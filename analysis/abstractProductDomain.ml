(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open AbstractDomain


module type PRODUCT_CONFIG = sig
  type 'a slot

  val slot_name: 'a slot -> string
  val slot_domain: 'a slot -> 'a abstract_domain
end


module Make(Config : PRODUCT_CONFIG) =
struct
  (* equal_slot compares to slots with potentially different types and produces
     a witness that allows recovering the type equality statically.

     Typically, clients would have to provide this function in the Config, but
     it is tedious to write type-safely, so to make the client interface
     simpler, we use Obj.magic here.
  *)
  let equal_slot (type a b) (left: a Config.slot) (right: b Config.slot) : (a, b) equality_witness =
    if left = Obj.magic right then
      Obj.magic AbstractDomain.Equal
    else
      AbstractDomain.Distinct

  module Key = struct
    include String
    let show = Fn.id
  end

  type 'a AbstractDomain.part +=
    | ProductSlot: 'b Config.slot * 'a AbstractDomain.part -> 'a AbstractDomain.part

  type element = Element: 'a Config.slot * 'a -> element

  let sexp_of_element = function
    | Element (slot, value) ->
        let name = Config.slot_name slot in
        let module D = (val (Config.slot_domain slot)) in
        Sexp.(List [Atom name; D.sexp_of_t value])

  let element_of_sexp _ =
    failwith "unimplemented"

  module ProductElement = struct
    let get_bottom (type a) (slot: a Config.slot) =
      let module D = (val (Config.slot_domain slot)) in
      D.bottom

    let is_bottom element =
      match element with
      | Element (slot, value) ->
          let module D = (val (Config.slot_domain slot)) in
          D.is_bottom value

    let show element =
      match element with
      | Element (slot, value) ->
          let module D = (val (Config.slot_domain slot)) in
          D.show value

    let join left right =
      match left, right with
      | Element (left_slot, left_value),
        Element (right_slot, right_value) ->
          match equal_slot left_slot right_slot with
          | Equal ->
              let module D = (val (Config.slot_domain left_slot)) in
              Element (left_slot, D.join left_value right_value)
          | Distinct ->
              failwith "unmatched slots"

    let widen ~iteration ~previous ~next =
      match previous, next with
      | Element (previous_slot, previous_value),
        Element (next_slot, next_value) ->
          match equal_slot previous_slot next_slot with
          | Equal ->
              let module D = (val (Config.slot_domain previous_slot)) in
              let value = D.widen ~iteration ~previous:previous_value ~next:next_value in
              Element (previous_slot, value)
          | Distinct ->
              failwith "unmatched slots"

    let less_or_equal ~left ~right =
      match left, right with
      | Element (left_slot, left_value),
        Element (right_slot, right_value) ->
          match equal_slot left_slot right_slot with
          | Equal ->
              let module D = (val (Config.slot_domain left_slot)) in
              D.less_or_equal ~left:left_value ~right:right_value
          | Distinct ->
              failwith "unmatched slots"

    let fold (type a b) (part: a part) ~(f: b -> a -> b) ~(init: b) element =
      match part, element with
      | ProductSlot (desired_slot, nested_part), Element (slot, value) ->
          begin
            match equal_slot desired_slot slot with
            | Equal ->
                let module D = (val (Config.slot_domain slot)) in
                D.fold nested_part ~f ~init value
            | Distinct ->
                init
          end
      | _ ->
          failwith "Must use product part"

    let transform (type a) (part: a part) ~(f: a -> a) element =
      match part, element with
      | ProductSlot (desired_slot, nested_part), Element (slot, value) ->
          begin
            match equal_slot desired_slot slot with
            | Equal ->
                let module D = (val (Config.slot_domain slot)) in
                Element (slot, D.transform nested_part ~f value)
            | Distinct ->
                element
          end
      | _ ->
          failwith "Must use product part"

    let partition (type a b) (part: a part) ~(f: a -> b) element =
      match part, element with
      | ProductSlot (desired_slot, nested_part), Element (slot, value) ->
          begin
            match equal_slot desired_slot slot with
            | Equal ->
                let module D = (val (Config.slot_domain slot)) in
                let partition = D.partition nested_part ~f value in
                `Fst (Map.Poly.map partition ~f:(fun value -> Element (slot, value)))
            | Distinct ->
                `Snd element
          end
      | _ ->
          failwith "Must use product part"

  end

  module Map = struct
    module ElementMap = Map.Make(Key)
    include ElementMap.Tree
  end

  type t = element Map.t
  [@@deriving sexp]

  let bottom = Map.empty

  let is_bottom d =
    Map.is_empty d

  let join x y =
    let merge ~key:_ = function
      | `Both (a, b) -> Some (ProductElement.join a b)
      | `Left e | `Right e -> Some e
    in
    Map.merge ~f:merge x y

  let widen ~iteration ~previous ~next =
    let merge ~key:_ = function
      | `Both (previous, next) -> Some (ProductElement.widen ~iteration ~previous ~next)
      | `Left e | `Right e -> Some e
    in
    Map.merge ~f:merge previous next

  let less_or_equal ~left ~right =
    let find_witness ~key:_ ~data =
      match data with
      | `Both (left, right) ->
          if not (ProductElement.less_or_equal ~left ~right) then raise Exit
      | `Left _ ->
          raise Exit
      | `Right _ ->
          ()
    in
    try
      Map.iter2 ~f:find_witness left right;
      true
    with
    | Exit -> false

  let show product =
    let show_pair (key, value) =
      Format.sprintf "%s: %s" (Key.show key) (ProductElement.show value)
    in
    Map.to_alist product
    |> List.map ~f:show_pair
    |> String.concat ~sep:", "

  let ensure_slot (type a) (slot: a Config.slot) product =
    let slot_name = Config.slot_name slot in
    if Map.mem product slot_name then
      product
    else
      let module D = (val (Config.slot_domain slot)) in
      Map.set product ~key:slot_name ~data:(Element (slot, D.bottom))

  let ensure_slots part product =
    match part with
    | ProductSlot (slot, _) -> ensure_slot slot product
    | _ -> failwith "Need ProductSlot or AllSlots"

  let transform (type a) (part: a part) ~(f: a -> a) (product: t) : t =
    ensure_slots part product
    |> Map.map ~f:(ProductElement.transform part ~f)

  let fold (type a b) (part: a part) ~(f: b -> a -> b) ~(init: b) (product: t) : b =
    ensure_slots part product
    |> Map.fold
      ~f:(fun ~key:_ ~data result -> ProductElement.fold part ~f ~init:result data)
      ~init

  let make elements =
    List.map ~f:(function Element (slot, _) as element -> (Config.slot_name slot, element)) elements
    |> Map.of_alist_exn

  let update (type a) (slot: a Config.slot) (value: a) product =
    Map.set product ~key:(Config.slot_name slot) ~data:(Element (slot, value))

  let partition (type a b) (part: a part) ~(f: a -> b) (product: t)
    : (b, t) Core.Map.Poly.t =
    let partitioned, unpartitioned =
      ensure_slots part product
      |> Map.data
      |> List.map ~f:(ProductElement.partition part ~f)
      |> List.partition_map ~f:Fn.id
    in
    let base_product = make unpartitioned in
    let update (Element (slot, value)) = function
      | None -> update slot value base_product
      | Some existing -> update slot value existing
    in
    let form_product_partition partition element_partition =
      Core.Map.Poly.fold
        element_partition
        ~init:partition
        ~f:(fun ~key:partition_key ~data partition ->
            Core.Map.Poly.update partition partition_key ~f:(update data))
    in
    List.fold partitioned ~init:Core.Map.Poly.empty ~f:form_product_partition

  let singleton (type a) (slot: a Config.slot) (value: a) =
    Map.set bottom ~key:(Config.slot_name slot) ~data:(Element (slot, value))

  let get (type a) (wanted: a Config.slot) product =
    match Map.find product (Config.slot_name wanted) with
    | None ->
        ProductElement.get_bottom wanted
    | Some (Element (slot, value)) ->
        match equal_slot slot wanted with
        | Equal -> value
        | Distinct -> failwith "internal invariant broken"

  let product = make
end