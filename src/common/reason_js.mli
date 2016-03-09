(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

val mk_id: unit -> int

type reason
type t = reason (* convenience *)

module TestID: sig
  val run: ('a -> unit) -> 'a -> unit
end

val lexpos: string -> int -> int -> Lexing.position

(* reason constructor *)
val mk_reason: string -> Loc.t -> reason

(* ranges *)
val diff_range: Loc.t -> int * int
val in_range: Loc.t -> Loc.t -> bool

val string_of_loc: Loc.t -> string
val json_of_loc: Loc.t -> Hh_json.json

val reason_of_string: string -> reason

val is_internal_name: string -> bool
val internal_name: string -> string

val is_internal_module_name: string -> bool
val internal_module_name: string -> string

val internal_pattern_name: Loc.t -> string

val derivable_reason: reason -> reason
val is_derivable_reason: reason -> bool

val builtin_reason: string -> reason

(* reason location preds *)
val is_builtin_reason: reason -> bool
val is_lib_reason: reason -> bool
val is_blamable_reason: reason -> bool
val reasons_overlap: reason -> reason -> bool

val string_of_reason: reason -> string
val json_of_reason: reason -> Hh_json.json
val dump_reason: reason -> string

(* accessors *)
val loc_of_reason: reason -> Loc.t

val desc_of_reason: reason -> string

(* simple way to get derived reasons whose descriptions are
   simple extensions of the original *)
val prefix_reason: string -> reason -> reason
val suffix_reason: string -> reason -> reason
val wrap_reason: string -> string -> reason -> reason

(* simple way to get derived reasons whose descriptions are
   simple replacements of the original *)
val replace_reason: string -> reason -> reason

val repos_reason: Loc.t -> reason -> reason

val compare: reason -> reason -> int

val do_patch: string list -> (int * int * string) list -> string

val strip_root: Path.t -> reason -> reason
val strip_root_from_loc: Path.t -> Loc.t -> Loc.t
