(* Default render width when no caller specifies one. Matches Rocq's
   own [Pp.string_of_ppcmds] (which uses [Format.str_formatter]'s
   default margin of ~78). The View passes the actual goals/messages
   pane width so panes wider or narrower than 78 reflow correctly. *)
let default_width = 78

let string_of_pp ?(width=default_width) pp =
  let buf = Stdlib.Buffer.create 256 in
  let fmt = Format.formatter_of_buffer buf in
  Format.pp_set_margin fmt width;
  Format.fprintf fmt "@[%a@]" Pp.pp_with pp;
  Format.pp_print_flush fmt ();
  Stdlib.Buffer.contents buf

type sentence_status = Processing | Verified | Error of string

type sentence_info = {
  start_off : int;
  end_off : int;
  mutable state_id : Stateid.t;
  mutable status : sentence_status;
}

(* Where to deliver a query's result. [Qr_msgs] (the editor case)
   leaves the result in [t.msgs] for the user to see. [Qr_external]
   (the MCP case) hands the result to a callback and restores the
   editor's prior [t.msgs] contents. *)
type query_reply =
  | Qr_msgs
  | Qr_external of (Pp.t list -> unit)

(* User intent: run [phrase] as a query at the current tip, with
   per-call printing-option overrides. One-deep slot — second press
   while a query is already pending is silently dropped. *)
type pending_query = {
  pq_phrase : string;
  pq_extra_opts : (string list * Interface.option_value) list;
  pq_reply : query_reply;
}

(* Phases of an in-flight query op. The query proceeds: send setup
   sentences ([Set Printing X.] etc.) one at a time → run the query
   at the resulting tip → restore the original tip via [edit_at]. *)
type query_phase =
  | Qp_setup of {
      remaining : string list;     (* setup sentences left to send *)
      tip : Stateid.t;             (* tip after sentences sent so far *)
      pending : Interface.add_rty Rocq_protocol.handle;
    }
  | Qp_query of {
      tip : Stateid.t;             (* tip the query is running at *)
      pending : unit Rocq_protocol.handle;
    }
  | Qp_restore of {
      pending : Interface.edit_at_rty Rocq_protocol.handle;
    }

type query_op_state = {
  qos_pq : pending_query;
  qos_original_tip : Stateid.t;
  (* Snapshot of [t.msgs] when the op started. Restored at op end
     when [pq_reply = Qr_external] so the editor view is preserved. *)
  qos_msgs_before : Pp.t list;
  (* Query-feedback msgs captured between Qp_query and Qp_restore so
     we can restore them after the edit_at adds its own feedback. *)
  qos_query_msgs : Pp.t list;
  qos_phase : query_phase;
}

type verifying_op_state = {
  vos_sentence : sentence_info;
  vos_pending : Interface.add_rty Rocq_protocol.handle;
}

(* Phases of the post-step goals refresh: send the current Printopts
   via set_options, then fetch goals at the new tip. *)
type refresh_phase =
  | Rp_set_options of unit Rocq_protocol.handle
  | Rp_fetch of Interface.goals option Rocq_protocol.handle

(* User intent: fetch goals text (formatted) with optional per-call
   printing-option overrides. The formatted result (or [None] if
   there's no proof in progress) is delivered to [pf_on_done]. *)
type pending_fetch = {
  pf_all_hyps : bool;
  pf_width : int;
  pf_extra_opts : (string list * Interface.option_value) list;
  pf_on_done : string option -> unit;
}

(* Phases of an in-flight fetch_goals op: send Printopts, then fetch
   goals and format them. *)
type fetch_phase =
  | Fp_set_options of unit Rocq_protocol.handle
  | Fp_fetch of Interface.goals option Rocq_protocol.handle

type fetch_op_state = {
  fos_pf : pending_fetch;
  fos_phase : fetch_phase;
}

(* In-flight rewind to [ros_target_id]. On Good, sentences whose
   state_id is "above" target_id are dropped (their state was
   rolled back by rocq). On Fail, [safe_id] tells us where rocq
   actually landed and we drop accordingly. *)
type rewinding_op_state = {
  ros_target_id : Stateid.t;
  ros_pending : Interface.edit_at_rty Rocq_protocol.handle;
}

type op_state =
  | Op_query of query_op_state
  | Op_verifying of verifying_op_state
  | Op_refreshing_goals of refresh_phase
  | Op_fetch_goals of fetch_op_state
  | Op_rewinding of rewinding_op_state

type t = {
  rocq : Rocq_protocol.t;
  buf : Buffer.t;
  mutable tip : Stateid.t;
  mutable sentences : sentence_info list;  (* stack, most recent first *)
  mutable next_edit_id : int;
  mutable goals_cache : Interface.goals option;
  (* Messages stored as Pp.t so they can be re-rendered at the current
     pane width. Sentence Error status keeps a stringified copy at
     default width — used for short status display where width doesn't
     matter much. *)
  mutable msgs : Pp.t list;
  mutable err_range : (int * int) option;
  mutable target_end : int;  (* user's target boundary *)
  mutable goals_dirty : bool;  (* goals need refresh when idle *)
  mutable needs_rewind : Stateid.t option;  (* deferred rewind from callback *)
  mutable state_changed : bool;
  (* Set true when a user-initiated step is in flight (set at the
     editor handler before [step_forward]/[step_backward]/
     [go_to_offset]). Cleared by [consume_user_step_result] once the
     session settles. MCP-initiated steps don't set this, so they
     never trigger the post-step auto-switch. *)
  mutable user_step_pending : bool;
  (* Active multi-call op (currently just queries). At most one op
     can be active. Compound ops own the rocq queue from start to
     finish; verification and other intent dispatch wait until
     [current_op = None]. *)
  mutable current_op : op_state option;
  (* Pending intent slots — picked up by [poll] when [current_op] is
     [None] and rocq is idle. *)
  mutable pending_query : pending_query option;
  mutable pending_fetch : pending_fetch option;
}

let create ?(prog="coqidetop") ?(args=[]) buf =
  let rocq = Rocq_protocol.spawn ~prog ~args () in
  let init_id = Rocq_protocol.init rocq None in
  { rocq; buf; tip = init_id; sentences = [];
    next_edit_id = -1; goals_cache = None; msgs = [];
    err_range = None; target_end = 0;
    goals_dirty = false; needs_rewind = None; state_changed = false;
    user_step_pending = false;
    current_op = None; pending_query = None; pending_fetch = None }

(* Find a sentence by state_id *)
let find_sentence t sid =
  List.find_opt (fun s -> Stateid.equal s.state_id sid) t.sentences

(* Process a single feedback message *)
let process_one_feedback t (fb : Feedback.feedback) =
  let sid = fb.Feedback.span_id in
  match fb.Feedback.contents with
  | Feedback.Processed ->
    (match find_sentence t sid with
     | Some s -> s.status <- Verified; t.state_changed <- true
     | None -> ())
  | Feedback.Message (Feedback.Error, _, _, msg) ->
    (match find_sentence t sid with
     | Some s ->
       s.status <- Error (string_of_pp msg);
       t.msgs <- t.msgs @ [msg];
       t.err_range <- Some (s.start_off, s.end_off);
       t.state_changed <- true
     | None ->
       t.msgs <- t.msgs @ [msg])
  | Feedback.Message (Feedback.Warning, _, _, msg) ->
    t.msgs <- t.msgs @ [Pp.(str "Warning: " ++ msg)];
    t.state_changed <- true
  | Feedback.Message (_, _, _, msg) ->
    t.msgs <- t.msgs @ [msg];
    t.state_changed <- true
  | _ -> ()

let process_feedback t =
  let fbs = Rocq_protocol.drain_feedback t.rocq in
  List.iter (process_one_feedback t) fbs

let verified_end t =
  match t.sentences with
  | s :: _ -> s.end_off
  | [] -> 0


(* Format goals for display.

   [width] is the rendering width used by the Pp pretty-printer for
   hypothesis types and goal conclusions. Each rendered Pp is prefixed
   with two spaces of indentation; the prefix only lands on the first
   line of a multi-line wrap, matching prior behavior. *)
let format_goals ?(all_hyps=true) ?(width=default_width) (gs : Interface.goals) =
  let ob = Stdlib.Buffer.create 256 in
  let pp_to_string pp = string_of_pp ~width pp in
  let fg = gs.Interface.fg_goals in
  let n = List.length fg in
  if n = 0 then begin
    let bg = List.concat_map (fun (l, r) -> l @ r) gs.Interface.bg_goals in
    let shelved = gs.Interface.shelved_goals in
    let given_up = gs.Interface.given_up_goals in
    match bg, shelved, given_up with
    | [], [], [] ->
      Stdlib.Buffer.add_string ob "No more subgoals.\n"
    | [], [], _ ->
      Stdlib.Buffer.add_string ob "All goals completed except some admitted goals:\n\n";
      List.iter (fun (g : Interface.goal) ->
        Stdlib.Buffer.add_string ob ("  " ^ pp_to_string g.Interface.goal_ccl ^ "\n")
      ) given_up;
      Stdlib.Buffer.add_string ob "\nYou need to go back and solve them.\n"
    | [], _, _ ->
      Stdlib.Buffer.add_string ob "All remaining goals are on the shelf:\n\n";
      List.iter (fun (g : Interface.goal) ->
        Stdlib.Buffer.add_string ob ("  " ^ pp_to_string g.Interface.goal_ccl ^ "\n")
      ) shelved
    | _, _, _ ->
      Stdlib.Buffer.add_string ob "This subproof is complete, but there are unfocused goals:\n\n";
      List.iteri (fun i (g : Interface.goal) ->
        let annot = match g.Interface.goal_name with
          | Some name -> Printf.sprintf "(?%s)" name
          | None -> Printf.sprintf "(%d/%d)" (i + 1) (List.length bg)
        in
        Stdlib.Buffer.add_string ob (Printf.sprintf "  ______________________________________%s\n" annot);
        Stdlib.Buffer.add_string ob ("  " ^ pp_to_string g.Interface.goal_ccl ^ "\n\n")
      ) bg
  end else begin
    Stdlib.Buffer.add_string ob (Printf.sprintf "%d subgoal%s\n\n" n (if n > 1 then "s" else ""));
    List.iteri (fun i (g : Interface.goal) ->
      let show_hyps = (i = 0) || all_hyps in
      if show_hyps then begin
        List.iter (fun hyp ->
          Stdlib.Buffer.add_string ob ("  " ^ pp_to_string hyp ^ "\n")
        ) g.Interface.goal_hyp
      end;
      let annot = match g.Interface.goal_name with
        | Some name -> Printf.sprintf "(?%s)" name
        | None -> if n > 1 then Printf.sprintf "(%d/%d)" (i + 1) n else ""
      in
      Stdlib.Buffer.add_string ob
        (Printf.sprintf "  ______________________________________%s\n" annot);
      Stdlib.Buffer.add_string ob ("  " ^ pp_to_string g.Interface.goal_ccl ^ "\n\n")
    ) fg
  end;
  Stdlib.Buffer.contents ob

let rewind_to_state t safe_id =
  let rec drop = function
    | s :: rest when not (Stateid.equal s.state_id safe_id) -> drop rest
    | remaining -> remaining
  in
  t.sentences <- drop t.sentences;
  t.tip <- safe_id;
  t.target_end <- verified_end t;
  Buffer.move_to_byte_offset t.buf (verified_end t);
  t.goals_dirty <- true;
  t.state_changed <- true

(* Compute byte offset and line/bol info for the Add call *)
let line_info_at buf byte_off =
  let line = ref 0 in
  let bol = ref 0 in
  let off = ref 0 in
  while !line < Buffer.line_count buf && !off < byte_off do
    let line_len = String.length (Buffer.get_line buf !line) + 1 in
    if !off + line_len <= byte_off then begin
      off := !off + line_len;
      bol := !off;
      incr line
    end else
      off := byte_off
  done;
  (!line + 1, !bol)

let mk_add_call ~phrase ~edit_id ~tip ~verbose ~bp ~line ~bol =
  Xmlprotocol.add ((((phrase, edit_id), (tip, verbose)), bp), (line, bol))

(* Compute the next sentence to submit toward target_end. Returns
   None if there's nothing more to verify. *)
let next_sentence_phrase t =
  let vend = verified_end t in
  if vend >= t.target_end then None
  else begin
    let text = Buffer.text t.buf in
    match Sentence.find_end text ~start:vend with
    | None -> None
    | Some end_off ->
      let phrase = String.sub text vend (end_off - vend) in
      Some (vend, end_off, phrase)
  end

(* Begin a verification op: submit the next pending sentence as
   an Op_verifying. Caller has already checked [current_op = None]
   and that the rocq queue is idle. *)
let start_verify t =
  match next_sentence_phrase t with
  | None -> ()
  | Some (vend, end_off, phrase) ->
    let eid = t.next_edit_id in
    t.next_edit_id <- eid - 1;
    let (line, bol) = line_info_at t.buf vend in
    let prev_tip = t.tip in
    let s = { start_off = vend; end_off; state_id = Stateid.dummy;
              status = Processing } in
    t.sentences <- s :: t.sentences;
    let call = mk_add_call ~phrase ~edit_id:eid ~tip:prev_tip
      ~verbose:true ~bp:vend ~line ~bol in
    let pending = Rocq_protocol.submit t.rocq call in
    t.current_op <- Some (Op_verifying { vos_sentence = s; vos_pending = pending });
    t.state_changed <- true

(* Find the sentence boundary before a given offset *)
let sentence_start_before t off =
  let rec find = function
    | s :: _ when s.start_off < off -> s.start_off
    | _ :: rest -> find rest
    | [] -> 0
  in
  find t.sentences

(* --- Query op state machine ---

   Bake current Printopts into a transient state so [Stm.query]
   renders with them (see the long comment near [Session.query]
   below for the rationale). The op runs as: send setup sentences
   one at a time → run the query at the resulting tip → restore
   the original tip via [edit_at]. *)

(* Submit the next setup sentence on top of [tip]; build a Qp_setup
   phase referencing the resulting handle. *)
let issue_setup_add t ~remaining ~tip ~next =
  let eid = t.next_edit_id in
  t.next_edit_id <- eid - 1;
  let call = mk_add_call ~phrase:next ~edit_id:eid ~tip
    ~verbose:false ~bp:0 ~line:0 ~bol:0 in
  let pending = Rocq_protocol.submit t.rocq call in
  Qp_setup { remaining; tip; pending }

(* Submit the query at [tip]; build a Qp_query phase. *)
let issue_query t ~pq ~tip =
  let pending = Rocq_protocol.submit t.rocq
    (Xmlprotocol.query (0, (pq.pq_phrase, tip))) in
  Qp_query { tip; pending }

(* Begin a query op from a pending intent. *)
let start_query t (pq : pending_query) =
  let original_tip = t.tip in
  let setup = Printopts.to_vernac_sentences ~override:pq.pq_extra_opts () in
  let msgs_before = t.msgs in
  t.msgs <- [];
  let phase = match setup with
    | [] -> issue_query t ~pq ~tip:original_tip
    | next :: rest -> issue_setup_add t ~remaining:rest ~tip:original_tip ~next
  in
  t.current_op <- Some (Op_query {
    qos_pq = pq;
    qos_original_tip = original_tip;
    qos_msgs_before = msgs_before;
    qos_query_msgs = [];
    qos_phase = phase;
  });
  t.state_changed <- true

let deliver_query_result t qos query_msgs =
  match qos.qos_pq.pq_reply with
  | Qr_msgs -> t.msgs <- query_msgs
  | Qr_external k ->
    t.msgs <- qos.qos_msgs_before;
    k query_msgs

let advance_query_op t qos =
  match qos.qos_phase with
  | Qp_setup s ->
    (match Rocq_protocol.poll_response s.pending with
     | None -> ()
     | Some (Interface.Good (new_id, _)) ->
       process_feedback t;
       t.msgs <- [];  (* discard setup feedback *)
       let phase = match s.remaining with
         | [] -> issue_query t ~pq:qos.qos_pq ~tip:new_id
         | next :: rest -> issue_setup_add t ~remaining:rest ~tip:new_id ~next
       in
       t.current_op <- Some (Op_query { qos with qos_phase = phase });
       t.state_changed <- true
     | Some (Interface.Fail _) ->
       process_feedback t;
       t.msgs <- [];
       (* Setup failed. Run the query at [original_tip] regardless of
          whether earlier setup sentences succeeded — matches prior
          synchronous behavior. If the tip did move, [Qp_query] will
          see [tip ≠ original_tip] and trigger restore. *)
       let phase = issue_query t ~pq:qos.qos_pq ~tip:qos.qos_original_tip in
       t.current_op <- Some (Op_query { qos with qos_phase = phase });
       t.state_changed <- true)
  | Qp_query r ->
    (match Rocq_protocol.poll_response r.pending with
     | None -> ()
     | Some _ ->
       process_feedback t;
       let query_msgs = t.msgs in
       if Stateid.equal r.tip qos.qos_original_tip then begin
         (* No restore needed; deliver immediately. *)
         deliver_query_result t qos query_msgs;
         t.current_op <- None;
         t.state_changed <- true
       end else begin
         let h = Rocq_protocol.submit t.rocq
           (Xmlprotocol.edit_at qos.qos_original_tip) in
         t.current_op <- Some (Op_query {
           qos with
           qos_query_msgs = query_msgs;
           qos_phase = Qp_restore { pending = h };
         });
         t.state_changed <- true
       end)
  | Qp_restore r ->
    (match Rocq_protocol.poll_response r.pending with
     | None -> ()
     | Some _ ->
       process_feedback t;
       (* edit_at may have appended its own feedback to t.msgs; we
          deliver only the previously-captured query_msgs. *)
       deliver_query_result t qos qos.qos_query_msgs;
       t.current_op <- None;
       t.state_changed <- true)

(* Drop sentences whose state was rolled back by an edit_at to
   [target_id]. After a successful edit_at, only sentences below
   target_id remain. If target_id is Stateid.initial, drop all. *)
let drop_above_state target_id sentences =
  if Stateid.equal target_id Stateid.initial then []
  else
    let rec walk = function
      | [] -> []
      | s :: _ as rest when Stateid.equal s.state_id target_id -> rest
      | _ :: rest -> walk rest
    in
    walk sentences

(* Compute the state_id we should land at when rewinding to
   [t.target_end]: state of the topmost sentence whose end_off does
   not exceed target_end, or Stateid.initial if none. *)
let target_id_for_target_end t =
  let rec walk = function
    | [] -> Stateid.initial
    | s :: rest when s.end_off > t.target_end -> walk rest
    | s :: _ -> s.state_id
  in
  walk t.sentences

(* Begin a rewind op: issue [edit_at target_id] and stash it. *)
let start_rewinding t target_id =
  let pending = Rocq_protocol.submit t.rocq (Xmlprotocol.edit_at target_id) in
  t.current_op <- Some (Op_rewinding {
    ros_target_id = target_id;
    ros_pending = pending;
  });
  t.state_changed <- true

let advance_rewinding_op t r =
  match Rocq_protocol.poll_response r.ros_pending with
  | None -> ()
  | Some result ->
    process_feedback t;
    (match result with
     | Interface.Good _ ->
       t.sentences <- drop_above_state r.ros_target_id t.sentences;
       t.tip <- r.ros_target_id;
       t.goals_dirty <- true
     | Interface.Fail (safe_id, _, msg) ->
       t.msgs <- t.msgs @ [Pp.(str "Undo failed: " ++ msg)];
       if not (Stateid.equal safe_id Stateid.dummy) then begin
         (* Rocq landed at safe_id instead. Drop above it. *)
         t.sentences <- drop_above_state safe_id t.sentences;
         t.tip <- safe_id
       end else begin
         (* Rocq couldn't tell us a safe state. If we leave Error
            sentences in [t.sentences], [has_error] stays true and
            [dispatch_idle_work] will issue the same rewind again
            forever (e.g. universe-binding errors that block undo).
            Trim the stack to its contiguous Verified suffix — the
            most we can be sure of — so the loop terminates. The
            user can step manually if they want to recover further. *)
         let oldest_first = List.rev t.sentences in
         let rec take_verified = function
           | s :: rest
             when (match s.status with Verified -> true | _ -> false) ->
             s :: take_verified rest
           | _ -> []
         in
         t.sentences <- List.rev (take_verified oldest_first);
         t.tip <- (match t.sentences with
                   | s :: _ -> s.state_id
                   | [] -> Stateid.initial)
       end;
       (* Snap target up to where we ended up so we don't loop. *)
       t.target_end <- verified_end t;
       t.goals_dirty <- true);
    t.current_op <- None;
    t.state_changed <- true

(* Find the OLDEST errored sentence (deepest in the most-recent-first
   stack) and start an [Op_rewinding] back to just before it. The
   oldest error is the root cause; sentences after it are either
   cascaded failures or unrelated work that's now invalidated, so we
   want to drop them all. Targeting the topmost error instead would
   leave older errors in place — has_error stays true, the next poll
   issues another rewind, and we cascade one sentence per pass. The
   target also lands on a known-Verified state below the bad region,
   which rocq is more likely to accept cleanly. *)
let start_rewind_errors_op t =
  let rec find_oldest_err = function
    | [] -> None
    | s :: rest ->
      (* Recurse first — a deeper Error wins. *)
      match find_oldest_err rest with
      | Some _ as r -> r
      | None ->
        match s.status with
        | Error _ ->
          let target_id = match rest with
            | s2 :: _ -> s2.state_id
            | [] -> Stateid.initial
          in
          Some (rest, target_id, s)
        | _ -> None
  in
  match find_oldest_err t.sentences with
  | None -> ()
  | Some (surviving, target_id, err_s) ->
    t.err_range <- Some (err_s.start_off, err_s.end_off);
    t.target_end <- (match surviving with s :: _ -> s.end_off | [] -> 0);
    start_rewinding t target_id

(* Begin a fetch_goals op: send Printopts (with per-call overrides),
   then fetch goals at the current tip. The formatted result is
   delivered to [pf.pf_on_done] at the end. *)
let start_fetch_goals t (pf : pending_fetch) =
  let opts = Printopts.to_set_options_with pf.pf_extra_opts in
  let pending = Rocq_protocol.submit t.rocq (Xmlprotocol.set_options opts) in
  t.current_op <- Some (Op_fetch_goals {
    fos_pf = pf;
    fos_phase = Fp_set_options pending;
  });
  t.state_changed <- true

let advance_fetch_goals_op t fos =
  match fos.fos_phase with
  | Fp_set_options p ->
    (match Rocq_protocol.poll_response p with
     | None -> ()
     | Some _ ->
       process_feedback t;
       let pending = Rocq_protocol.submit t.rocq (Xmlprotocol.goals ()) in
       t.current_op <- Some (Op_fetch_goals {
         fos with fos_phase = Fp_fetch pending });
       t.state_changed <- true)
  | Fp_fetch p ->
    (match Rocq_protocol.poll_response p with
     | None -> ()
     | Some result ->
       process_feedback t;
       let pf = fos.fos_pf in
       let formatted = match result with
         | Interface.Good (Some gs) ->
           Some (format_goals
             ~all_hyps:pf.pf_all_hyps ~width:pf.pf_width gs)
         | Interface.Good None | Interface.Fail _ -> None
       in
       pf.pf_on_done formatted;
       t.current_op <- None;
       t.state_changed <- true)

(* Begin a goals-refresh op: send Printopts, then queue the goals
   fetch in the second phase. Caller has already cleared
   [goals_dirty]. *)
let start_refresh_goals t =
  let opts = Printopts.to_set_options () in
  let pending = Rocq_protocol.submit t.rocq (Xmlprotocol.set_options opts) in
  t.current_op <- Some (Op_refreshing_goals (Rp_set_options pending));
  t.state_changed <- true

let advance_refreshing_goals_op t = function
  | Rp_set_options p ->
    (match Rocq_protocol.poll_response p with
     | None -> ()
     | Some _ ->
       process_feedback t;
       let pending = Rocq_protocol.submit t.rocq (Xmlprotocol.goals ()) in
       t.current_op <- Some (Op_refreshing_goals (Rp_fetch pending));
       t.state_changed <- true)
  | Rp_fetch p ->
    (match Rocq_protocol.poll_response p with
     | None -> ()
     | Some result ->
       process_feedback t;
       (match result with
        | Interface.Good (Some gs) -> t.goals_cache <- Some gs
        | Interface.Good None | Interface.Fail _ ->
          (* Drop goals_cache. Don't surface a Fail msg — this is an
             internal "couldn't render goals at this state" event, not
             a user-actionable error. The actual error from the prior
             Add is already in [t.msgs]; appending the same wording
             again from the downstream Goals call (e.g. when a
             post-error rewind leaves rocq in a state where Goals
             also Fails with the same universe complaint) would be
             redundant noise. [Rp_set_options] above already ignores
             its result in the same spirit. *)
          t.goals_cache <- None);
       t.current_op <- None;
       t.state_changed <- true)

let advance_verifying_op t v =
  match Rocq_protocol.poll_response v.vos_pending with
  | None -> ()
  | Some result ->
    (* Set state_id BEFORE processing feedback so Processed feedback
       can find the sentence *)
    (match result with
     | Interface.Good (new_id, _) -> v.vos_sentence.state_id <- new_id
     | _ -> ());
    process_feedback t;
    (match result with
     | Interface.Good (new_id, _) ->
       t.tip <- new_id;
       t.goals_dirty <- true
     | Interface.Fail (safe_id, _, msg) ->
       (* Remove the Processing sentence *)
       (match t.sentences with
        | hd :: rest when hd == v.vos_sentence -> t.sentences <- rest
        | _ -> ());
       t.msgs <- t.msgs @ [msg];
       t.err_range <- Some (v.vos_sentence.start_off, v.vos_sentence.end_off);
       t.target_end <- verified_end t;
       (* Don't call rewind_to_state here — defer to poll. Just record
          that we need to rewind. *)
       if not (Stateid.equal safe_id t.tip
               || Stateid.equal safe_id Stateid.dummy) then
         t.needs_rewind <- Some safe_id
       else
         t.tip <- (match t.sentences with
                   | si :: _ -> si.state_id
                   | [] -> Stateid.initial));
    t.current_op <- None;
    t.state_changed <- true

let advance_op t = function
  | Op_query qos -> advance_query_op t qos
  | Op_verifying v -> advance_verifying_op t v
  | Op_refreshing_goals phase -> advance_refreshing_goals_op t phase
  | Op_fetch_goals fos -> advance_fetch_goals_op t fos
  | Op_rewinding r -> advance_rewinding_op t r

(* Dispatch the next intent in priority order. Caller must have
   verified that [current_op = None] and the rocq queue is idle. *)
let dispatch_idle_work t =
  (* Handle deferred rewind from callback *)
  (match t.needs_rewind with
   | Some safe_id ->
     t.needs_rewind <- None;
     rewind_to_state t safe_id
   | None -> ());
  let has_error = List.exists (fun si ->
    match si.status with Error _ -> true | _ -> false
  ) t.sentences in
  if has_error then
    start_rewind_errors_op t
  else if verified_end t > t.target_end then
    (* Deferred rewind from step_backward / go_to_cursor / etc. *)
    start_rewinding t (target_id_for_target_end t)
  else begin
    let vend = verified_end t in
    if vend < t.target_end then
      start_verify t
    else if t.goals_dirty then begin
      t.goals_dirty <- false;
      start_refresh_goals t
    end
    else match t.pending_query with
      | Some pq ->
        t.pending_query <- None;
        start_query t pq
      | None ->
        match t.pending_fetch with
        | Some pf ->
          t.pending_fetch <- None;
          start_fetch_goals t pf
        | None -> ()
  end

(* Poll: process feedback and drive async stepping.
   Returns true if state changed. *)
let poll t =
  Rocq_protocol.poll t.rocq;
  process_feedback t;
  (match t.current_op with
   | Some op -> advance_op t op
   | None -> ());
  (* Re-check after advance_op: it may have cleared current_op. We
     dispatch the next intent in the same poll cycle so [is_busy]
     doesn't briefly drop to false between an op finishing and the
     next intent firing — bridge polls would otherwise observe stale
     state in that window (e.g. an Error feedback that arrived during
     the previous op needs to trigger [start_rewind_errors_op] before
     anyone sees [is_busy = false]). *)
  if t.current_op = None && not (Rocq_protocol.is_busy t.rocq) then
    dispatch_idle_work t;
  let changed = t.state_changed in
  t.state_changed <- false;
  changed

(* --- Public API --- *)

let cursor_byte_offset t =
  let (cl, cc) = Buffer.cursor t.buf in
  let off = ref 0 in
  for i = 0 to cl - 1 do
    off := !off + String.length (Buffer.get_line t.buf i) + 1
  done;
  !off + cc

let step_forward t =
  t.msgs <- [];
  t.err_range <- None;
  let text = Buffer.text t.buf in
  let cur_target = t.target_end in
  match Sentence.find_end text ~start:cur_target with
  | None -> t.msgs <- [Pp.str "No more sentences."]
  | Some end_off ->
    let cursor_off = cursor_byte_offset t in
    t.target_end <- end_off;
    (* Push cursor out if it's now inside the target region *)
    if cursor_off < end_off && cursor_off >= cur_target then
      Buffer.move_to_byte_offset t.buf end_off;
    t.state_changed <- true

let step_backward t =
  t.msgs <- [];
  t.err_range <- None;
  if t.target_end = 0 then
    t.msgs <- [Pp.str "Already at the beginning."]
  else begin
    (* Find the sentence boundary before current target *)
    let old_target = t.target_end in
    let new_target = sentence_start_before t old_target in
    let cursor_off = cursor_byte_offset t in
    t.target_end <- new_target;
    (* Pull cursor back if it was exactly on the old boundary *)
    if cursor_off = old_target then
      Buffer.move_to_byte_offset t.buf new_target;
    t.state_changed <- true
    (* poll picks up the deferred rewind via [target_id_for_target_end]
       once it's idle. *)
  end

let go_to_offset t offset =
  t.err_range <- None;
  t.msgs <- [];
  (* Snap target to the last sentence boundary at or before offset *)
  let text = Buffer.text t.buf in
  let pos = ref 0 in
  let snapped = ref 0 in
  while !pos < offset do
    match Sentence.find_end text ~start:!pos with
    | None -> pos := offset
    | Some end_off ->
      if end_off <= offset then snapped := end_off;
      pos := end_off
  done;
  t.target_end <- !snapped;
  t.state_changed <- true
  (* poll picks up the deferred rewind once idle. *)

let go_to_cursor t =
  let (cur_line, cur_col) = Buffer.cursor t.buf in
  let cursor_off = ref 0 in
  for i = 0 to cur_line - 1 do
    cursor_off := !cursor_off + String.length (Buffer.get_line t.buf i) + 1
  done;
  cursor_off := !cursor_off + cur_col;
  go_to_offset t !cursor_off

(* Per-sentence status info for rendering *)
type sentence_display = {
  sd_start : int;
  sd_end : int;
  sd_status : sentence_status;
}

let sentence_ranges t =
  List.rev_map (fun s ->
    { sd_start = s.start_off; sd_end = s.end_off; sd_status = s.status }
  ) t.sentences

let pending_end t = t.target_end
let error_range t = t.err_range
let clear_error t = t.err_range <- None
let goals_text ?(all_hyps=true) ?(width=default_width) t =
  match t.goals_cache with
  | None -> None
  | Some gs -> Some (format_goals ~all_hyps ~width gs)

let messages ?(width=default_width) t =
  List.map (string_of_pp ~width) t.msgs

let clear_messages t = t.msgs <- []

let set_messages t msgs =
  t.msgs <- List.map Pp.str msgs

let is_busy t =
  Rocq_protocol.is_busy t.rocq || verified_end t < t.target_end
  || t.goals_dirty || t.needs_rewind <> None
  || t.current_op <> None
  || t.pending_query <> None || t.pending_fetch <> None

let set_user_step_pending t = t.user_step_pending <- true

let consume_user_step_result t =
  if t.user_step_pending && not (is_busy t) then begin
    t.user_step_pending <- false;
    if t.err_range <> None then Some `Error else Some `Ok
  end else None

let is_busy_opt = function
  | Some t -> is_busy t
  | None -> false

(* Bake current Printopts into a transient state so [Stm.query] renders
   with them. SetOptions and inline [Set Printing ...] in the query
   phrase don't work: [Stm.query] wraps in [State.purify] which restores
   the snapshot at [at]; multi-sentence phrases iterate with each
   sentence starting from [at]'s snapshot afresh (interp_gen freezes
   the new system into s_cache after each sentence, so the next
   iteration's unfreeze hits a cache miss and reverts Goptions). What
   does work: [Stm.add] freezes live Goptions into the new state's
   snapshot. We Add one [Set Printing X.] per option, query at the
   resulting tip, then [edit_at] back to undo the document mutation.

   Pull-style: this just sets [pending_query]; [Session.poll] picks
   it up when the session is idle and runs it as an [Op_query] state
   machine (see [start_query], [advance_query_op]). Second calls
   while a query is pending are silently dropped.

   Without [on_done] (the editor case), the result lands in [t.msgs]
   so the user sees it. With [on_done] (the MCP case), the callback
   receives the result and the editor's prior [t.msgs] are restored. *)
let query ?(extra_opts=[]) ?on_done t phrase =
  match t.pending_query with
  | Some _ -> ()  (* already pending; drop *)
  | None ->
    let reply = match on_done with
      | None -> Qr_msgs
      | Some k -> Qr_external k
    in
    t.pending_query <- Some {
      pq_phrase = phrase;
      pq_extra_opts = extra_opts;
      pq_reply = reply;
    };
    t.state_changed <- true

(* Async fetch_goals: deliver formatted goals text (or [None] if no
   proof in progress) to [on_done] when the op completes. Drops if
   another fetch is already pending. *)
let start_fetch_goals ?(all_hyps=true) ?(width=default_width)
                      ?(extra_opts=[]) t ~on_done =
  match t.pending_fetch with
  | Some _ -> ()  (* concurrent fetch; drop *)
  | None ->
    t.pending_fetch <- Some {
      pf_all_hyps = all_hyps; pf_width = width;
      pf_extra_opts = extra_opts; pf_on_done = on_done;
    };
    t.state_changed <- true

let sync_options_and_refresh t =
  t.goals_dirty <- true;
  t.state_changed <- true

let pid t = Rocq_protocol.pid t.rocq

let quit t =
  (try Rocq_protocol.quit t.rocq with _ -> ())
