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
}

let create ?(prog="coqidetop") ?(args=[]) buf =
  let rocq = Rocq_protocol.spawn ~prog ~args () in
  let init_id = Rocq_protocol.init rocq None in
  { rocq; buf; tip = init_id; sentences = [];
    next_edit_id = -1; goals_cache = None; msgs = [];
    err_range = None; target_end = 0;
    goals_dirty = false; needs_rewind = None; state_changed = false;
    user_step_pending = false }

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

(* Rewind errored sentences *)
let rewind_errors t =
  let rec find_and_drop = function
    | [] -> None
    | s :: rest ->
      match s.status with
      | Error _ ->
        let target_id = match rest with
          | s2 :: _ -> s2.state_id
          | [] -> Stateid.initial
        in
        Some (rest, target_id, s)
      | _ ->
        match find_and_drop rest with
        | Some (surviving, target_id, err_s) ->
          Some (surviving, target_id, err_s)
        | None -> None
  in
  match find_and_drop t.sentences with
  | None -> ()
  | Some (surviving, target_id, err_s) ->
    t.err_range <- Some (err_s.start_off, err_s.end_off);
    t.sentences <- surviving;
    t.tip <- target_id;
    (* Snap target back to error *)
    t.target_end <- (match surviving with s :: _ -> s.end_off | [] -> 0);
    let result = Rocq_protocol.edit_at t.rocq target_id in
    process_feedback t;
    (match result with Interface.Good _ -> () | Interface.Fail _ -> ());
    t.goals_dirty <- true;
    t.state_changed <- true

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

let [@warning "-32"] refresh_goals t =
  let opts = Printopts.to_set_options () in
  ignore (Rocq_protocol.set_options t.rocq opts);
  process_feedback t;
  match Rocq_protocol.goals t.rocq with
  | Interface.Good (Some gs) ->
    process_feedback t;
    t.goals_cache <- Some gs;
    t.state_changed <- true
  | Interface.Good None ->
    process_feedback t;
    t.goals_cache <- None;
    t.state_changed <- true
  | Interface.Fail (_, _, msg) ->
    process_feedback t;
    t.msgs <- t.msgs @ [msg];
    t.goals_cache <- None;
    t.state_changed <- true

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

(* Async: submit next sentence toward target_end *)
let submit_next_sentence t =
  if Rocq_protocol.is_busy t.rocq then ()
  else begin
    let vend = verified_end t in
    if vend >= t.target_end then ()  (* already caught up *)
    else begin
      let text = Buffer.text t.buf in
      match Sentence.find_end text ~start:vend with
      | None -> ()
      | Some end_off ->
        let phrase = String.sub text vend (end_off - vend) in
        let eid = t.next_edit_id in
        t.next_edit_id <- eid - 1;
        let (line, bol) = line_info_at t.buf vend in
        let prev_tip = t.tip in
        let s = { start_off = vend; end_off; state_id = Stateid.dummy;
                  status = Processing } in
        t.sentences <- s :: t.sentences;
        t.state_changed <- true;
        let call = Xmlprotocol.add
          ((((phrase, eid), (prev_tip, true)), vend), (line, bol)) in
        Rocq_protocol.send_call t.rocq call
          (fun result ->
             (* Set state_id BEFORE processing feedback so Processed
                feedback can find the sentence *)
             (match result with
              | Interface.Good (new_id, _) -> s.state_id <- new_id
              | _ -> ());
             process_feedback t;
             match result with
             | Interface.Good (new_id, _) ->
               t.tip <- new_id;
               t.state_changed <- true;
               t.goals_dirty <- true;
               (* Don't call rewind_errors here — it uses eval_call
                  which would deadlock inside the watch callback.
                  Errors will be detected and handled in poll. *)
             | Interface.Fail (safe_id, _, msg) ->
               (* Remove the Processing sentence *)
               (match t.sentences with
                | hd :: rest when hd == s -> t.sentences <- rest
                | _ -> ());
               t.msgs <- t.msgs @ [msg];
               t.err_range <- Some (vend, end_off);
               t.target_end <- verified_end t;
               t.state_changed <- true;
               (* Don't call rewind_to_state here — defer to poll.
                  Just record that we need to rewind. *)
               if not (Stateid.equal safe_id t.tip
                       || Stateid.equal safe_id Stateid.dummy) then
                 t.needs_rewind <- Some safe_id
               else
                 t.tip <- (match t.sentences with
                           | si :: _ -> si.state_id
                           | [] -> Stateid.initial))
    end
  end

