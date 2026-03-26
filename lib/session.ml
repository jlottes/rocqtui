type sentence_status = Processing | Verified | Error of string

type sentence_info = {
  start_off : int;
  end_off : int;
  state_id : Stateid.t;
  mutable status : sentence_status;
}

type t = {
  rocq : Rocq_protocol.t;
  buf : Buffer.t;
  mutable tip : Stateid.t;
  mutable sentences : sentence_info list;  (* stack, most recent first *)
  mutable next_edit_id : int;
  mutable goals_cache : Interface.goals option;
  mutable msgs : string list;
  mutable err_range : (int * int) option;
}

let create ?(prog="coqidetop") ?(args=[]) buf =
  let rocq = Rocq_protocol.spawn ~prog ~args () in
  let init_id = Rocq_protocol.init rocq None in
  { rocq; buf; tip = init_id; sentences = [];
    next_edit_id = -1; goals_cache = None; msgs = [];
    err_range = None }

(* Find a sentence by state_id *)
let find_sentence t sid =
  List.find_opt (fun s -> Stateid.equal s.state_id sid) t.sentences

(* Process a single feedback message *)
let process_one_feedback t (fb : Feedback.feedback) =
  let sid = fb.Feedback.span_id in
  match fb.Feedback.contents with
  | Feedback.Processed ->
    (match find_sentence t sid with
     | Some s -> s.status <- Verified
     | None -> ())
  | Feedback.Message (Feedback.Error, _, _, msg) ->
    (match find_sentence t sid with
     | Some s ->
       let err_msg = Pp.string_of_ppcmds msg in
       s.status <- Error err_msg;
       t.msgs <- t.msgs @ [err_msg];
       t.err_range <- Some (s.start_off, s.end_off)
     | None ->
       t.msgs <- t.msgs @ [Pp.string_of_ppcmds msg])
  | Feedback.Message (Feedback.Warning, _, _, msg) ->
    t.msgs <- t.msgs @ ["Warning: " ^ Pp.string_of_ppcmds msg]
  | Feedback.Message (_, _, _, msg) ->
    t.msgs <- t.msgs @ [Pp.string_of_ppcmds msg]
  | _ -> ()

(* Drain all pending feedback and process it *)
let process_feedback t =
  let fbs = Rocq_protocol.drain_feedback t.rocq in
  List.iter (process_one_feedback t) fbs

(* Poll for new feedback without blocking *)
let poll t =
  Rocq_protocol.poll_feedback t.rocq;
  process_feedback t

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
    let result = Rocq_protocol.edit_at t.rocq target_id in
    process_feedback t;
    (match result with
     | Interface.Good _ -> ()
     | Interface.Fail _ -> ());
    Buffer.move_to_byte_offset t.buf (verified_end t)

(* Format goals for display *)
let format_goals ?(all_hyps=true) (gs : Interface.goals) =
  let ob = Stdlib.Buffer.create 256 in
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
        Stdlib.Buffer.add_string ob ("  " ^ Pp.string_of_ppcmds g.Interface.goal_ccl ^ "\n")
      ) given_up;
      Stdlib.Buffer.add_string ob "\nYou need to go back and solve them.\n"
    | [], _, _ ->
      Stdlib.Buffer.add_string ob "All remaining goals are on the shelf:\n\n";
      List.iter (fun (g : Interface.goal) ->
        Stdlib.Buffer.add_string ob ("  " ^ Pp.string_of_ppcmds g.Interface.goal_ccl ^ "\n")
      ) shelved
    | _, _, _ ->
      Stdlib.Buffer.add_string ob "This subproof is complete, but there are unfocused goals:\n\n";
      List.iteri (fun i (g : Interface.goal) ->
        let annot = match g.Interface.goal_name with
          | Some name -> Printf.sprintf "(?%s)" name
          | None -> Printf.sprintf "(%d/%d)" (i + 1) (List.length bg)
        in
        Stdlib.Buffer.add_string ob (Printf.sprintf "  ______________________________________%s\n" annot);
        Stdlib.Buffer.add_string ob ("  " ^ Pp.string_of_ppcmds g.Interface.goal_ccl ^ "\n\n")
      ) bg
  end else begin
    Stdlib.Buffer.add_string ob (Printf.sprintf "%d subgoal%s\n\n" n (if n > 1 then "s" else ""));
    List.iteri (fun i (g : Interface.goal) ->
      let show_hyps = (i = 0) || all_hyps in
      if show_hyps then begin
        List.iter (fun hyp ->
          Stdlib.Buffer.add_string ob ("  " ^ Pp.string_of_ppcmds hyp ^ "\n")
        ) g.Interface.goal_hyp
      end;
      let annot = match g.Interface.goal_name with
        | Some name -> Printf.sprintf "(?%s)" name
        | None -> if n > 1 then Printf.sprintf "(%d/%d)" (i + 1) n else ""
      in
      Stdlib.Buffer.add_string ob
        (Printf.sprintf "  ______________________________________%s\n" annot);
      Stdlib.Buffer.add_string ob ("  " ^ Pp.string_of_ppcmds g.Interface.goal_ccl ^ "\n\n")
    ) fg
  end;
  Stdlib.Buffer.contents ob

