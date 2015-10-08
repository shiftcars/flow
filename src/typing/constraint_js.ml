(**
 * Copyright (c) 2014, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

(* This module defines the ML data types that represent types in Flow. *)

open Utils
open Utils_js
open Reason_js
open Type

module Ast = Spider_monkey_ast

type ident = int

(** Type variables are unknowns, and we are ultimately interested in constraints
    on their solutions for type inference.

    Type variables form nodes in a "union-find" forest: each tree denotes a set
    of type variables that are considered by the type system to be equivalent.

    There are two kinds of nodes: Goto nodes and Root nodes.

    - All Goto nodes of a tree point, directly or indirectly, to the Root node
    of the tree.
    - A Root node holds the actual non-trivial state of a tvar, represented by a
    root structure (see below).
**)
type node =
| Goto of ident
| Root of root

(** A root structure carries the actual non-trivial state of a tvar, and
    consists of:

    - rank, which is a quantity roughly corresponding to the longest chain of
    gotos pointing to the tvar. It's an implementation detail of the unification
    algorithm that simply has to do with efficiently finding the root of a tree.
    We merge a tree with another tree by converting the root with the lower rank
    to a goto node, and making it point to the root with the higher rank. See
    http://en.wikipedia.org/wiki/Disjoint-set_data_structure for more details on
    this data structure and supported operations.

    - constraints, which carry type information that narrows down the possible
    solutions of the tvar (see below).  **)

and root = {
  rank: int;
  constraints: constraints;
}

(** Constraints carry type information that narrows down the possible solutions
    of tvar, and are of two kinds:

    - A Resolved constraint contains a concrete type that is considered by the
    type system to be the solution of the tvar carrying the constraint. In other
    words, the tvar is equivalent to this concrete type in all respects.

    - Unresolved constraints contain bounds that carry both concrete types and
    other tvars as upper and lower bounds (see below).
**)

and constraints =
| Resolved of Type.t
| Unresolved of bounds

(** The bounds structure carries the evolving constraints on the solution of an
    unresolved tvar.

    - upper and lower hold concrete upper and lower bounds, respectively. At any
    point in analysis the aggregate lower bound of a tvar is (conceptually) the
    union of the concrete types in lower, and the aggregate upper bound is
    (conceptually) the intersection of the concrete types in upper. (Upper and
    lower are maps, with the types as keys, and trace information as values.)

    - lowertvars and uppertvars hold tvars which are also (latent) lower and
    upper bounds, respectively. See the __flow function for how these structures
    are populated and operated on.  Here the map keys are tvar ids, with trace
    info as values.
**)
and bounds = {
  mutable lower: Trace.t TypeMap.t;
  mutable upper: Trace.t TypeMap.t;
  mutable lowertvars: Trace.t IMap.t;
  mutable uppertvars: Trace.t IMap.t;
}

(* Extract bounds from a node. *)
(** WARNING: This function is unsafe, since not all nodes are roots, and not all
    roots are unresolved. Use this function only when you are absolutely sure
    that a node is an unresolved root: this is guaranteed to be the case when
    the type variable it denotes is never involved in unification. **)
let bounds_of_unresolved_root node =
  match node with
  | Root { constraints = Unresolved bounds; _ } -> bounds
  | _ -> failwith "expected unresolved root"

let new_bounds () = {
  lower = TypeMap.empty;
  upper = TypeMap.empty;
  lowertvars = IMap.empty;
  uppertvars = IMap.empty;
}

let new_unresolved_root () =
  Root { rank = 0; constraints = Unresolved (new_bounds ()) }

let copy_bounds = function
  | { lower; upper; lowertvars; uppertvars; } ->
    { lower; upper; lowertvars; uppertvars; }

let copy_node node = match node with
  | Root { rank; constraints = Unresolved bounds } ->
    Root { rank; constraints = Unresolved (copy_bounds bounds) }
  | _ -> node

(***************************************)
(* type context *)

type stack = int list

type context = {
  file: filename;
  _module: string;
  checked: bool;
  weak: bool;
  verbose: int option;

  (* required modules, and map to their locations *)
  mutable required: SSet.t;
  mutable require_loc: Loc.t SMap.t;
  mutable module_exports_type: module_exports_type;

  (* map from tvar ids to nodes (type info structures) *)
  mutable graph: node IMap.t;

  (* obj types point to mutable property maps *)
  mutable property_maps: Type.properties IMap.t;

  (* map from closure ids to env snapshots *)
  mutable closures: (stack * Scope.t list) IMap.t;

  (* map from module names to their types *)
  mutable modulemap: Type.t SMap.t;

  mutable errors: Errors_js.ErrorSet.t;
  mutable globals: SSet.t;

  mutable error_suppressions: Errors_js.ErrorSuppressions.t;

  type_table: (Loc.t, Type.t) Hashtbl.t;
  annot_table: (Loc.t, Type.t) Hashtbl.t;
}

and module_exports_type =
  | CommonJSModule of Loc.t option
  | ESModule

(* create a new context structure.
   Flow_js.fresh_context prepares for actual use.
 *)
let new_context ?(checked=false) ?(weak=false) ~verbose ~file ~_module = {
  file;
  _module;
  checked;
  weak;
  verbose;

  required = SSet.empty;
  require_loc = SMap.empty;
  module_exports_type = CommonJSModule(None);

  graph = IMap.empty;
  closures = IMap.empty;
  property_maps = IMap.empty;
  modulemap = SMap.empty;

  errors = Errors_js.ErrorSet.empty;
  globals = SSet.empty;

  error_suppressions = Errors_js.ErrorSuppressions.empty;

  type_table = Hashtbl.create 0;
  annot_table = Hashtbl.create 0;
}

(********************************************************************)

let name_prefix_of_t = function
  | RestT _ -> "..."
  | _ -> ""

let name_suffix_of_t = function
  | OptionalT _ -> "?"
  | _ -> ""

let parameter_name cx n t =
  (name_prefix_of_t t) ^ n ^ (name_suffix_of_t t)

type enclosure_t =
    EnclosureNone
  | EnclosureUnion
  | EnclosureIntersect
  | EnclosureParam
  | EnclosureMaybe
  | EnclosureAppT
  | EnclosureRet

let parenthesize t_str enclosure triggers =
  if List.mem enclosure triggers
  then "(" ^ t_str ^ ")"
  else t_str

(* general-purpose type printer. not the cleanest visitor in the world,
   but reasonably general. override gets a chance to print the incoming
   type first. if it passes, the bulk of printable types are formatted
   in a reasonable way. fallback is sent the rest. enclosure drives
   delimiter choice. see e.g. string_of_t for callers.
 *)
let rec type_printer override fallback enclosure cx t =
  let pp = type_printer override fallback in
  match override cx t with
  | Some s -> s
  | None ->
    match t with
    | BoundT typeparam -> typeparam.name

    | SingletonStrT (_, s) -> spf "'%s'" s
    | SingletonNumT (_, (_, raw)) -> raw
    | SingletonBoolT (_, b) -> string_of_bool b

    (* reasons for VoidT use "undefined" for more understandable error output.
       For parsable types we need to use "void" though, thus overwrite it. *)
    | VoidT _ -> "void"

    | FunT (_,_,_,{params_tlist = ts; params_names = pns; return_t = t; _}) ->
        let pns =
          match pns with
          | Some pns -> pns
          | None -> List.map (fun _ -> "_") ts in
        let type_s = spf "(%s) => %s"
          (List.map2 (fun n t ->
              (parameter_name cx n t) ^
              ": "
              ^ (pp EnclosureParam cx t)
            ) pns ts
           |> String.concat ", "
          )
          (pp EnclosureNone cx t) in
        parenthesize type_s enclosure [EnclosureUnion; EnclosureIntersect]

    | ObjT (_, {props_tmap = flds; dict_t; _}) ->
        let props =
          IMap.find_unsafe flds cx.property_maps
           |> SMap.elements
           |> List.filter (fun (x,_) -> not (Reason_js.is_internal_name x))
           |> List.rev
           |> List.map (fun (x,t) -> x ^ ": " ^ (pp EnclosureNone cx t) ^ ",")
           |> String.concat " "
        in
        let indexer =
          (match dict_t with
          | Some { dict_name; key; value } ->
              let indexer_prefix =
                if props <> ""
                then " "
                else ""
              in
              let dict_name = match dict_name with
                | None -> "_"
                | Some name -> name
              in
              (spf "%s[%s: %s]: %s,"
                indexer_prefix
                dict_name
                (pp EnclosureNone cx key)
                (pp EnclosureNone cx value)
              )
          | None -> "")
        in
        spf "{%s%s}" props indexer

    | ArrT (_, t, ts) ->
        (*(match ts with
        | [] -> *)spf "Array<%s>" (pp EnclosureNone cx t)
        (*| _ -> spf "[%s]"
                  (ts
                    |> List.map (pp cx EnclosureNone)
                    |> String.concat ", "))*)

    | InstanceT (reason,static,super,instance) ->
        desc_of_reason reason (* nominal type *)

    | TypeAppT (c,ts) ->
        let type_s =
          spf "%s <%s>"
            (pp EnclosureAppT cx c)
            (ts
              |> List.map (pp EnclosureNone cx)
              |> String.concat ", "
            )
        in
        parenthesize type_s enclosure [EnclosureMaybe]

    | MaybeT t ->
        spf "?%s" (pp EnclosureMaybe cx t)

    | PolyT (xs,t) ->
        let type_s =
          spf "<%s> %s"
            (xs
              |> List.map (fun param -> param.name)
              |> String.concat ", "
            )
            (pp EnclosureNone cx t)
        in
        parenthesize type_s enclosure [EnclosureAppT; EnclosureMaybe]

    | IntersectionT (_, ts) ->
        let type_s =
          (ts
            |> List.map (pp EnclosureIntersect cx)
            |> String.concat " & "
          ) in
        parenthesize type_s enclosure [EnclosureUnion; EnclosureMaybe]

    | UnionT (_, ts) ->
        let type_s =
          (ts
            |> List.map (pp EnclosureUnion cx)
            |> String.concat " | "
          ) in
        parenthesize type_s enclosure [EnclosureIntersect; EnclosureMaybe]

    (* The following types are not syntax-supported in all cases *)
    | RestT t ->
        let type_s =
          spf "Array<%s>" (pp EnclosureNone cx t) in
        if enclosure == EnclosureParam
        then type_s
        else "..." ^ type_s

    | OptionalT t ->
        let type_s = pp EnclosureNone cx t in
        if enclosure == EnclosureParam
        then type_s
        else "=" ^ type_s

    | AnnotT (_, t) -> pp EnclosureNone cx t
    | KeysT (_, t) -> spf "$Keys<%s>" (pp EnclosureNone cx t)
    | ShapeT t -> spf "$Shape<%s>" (pp EnclosureNone cx t)

    (* The following types are not syntax-supported *)
    | ClassT t ->
        spf "[class: %s]" (pp EnclosureNone cx t)

    | TypeT (_, t) ->
        spf "[type: %s]" (pp EnclosureNone cx t)

    | BecomeT (_, t) ->
        spf "[become: %s]" (pp EnclosureNone cx t)

    | LowerBoundT t ->
        spf "$Subtype<%s>" (pp EnclosureNone cx t)

    | UpperBoundT t ->
        spf "$Supertype<%s>" (pp EnclosureNone cx t)

    | AnyObjT _ ->
        "Object"

    | AnyFunT _ ->
        "Function"

    | t ->
        fallback t

(* pretty printer *)
let string_of_t_ =
  let override cx t = match t with
    | OpenT (r, id) -> Some (spf "TYPE_%d" id)
    | NumT _
    | StrT _
    | BoolT _
    | UndefT _
    | MixedT _
    | AnyT _
    | NullT _ -> Some (desc_of_reason (reason_of_t t))
    | _ -> None
  in
  let fallback t =
    assert_false (spf "Missing printer for %s" (string_of_ctor t))
  in
  fun enclosure cx t ->
    type_printer override fallback enclosure cx t

let string_of_t =
  string_of_t_ EnclosureNone

let string_of_param_t =
  string_of_t_ EnclosureParam

let rec is_printed_type_parsable_impl weak cx enclosure = function
  (* Base cases *)
  | BoundT _
  | NumT _
  | StrT _
  | BoolT _
  | AnyT _
    ->
      true

  | VoidT _
    when (enclosure == EnclosureRet)
    ->
      true

  | AnnotT (_, t) ->
      is_printed_type_parsable_impl weak cx enclosure t

  (* Composed types *)
  | MaybeT t
    ->
      is_printed_type_parsable_impl weak cx EnclosureMaybe t

  | ArrT (_, t, ts)
    ->
      (*(match ts with
      | [] -> *)is_printed_type_parsable_impl weak cx EnclosureNone t
      (*| _ ->
          is_printed_type_list_parsable weak cx EnclosureNone t*)

  | RestT t
  | OptionalT t
    when (enclosure == EnclosureParam)
    ->
      is_printed_type_parsable_impl weak cx EnclosureNone t

  | FunT (_, _, _, { params_tlist; return_t; _ })
    ->
      (is_printed_type_parsable_impl weak cx EnclosureRet return_t) &&
      (is_printed_type_list_parsable weak cx EnclosureParam params_tlist)

  | ObjT (_, { props_tmap; dict_t; _ })
    ->
      let is_printable =
        match dict_t with
        | Some { key; value; _ } ->
            (is_printed_type_parsable_impl weak cx EnclosureNone key) &&
            (is_printed_type_parsable_impl weak cx EnclosureNone value)
        | None -> true
      in
      let prop_map = IMap.find_unsafe props_tmap cx.property_maps in
      SMap.fold (fun name t acc ->
          acc && (
            (* We don't print internal properties, thus we do not care whether
               their type is printable or not *)
            (Reason_js.is_internal_name name) ||
            (is_printed_type_parsable_impl weak cx EnclosureNone t)
          )
        ) prop_map is_printable

  | InstanceT _
    ->
      true

  | IntersectionT (_, ts)
    ->
      is_printed_type_list_parsable weak cx EnclosureIntersect ts

  | UnionT (_, ts)
    ->
      is_printed_type_list_parsable weak cx EnclosureUnion ts

  | PolyT (_, t)
    ->
      is_printed_type_parsable_impl weak cx EnclosureNone t

  | AnyObjT _ -> true
  | AnyFunT _ -> true

  (* weak mode *)

  (* these are types which are not really parsable, but they make sense to a
     human user in cases of autocompletion *)
  | OptionalT t
  | RestT t
  | TypeT (_, t)
  | LowerBoundT t
  | UpperBoundT t
  | ClassT t
    when weak
    ->
      is_printed_type_parsable_impl weak cx EnclosureNone t

  | VoidT _
    when weak
    ->
      true

  (* This gives really ugly output, but would need to figure out a better way
     to print these types otherwise, maybe substitute on printing? *)
  | TypeAppT (t, ts)
    when weak
    ->
      (is_printed_type_parsable_impl weak cx EnclosureAppT t) &&
      (is_printed_type_list_parsable weak cx EnclosureNone ts)

  | _
    ->
      false

and is_printed_type_list_parsable weak cx enclosure ts =
  List.fold_left (fun acc t ->
      acc && (is_printed_type_parsable_impl weak cx enclosure t)
    ) true ts

let is_printed_type_parsable ?(weak=false) cx t =
  is_printed_type_parsable_impl weak cx EnclosureNone t

let is_printed_param_type_parsable ?(weak=false) cx t =
  is_printed_type_parsable_impl weak cx EnclosureParam t

(********* type visitor *********)

(* We walk types in a lot of places for all kinds of things, but often most of
   the code is boilerplate. The following visitor class for types aims to
   reduce that boilerplate. It is designed as a fold on the structure of types,
   parameterized by an accumulator.

   WARNING: This is only a partial implementation, sufficient for current
   purposes but intended to be completed in a later diff.
*)
class ['a] type_visitor = object(self)
  method type_ cx (acc: 'a) = function
  | OpenT (_, id) -> self#id_ cx acc id

  | NumT _
  | StrT _
  | BoolT _
  | UndefT _
  | MixedT _
  | AnyT _
  | NullT _
  | VoidT _ -> acc

  | FunT (_, static, prototype, funtype) ->
    let acc = self#type_ cx acc static in
    let acc = self#type_ cx acc prototype in
    let acc = self#fun_type cx acc funtype in
    acc

  | ObjT (_, { dict_t; props_tmap; proto_t; _ }) ->
    let acc = self#opt (self#dict_ cx) acc dict_t in
    let acc = self#props cx acc props_tmap in
    let acc = self#type_ cx acc proto_t in
    acc

  | ArrT (_, t, ts) ->
    let acc = self#type_ cx acc t in
    let acc = self#list (self#type_ cx) acc ts in
    acc

  | ClassT t -> self#type_ cx acc t

  | InstanceT (_, static, super, insttype) ->
    let acc = self#type_ cx acc static in
    let acc = self#type_ cx acc super in
    let acc = self#inst_type cx acc insttype in
    acc

  | OptionalT t -> self#type_ cx acc t

  | RestT t -> self#type_ cx acc t

  | PolyT (typeparams, t) ->
    let acc = self#list (self#type_param cx) acc typeparams in
    let acc = self#type_ cx acc t in
    acc

  | TypeAppT (t, ts) ->
    let acc = self#type_ cx acc t in
    let acc = self#list (self#type_ cx) acc ts in
    acc

  | BoundT typeparam -> self#type_param cx acc typeparam

  | ExistsT _ -> acc

  | MaybeT t -> self#type_ cx acc t

  | IntersectionT (_, ts)
  | UnionT (_, ts) -> self#list (self#type_ cx) acc ts

  | UpperBoundT t
  | LowerBoundT t -> self#type_ cx acc t

  | AnyObjT _
  | AnyFunT _ -> acc

  | ShapeT t -> self#type_ cx acc t

  | DiffT (t1, t2) ->
    let acc = self#type_ cx acc t1 in
    let acc = self#type_ cx acc t2 in
    acc

  | KeysT (_, t) -> self#type_ cx acc t

  | SingletonStrT _
  | SingletonNumT _
  | SingletonBoolT _ -> acc

  | TypeT (_, t) -> self#type_ cx acc t

  | AnnotT (t1, t2) ->
    let acc = self#type_ cx acc t1 in
    let acc = self#type_ cx acc t2 in
    acc

  | BecomeT (_, t) -> self#type_ cx acc t

  | SpeculativeMatchFailureT (_, t1, t2) ->
    let acc = self#type_ cx acc t1 in
    let acc = self#type_ cx acc t2 in
    acc

  | ModuleT (_, exporttypes) ->
    self#export_types cx acc exporttypes

  (* Currently not walking use types. This will change in an upcoming diff. *)
  | SummarizeT (_, _)
  | CallT (_, _)
  | MethodT (_, _, _)
  | ReposLowerT (_, _)
  | ReposUpperT (_, _)
  | SetPropT (_, _, _)
  | GetPropT (_, _, _)
  | SetElemT (_, _, _)
  | GetElemT (_, _, _)
  | ConstructorT (_, _, _)
  | SuperT (_, _)
  | ExtendsT (_, _, _)
  | AdderT (_, _, _)
  | ComparatorT (_, _)
  | PredicateT (_, _)
  | EqT (_, _)
  | AndT (_, _, _)
  | OrT (_, _, _)
  | NotT (_, _)
  | SpecializeT (_, _, _, _)
  | LookupT (_, _, _, _, _)
  | ObjAssignT (_, _, _, _, _)
  | ObjFreezeT (_, _)
  | ObjRestT (_, _, _)
  | ObjSealT (_, _)
  | ObjTestT (_, _, _)
  | UnaryMinusT (_, _)
  | UnifyT (_, _)
  | ConcretizeT (_, _, _, _)
  | ConcreteT _
  | GetKeysT (_, _)
  | HasKeyT (_, _)
  | ElemT (_, _, _)
  | CJSRequireT (_, _)
  | ImportModuleNsT (_, _)
  | ImportTypeT (_, _)
  | ImportTypeofT (_, _)
  | CJSExtractNamedExportsT (_, _, _)
  | SetCJSExportT (_, _, _)
  | SetNamedExportsT (_, _, _)
    -> self#__TODO__ cx acc

  (* The default behavior here could be fleshed out a bit, to look up the graph,
     handle Resolved and Unresolved cases, etc. *)
  method id_ cx acc id = acc

  method private dict_ cx acc { key; value; _ } =
    let acc = self#type_ cx acc key in
    let acc = self#type_ cx acc value in
    acc

  method props cx acc id =
    self#smap (self#type_ cx) acc (IMap.find_unsafe id cx.property_maps)

  method private type_param cx acc { bound; _ } =
    self#type_ cx acc bound

  method fun_type cx acc { this_t; params_tlist; return_t; _ } =
    let acc = self#type_ cx acc this_t in
    let acc = self#list (self#type_ cx) acc params_tlist in
    let acc = self#type_ cx acc return_t in
    acc

  method private inst_type cx acc { type_args; fields_tmap; methods_tmap; _ } =
    let acc = self#smap (self#type_ cx) acc type_args in
    let acc = self#props cx acc fields_tmap in
    let acc = self#props cx acc methods_tmap in
    acc

  method private export_types cx acc { exports_tmap; cjs_export } =
    let acc = self#props cx acc exports_tmap in
    let acc = self#opt (self#type_ cx) acc cjs_export in
    acc

  method private __TODO__ cx acc = acc

  method private list: 't. ('a -> 't -> 'a) -> 'a -> 't list -> 'a =
    List.fold_left

  method private opt: 't. ('a -> 't -> 'a) -> 'a -> 't option -> 'a =
    fun f acc -> function
    | None -> acc
    | Some x -> f acc x

  method private smap: 't. ('a -> 't -> 'a) -> 'a -> 't SMap.t -> 'a =
    fun f acc map ->
      SMap.fold (fun _ t acc -> f acc t) map acc
end
