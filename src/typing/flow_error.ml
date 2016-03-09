(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Type
open Utils_js
open Reason_js
module Errors = Errors_js

(** we keep a stack of reasons representing the operations
    taking place when flows are performed. the top op reason
    is used in messages for errors that take place during its
    residence.
  *)
module Ops : sig
  val clear : unit -> reason list
  val push : reason -> unit
  val pop : unit -> unit
  val peek : unit -> reason option
  val get : unit -> reason list
  val set : reason list -> unit
end = struct
  let ops = ref []
  let clear () = let orig = !ops in ops := []; orig
  let push r = ops := r :: !ops
  let pop () = ops := List.tl !ops
  let peek () = match !ops with r :: _ -> Some r | [] -> None
  let get () = !ops
  let set _ops = ops := _ops
end

(** error services for typecheck pipeline -
    API for building and adding errors to context during
    typechecking, subject to speculation state.
  *)

module Impl : sig

  (* speculative checking *)
  exception SpeculativeError of Errors.error
  val set_speculative: unit -> unit
  val restore_speculative: unit -> unit
  val speculation_depth: unit -> int

  (* error info is a location followed by a list of strings.
     mk_info takes location and first string from a reason. *)
  val mk_info: reason -> string list -> Errors.info

  (* convert reason into error info *)
  val info_of_reason: reason -> Errors.info

  (* build warning from info and add to context *)
  val add_warning:
    Context.t -> ?extra:Errors.info_tree list -> Errors.info -> unit

  (* build error from info and add to context *)
  val add_error:
    Context.t -> ?extra:Errors.info_tree list -> Errors.info -> unit

  (* build error from info list and add to context *)
  val add_extended_error:
    Context.t -> ?extra:Errors.info_tree list -> Errors.info list -> unit

  (* build internal error from info and add to context *)
  val add_internal_error:
    Context.t -> ?extra:Errors.info_tree list -> Errors.info -> unit

  (* add typecheck (flow) error from message and LB/UB pair.
     note: reasons extracted from types may appear in either order *)
  val flow_err:
    Context.t -> Trace.t -> string -> ?extra:Errors.info_tree list ->
    Type.t -> Type.use_t ->
    unit

  (* for when a t has been extracted from a use_t *)
  val flow_err_use_t:
    Context.t -> Trace.t -> string -> ?extra:Errors.info_tree list ->
    Type.t -> Type.t ->
    unit

  (* add typecheck (flow) error from message and reason pair.
     reasons are not reordered *)
  val flow_err_reasons:
    Context.t -> Trace.t -> string -> ?extra:Errors.info_tree list ->
    reason * reason ->
    unit

  (* TODO remove once error messages are indexed *)
  val flow_err_prop_not_found:
    Context.t -> Trace.t -> reason * reason -> unit

end = struct

  exception SpeculativeError of Errors.error

  let speculative = ref 0
  let set_speculative () = speculative := !speculative + 1
  let restore_speculative () = speculative := !speculative - 1
  let speculation_depth () = !speculative

  (* internal *)
  let throw_on_error () = !speculative > 0

  let mk_info reason extra_msgs =
    loc_of_reason reason, desc_of_reason reason :: extra_msgs

  let info_of_reason r =
    mk_info r []

  (* lowish-level error logging.
     basic filtering and packaging before sending error to context. *)
  let add_output cx error =
    if throw_on_error ()
    then raise (SpeculativeError error)
    else (
      if Context.is_verbose cx
      then prerr_endlinef "\nadd_output cx.file %S loc %s"
        (string_of_filename (Context.file cx))
        (string_of_loc (Errors.loc_of_error error));

      (* catch no-loc errors early, before they get into error map *)
      Errors.(
        if Loc.source (loc_of_error error) = None
        then assert_false (spf "add_output: no source for error: %s"
          (Hh_json.json_to_multiline (json_of_errors [error])))
      );

      Context.add_error cx error
    )

  let add_warning cx ?extra info =
    add_output cx Errors.(mk_error ~kind:InferWarning ?extra [info])

  let add_error cx ?extra info =
    add_output cx (Errors.mk_error ?extra [info])

  let add_extended_error cx ?extra infos =
    add_output cx (Errors.mk_error ?extra infos)

  let add_internal_error cx ?extra info =
    add_output cx Errors.(mk_error ~kind:InternalError ?extra [info])

  (** build typecheck error from msg, reasons, trace and extra info.
      Note: Ops stack is also queried, so this isn't a stateless function.
    *)
  let typecheck_error cx trace msg ?extra (r1, r2) =
    (* make core info from reasons, message, and optional extra infos *)
    let core_infos = [
      mk_info r1 [msg];
      mk_info r2 []
    ] in
    (* Since pointing to endpoints in the library without any information on
       the code that uses those endpoints inconsistently is useless, we point
       to the file containing that code instead. Ideally, improvements in
       error reporting would cause this case to never arise. *)
    let lib_infos = if is_lib_reason r1 && is_lib_reason r2 then
        let loc = Loc.({ none with source = Some (Context.file cx) }) in
        [loc, ["inconsistent use of library definitions"]]
      else []
    in
    (* trace info *)
    let trace_infos =
      (* format a trace into list of (reason, desc) pairs used
       downstream for obscure reasons, and then to messages *)
      let max_trace_depth = Context.max_trace_depth cx in
      if max_trace_depth = 0 then [] else
        let strip_root = Context.should_strip_root cx in
        Trace.reasons_of_trace ~strip_root ~level:max_trace_depth trace
        |> List.map info_of_reason
    in
    (* NOTE: We include the operation's reason in the error message, unless it
       overlaps *both* endpoints. *)
    let op_info = match Ops.peek () with
      | Some r when not (reasons_overlap r r1 && reasons_overlap r r2) ->
        Some (info_of_reason r)
      | _ -> None
    in
    (* main info is core info with optional lib line prepended, and optional
       extra info appended. ops/trace info is held separately in error *)
    let msg_infos = lib_infos @ core_infos in
    Errors.mk_error ?op_info ~trace_infos ?extra msg_infos

  let flow_err_reasons cx trace msg ?extra (r1, r2) =
    add_output cx (typecheck_error cx trace msg ?extra (r1, r2))

  (* TODO remove once error messages are indexed *)
  let flow_err_prop_not_found cx trace (r1, r2) =
    flow_err_reasons cx trace "Property not found in" (r1, r2)

  (* decide reason order based on UB's flavor and blamability *)
  let ordered_reasons l u =
    let rl = reason_of_t l in
    let ru = reason_of_use_t u in
    if is_use u || (is_blamable_reason ru && not (is_blamable_reason rl))
    then ru, rl
    else rl, ru

  (* build a flow error from an LB/UB pair *)
  let flow_err cx trace msg ?extra lower upper =
    let r1, r2 = ordered_reasons lower upper in
    flow_err_reasons cx trace msg ?extra (r1, r2)

  (* for when a t has been extracted from a use_t *)
  let flow_err_use_t cx trace msg ?extra lower upper =
    flow_err cx trace msg ?extra lower (UseT upper)

end

include Impl