(* Sync: rewind verified region to match target *)
let rewind_to_target t =
  while verified_end t > t.target_end do
    match t.sentences with
    | [] -> ()  (* shouldn't happen *)
    | _ :: rest ->
      let target_id = match rest with
        | s :: _ -> s.state_id
        | [] -> Stateid.initial
      in
      let result = Rocq_protocol.edit_at t.rocq target_id in
      process_feedback t;
      (match result with
       | Interface.Good _ ->
         t.sentences <- rest;
         t.tip <- target_id;
         t.state_changed <- true
       | Interface.Fail (safe_id, _, msg) ->
         t.msgs <- t.msgs @ [Pp.(str "Undo failed: " ++ msg)];
         if not (Stateid.equal safe_id t.tip
                 || Stateid.equal safe_id Stateid.dummy) then
           rewind_to_state t safe_id;
         (* Break the loop *)
         t.target_end <- verified_end t)
  done

(* Find the sentence boundary before a given offset *)
let sentence_start_before t off =
  let rec find = function
    | s :: _ when s.start_off < off -> s.start_off
    | _ :: rest -> find rest
    | [] -> 0
  in
  find t.sentences

(* Poll: process feedback and drive async stepping.
   Returns true if state changed. *)
let poll t =
  Rocq_protocol.poll t.rocq;
  process_feedback t;
  if not (Rocq_protocol.is_busy t.rocq) then begin
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
      rewind_errors t
    else if verified_end t > t.target_end then begin
      (* Deferred rewind from step_backward/go_to_cursor *)
      rewind_to_target t;
      t.goals_dirty <- true
    end
    else if not (Rocq_protocol.is_busy t.rocq) then begin
      let vend = verified_end t in
      if vend < t.target_end then
        submit_next_sentence t
      else if t.goals_dirty then begin
        t.goals_dirty <- false;
        let opts = Printopts.to_set_options () in
        Rocq_protocol.send_call t.rocq
          (Xmlprotocol.set_options opts)
          (fun _result ->
             process_feedback t;
             Rocq_protocol.send_call t.rocq
               (Xmlprotocol.goals ())
               (fun result ->
                  process_feedback t;
                  (match result with
                   | Interface.Good (Some gs) ->
                     t.goals_cache <- Some gs
                   | Interface.Good None ->
                     t.goals_cache <- None
                   | Interface.Fail (_, _, msg) ->
                     t.msgs <- t.msgs @ [msg];
                     t.goals_cache <- None);
                  t.state_changed <- true))
      end
    end
  end;
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
    t.state_changed <- true;
    (* If verified > target, rewind. If busy, defer to poll. *)
    if verified_end t > t.target_end then begin
      if Rocq_protocol.is_busy t.rocq then
        (* Can't rewind yet — poll will handle it when the in-flight call completes *)
        ()
      else begin
        rewind_to_target t;
        t.goals_dirty <- true
      end
    end
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
  t.state_changed <- true;
  if verified_end t > t.target_end then begin
    if Rocq_protocol.is_busy t.rocq then
      ()
    else begin
      rewind_to_target t;
      t.goals_dirty <- true
    end
  end

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
   resulting tip, then [edit_at] back to undo the document mutation. *)
let query ?(extra_opts=[]) t phrase =
  t.msgs <- [];
  let prev_tip = t.tip in
  let setup = Printopts.to_vernac_sentences ~override:extra_opts () in
  let final_tip = ref prev_tip in
  let setup_ok = ref true in
  List.iter (fun sent ->
    if !setup_ok then begin
      let eid = t.next_edit_id in
      t.next_edit_id <- eid - 1;
      match Rocq_protocol.add t.rocq
        ~state_id:!final_tip ~edit_id:eid ~verbose:false
        ~bp:0 ~line:0 ~bol:0 sent with
      | Interface.Good (new_id, _) -> final_tip := new_id
      | Interface.Fail _ -> setup_ok := false
    end
  ) setup;
  process_feedback t;
  (* Discard any feedback from the setup sentences; the user only
     wants to see output from their actual query. *)
  t.msgs <- [];
  let query_at = if !setup_ok then !final_tip else prev_tip in
  Rocq_protocol.query t.rocq ~state_id:query_at phrase;
  process_feedback t;
  let query_msgs = t.msgs in
  if !final_tip <> prev_tip then begin
    ignore (Rocq_protocol.edit_at t.rocq prev_tip);
    process_feedback t
  end;
  t.msgs <- query_msgs

(* Synchronously fetch goals and format them *)
let fetch_goals_text ?(all_hyps=true) ?(width=default_width) ?(extra_opts=[]) t =
  let opts = Printopts.to_set_options_with extra_opts in
  ignore (Rocq_protocol.set_options t.rocq opts);
  process_feedback t;
  match Rocq_protocol.goals t.rocq with
  | Interface.Good (Some gs) ->
    process_feedback t;
    Some (format_goals ~all_hyps ~width gs)
  | Interface.Good None ->
    process_feedback t; None
  | Interface.Fail _ ->
    process_feedback t; None

let sync_options_and_refresh t =
  t.goals_dirty <- true;
  t.state_changed <- true

let pid t = Rocq_protocol.pid t.rocq

let quit t =
  (try Rocq_protocol.quit t.rocq with _ -> ())
