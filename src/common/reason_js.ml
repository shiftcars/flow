(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

(* This module defines a general notion of trace, which is used in modules
   Type_inference_js and Flow_js to record how the typechecker reasons about
   code, systematically collecting, simplifying, and solving constraints. This
   is extremely useful, not only for debugging the typechecker but also to
   really understand why an error is reported. *)

(* Eventually, trace information should be printed out only in verbose mode,
   since Flow reports all errors it finds and the trace for every error can get
   quite detailed dependening on how far apart the "source" and "sink" are and
   how convoluted the flow between them is. *)

open Utils_js
module Ast = Spider_monkey_ast

let mk_id () = Ident.make ""

(* Reasons are included in types mainly for error reporting, but sometimes we
   also use reasons in types to recover information on the source code that
   caused those reasons to be created. Two examples of such secondary uses of
   reasons are:

   - strictness analysis: we use reasons to locate the origin of an object and
   the origin of an operation on the object, and use such origins to determine
   whether certain errors should be suppressed.

   - termination analysis: we use reasons to limit instantiation of type
   parameters in polymorphic types at particular locations, to prevent the type
   checker from generating an unbounded number of constraints. The `pos` field
   of reasons is sufficient to distinguish code locations, except that as an
   implementation strategy for checking polymorphic definitions, we walk over
   the same source code multiple times to check it with different instantiations
   of type parameters, and to index "copies" of the reasons created in those
   passes over the same source code, we use an additional `test_id` field.
*)
module TestID = struct
  let _current = ref None

  (* Get current test id. *)
  let current() = !_current

  (* Call f on a, installing new_test_id as the current test_id, and restoring
     the current test_id when done. (See also the function mk_reason below.) *)
  let run f a =
    let test_id = current () in
    _current := Some (mk_id ());
    f a;
    _current := test_id

end

type reason = {
  test_id: int option;
  derivable: bool;
  desc: string;
  loc: Loc.t;
}

type t = reason

let lexpos file line col = {
  Lexing.pos_fname = file;
  Lexing.pos_lnum = line;
  Lexing.pos_bol = 0;
  Lexing.pos_cnum = col;
}

let diff_range loc = Loc.(
  let line1, line2 = loc.start.line, loc._end.line in
  (* TODO: Get rid of +1 which is here to ensure same behavior as old code
     using Pos.info_pos *)
  let start, end_  = loc.start.column + 1, loc._end.column in
  (line2 - line1, end_ - start)
)

let in_range loc range = Loc.(
  let line, line1, line2 = loc.start.line, range.start.line, range._end.line in
  (line1 < line || (line = line1 && range.start.column <= loc.start.column)) &&
  (line < line2 || (line = line2 && loc._end.column <= range._end.column))
)

let rec patch ll offset lines = function
  | [] -> ()
  | (l,c,str)::insertions ->
      let c = if l = ll then c + offset else c in
      let del = try Some (int_of_string str) with _ -> None in
      let line = lines.(l - 1) in
      let shift = match del with
      | Some n -> (* delete n chars at l, c *)
          lines.(l - 1) <- spf "%s%s"
            (Str.string_before line c) (Str.string_after line (c + n));
          -n
      | None -> (* insert str at l, c *)
          lines.(l - 1) <- spf "%s%s%s"
            (Str.string_before line c) str (Str.string_after line c);
          String.length str
      in
      let offset = (if l = ll then offset else 0) + shift in
      patch l offset lines insertions

let do_patch lines insertions =
  let lines = Array.of_list lines in
  patch 1 0 lines insertions;
  String.concat "\n" (Array.to_list lines)

let string_of_loc loc = Loc.(
  match loc.source with
  | None
  | Some Builtins -> ""
  | Some LibFile file
  | Some SourceFile file
  | Some JsonFile file ->
    let line = loc.start.line in
    let start = loc.start.column + 1 in
    let end_ = loc._end.column in
    if line <= 0 then
      spf "%s:0:0" file
    else if line = loc._end.line && start = end_ then
      spf "%s:%d:%d" file line start
    else if line != loc._end.line then
      spf "%s:%d:%d,%d:%d" file line start loc._end.line end_
    else
      spf "%s:%d:%d-%d" file line start end_
)

let json_of_loc loc = Hh_json.(Loc.(
  JSON_Object [
    "source", (match loc.source with
      | Some x -> JSON_String (string_of_filename x)
      | None -> JSON_Null);
    "start", JSON_Object [
      "line", int_ loc.start.line;
      "column", int_ (loc.start.column + 1);
      "offset", int_ loc.start.offset;
    ];
    "end", JSON_Object [
      "line", int_ loc._end.line;
      "column", int_ loc._end.column;
      "offset", int_ loc._end.offset;
    ];
  ]
))

(* reason constructors, accessors, etc. *)

let mk_reason_with_test_id test_id desc loc = {
  test_id;
  derivable = false;
  desc;
  loc;
}

(* The current test_id is included in every new reason. *)
let mk_reason desc loc =
  mk_reason_with_test_id (TestID.current()) desc loc

(* Lift a string to a reason. Usually used as a dummy reason. *)
let reason_of_string s =
  mk_reason_with_test_id None s Loc.none

let loc_of_reason r = r.loc

let string_of_reason r =
  let spos = string_of_loc (loc_of_reason r) in
  let desc = r.desc in
  if spos = ""
  then desc
  else (
    if desc = ""
    then spos
    else spf "%s:\n%s" spos desc
  )

let json_of_reason r = Hh_json.(
  JSON_Object [
    "pos", json_of_loc (loc_of_reason r);
    "desc", JSON_String r.desc
  ]
)

let dump_reason r =
  spf "%s: %S" (string_of_loc (loc_of_reason r)) r.desc

let desc_of_reason r =
  r.desc

let internal_name name =
  spf ".%s" name

let is_internal_name name =
  String.length name >= 1 && name.[0] = '.'

let internal_module_name name =
  spf "$module__%s" name

let is_internal_module_name name =
  Str.string_match (Str.regexp "\\$module__.*") name 0

let internal_pattern_name loc =
  spf "$pattern__%s" (string_of_loc loc)

let is_derivable_reason r =
  r.derivable

let derivable_reason r =
  { r with derivable = true }

let builtin_reason x =
  mk_reason x Loc.({ none with source = Some Builtins })
  |> derivable_reason

let is_builtin_reason r =
  Loc.(r.loc.source = Some Builtins)

let is_lib_reason r =
  Loc.(match r.loc.source with
  | Some LibFile _ -> true
  | Some Builtins -> true
  | Some SourceFile _ -> false
  | Some JsonFile _ -> false
  | None -> false)

let is_blamable_reason r =
  not Loc.(r.loc = none || is_lib_reason r)

let reasons_overlap r1 r2 =
  Loc.(contains r1.loc r2.loc)

(* reasons compare on their locations *)
let compare r1 r2 =
  Pervasives.compare (loc_of_reason r1) (loc_of_reason r2)

(* reason transformers: *)

(* returns reason whose description is prefix-extension of original *)
let prefix_reason prefix reason =
  mk_reason (spf "%s%s" prefix (desc_of_reason reason))
    (loc_of_reason reason)

(* returns reason whose description is suffix-extension of original *)
let suffix_reason suffix reason =
  mk_reason (spf "%s%s" (desc_of_reason reason) suffix)
    (loc_of_reason reason)

(* returns reason whose description is prefix+suffix-extension of original *)
let wrap_reason prefix suffix reason =
  mk_reason (spf "%s%s%s" prefix (desc_of_reason reason) suffix)
    (loc_of_reason reason)

(* returns reason with new description and position of original *)
let replace_reason replacement reason =
  mk_reason replacement (loc_of_reason reason)

(* returns reason with new location and description of original *)
let repos_reason loc reason =
  mk_reason (desc_of_reason reason) loc

(* helper: strip root from positions *)
let strip_root_from_loc root loc = Loc.(
  let source = match loc.source with
  | None -> None
  | Some Builtins -> Some Builtins
  | Some LibFile file ->
    let root_str = spf "%s%s" (Path.to_string root) Filename.dir_sep in
    if Str.string_match (Str.regexp_string root_str) file 0
    then Some (LibFile (spf "[LIB] %s" (Files_js.relative_path root_str file)))
    else Some (LibFile (spf "[LIB] %s" (Filename.basename file)))

  | Some SourceFile file ->
    let root_str = spf "%s%s" (Path.to_string root) Filename.dir_sep in
    Some (SourceFile (Files_js.relative_path root_str file))

  | Some JsonFile file ->
    let root_str = spf "%s%s" (Path.to_string root) Filename.dir_sep in
    Some (JsonFile (Files_js.relative_path root_str file))
  in
  { loc with source }
)

let strip_root root reason =
  let loc = strip_root_from_loc root (loc_of_reason reason) in
  repos_reason loc reason