let refresh_goals t =
  let opts = Printopts.to_set_options () in
  ignore (Rocq_protocol.set_options t.rocq opts);
  process_feedback t;
  match Rocq_protocol.goals t.rocq with
  | Interface.Good (Some gs) ->
    process_feedback t;
    t.goals_cache <- Some gs
  | Interface.Good None ->
    process_feedback t;
    t.goals_cache <- None
  | Interface.Fail (_, _, msg) ->
    process_feedback t;
    t.msgs <- t.msgs @ [Pp.string_of_ppcmds msg];
    t.goals_cache <- None

let rewind_to_state t safe_id =
  let rec drop = function
    | s :: rest when not (Stateid.equal s.state_id safe_id) -> drop rest
    | remaining -> remaining
  in
  t.sentences <- drop t.sentences;
  t.tip <- safe_id;
  Buffer.move_to_byte_offset t.buf (verified_end t);
  refresh_goals t

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

(* Internal step functions — don't clear messages *)
let step_forward_inner t =
  t.err_range <- None;
  let text = Buffer.text t.buf in
  let start = verified_end t in
  match Sentence.find_end text ~start with
  | None ->
    t.msgs <- t.msgs @ ["No more sentences."]
  | Some end_off ->
    let phrase = String.sub text start (end_off - start) in
    let eid = t.next_edit_id in
    t.next_edit_id <- eid - 1;
    let (line, bol) = line_info_at t.buf start in
    let result = Rocq_protocol.add t.rocq
      ~state_id:t.tip ~edit_id:eid ~verbose:true
      ~bp:start ~line ~bol phrase in
    process_feedback t;
    match result with
    | Interface.Good (new_id, _) ->
      let s = { start_off = start; end_off; state_id = new_id;
                status = Processing } in
      t.sentences <- s :: t.sentences;
      t.tip <- new_id;
      Buffer.move_to_byte_offset t.buf end_off;
      refresh_goals t;
      process_feedback t;
      rewind_errors t
    | Interface.Fail (safe_id, _, msg) ->
      t.msgs <- t.msgs @ [Pp.string_of_ppcmds msg];
      t.err_range <- Some (start, end_off);
      if not (Stateid.equal safe_id t.tip
              || Stateid.equal safe_id Stateid.dummy) then
        rewind_to_state t safe_id

let step_backward_inner t =
  t.err_range <- None;
  match t.sentences with
  | [] ->
    t.msgs <- t.msgs @ ["Already at the beginning."]
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
       Buffer.move_to_byte_offset t.buf (verified_end t);
       refresh_goals t
     | Interface.Fail (safe_id, _, msg) ->
       t.msgs <- t.msgs @ ["Undo failed: " ^ Pp.string_of_ppcmds msg];
       if not (Stateid.equal safe_id t.tip
               || Stateid.equal safe_id Stateid.dummy) then
         rewind_to_state t safe_id)

(* Public wrappers that clear messages *)
let step_forward t =
  t.msgs <- [];
  step_forward_inner t

let step_backward t =
  t.msgs <- [];
  step_backward_inner t

let go_to_cursor ?render t =
  t.err_range <- None;
  t.msgs <- [];
  let (cur_line, cur_col) = Buffer.cursor t.buf in
  let target_off = ref 0 in
  for i = 0 to cur_line - 1 do
    target_off := !target_off + String.length (Buffer.get_line t.buf i) + 1
  done;
  target_off := !target_off + cur_col;
  let target = !target_off in
  let vend = verified_end t in
  if target > vend then begin
    let keep_going = ref true in
    while !keep_going do
      let cur_end = verified_end t in
      if cur_end >= target then
        keep_going := false
      else begin
        let text = Buffer.text t.buf in
        match Sentence.find_end text ~start:cur_end with
        | None -> keep_going := false
        | Some end_off ->
          let prev_end = verified_end t in
          step_forward_inner t;
          (* Render between steps if callback provided *)
          (match render with Some f -> f () | None -> ());
          if verified_end t = prev_end then
            keep_going := false
          else if end_off >= target then
            keep_going := false
      end
    done
  end else if target < vend then begin
    let keep_going = ref true in
    while !keep_going do
      match t.sentences with
      | s :: _ when s.start_off >= target ->
        let n_before = List.length t.sentences in
        step_backward_inner t;
        let n_after = List.length t.sentences in
        if t.sentences = [] || n_after >= n_before then
          keep_going := false
      | _ -> keep_going := false
    done
  end

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

let error_range t = t.err_range
let clear_error t = t.err_range <- None
let goals_text ?(all_hyps=true) t =
  match t.goals_cache with
  | None -> None
  | Some gs -> Some (format_goals ~all_hyps gs)
let messages t = t.msgs
let clear_messages t = t.msgs <- []

let is_busy _ = false

let query t phrase =
  t.msgs <- [];
  let opts = Printopts.to_set_options () in
  ignore (Rocq_protocol.set_options t.rocq opts);
  process_feedback t;
  Rocq_protocol.query t.rocq ~state_id:t.tip phrase;
  process_feedback t

let sync_options_and_refresh t =
  let opts = Printopts.to_set_options () in
  ignore (Rocq_protocol.set_options t.rocq opts);
  process_feedback t;
  refresh_goals t

let pid t = Rocq_protocol.pid t.rocq

let quit t =
  (try Rocq_protocol.quit t.rocq with _ -> ())
