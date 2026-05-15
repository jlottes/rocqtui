(* Idle-trigger logic: per frame, decides whether to fire a new AI
   suggestion request.

   Single-flight: a request is issued only when no other request is
   in flight (per the global-state convention). On response, the
   active tab's [Per_tab.ghost] is populated. *)

let debounce_seconds = 0.300

(* If the user typed since the request fired, see whether what they
   typed is exactly a prefix of the model's suggestion. If so, the
   suggestion is still relevant — just consumed from its start. We
   return the trimmed suggestion plus the new cursor position to
   anchor it on. Returns None if the suggestion no longer applies
   (typed something else, deleted, etc.). *)
let shifted_insertion ~origin_offset ~insertion buf =
  let cur_offset = Buffer.cursor_byte_offset buf in
  let cur_text = Buffer.text buf in
  let delta = cur_offset - origin_offset in
  if delta = 0 then
    Some insertion
  else if delta > 0
       && delta < String.length insertion
       && origin_offset + delta <= String.length cur_text
       && String.sub cur_text origin_offset delta
          = String.sub insertion 0 delta
  then
    Some (String.sub insertion delta (String.length insertion - delta))
  else
    None

let send_request (state : State.t) (tab : Tab.t) ~now =
  let buf = tab.buf in
  let text = Buffer.text buf in
  let (line, col) = Buffer.cursor buf in
  let origin_offset = Buffer.cursor_byte_offset buf in
  let revision = Buffer.revision buf in
  (* Phase 1 only renders FIM ghosts. The bridge's classifier uses
     [len(recent_edits) >= 2 → edits-shape], which would route any
     reasonably-typed session straight into edits-shape responses
     that we silently drop. Cap at 1 here so the bridge always picks
     FIM. Phase 3 will lift this. *)
  let recent_edits =
    let all =
      List.map (fun e -> Region_buffer.(e.before, e.after))
        (Region_buffer.recent_edits tab.rb)
    in
    match List.rev all with
    | [] -> []
    | newest :: _ -> [newest]
  in
  let req_id = Printf.sprintf "r%d-%d" (int_of_float (now *. 1000.)) tab.id in
  let req = Client.build_request ~req_id ~buffer:text
              ~cursor_line:line ~cursor_col:col ~recent_edits in
  state.in_flight_req_id <- Some req_id;
  state.in_flight_tab_id <- Some tab.id;
  state.last_request_time <- now;
  state.status <- State.Pending;
  (* Make the Pending status visible immediately. Without this, the
     main loop has no reason to re-render between "fire request" and
     "response arrives", so the Pending glyph never appears — the user
     only sees Idle → Ready (or Idle → Idle on a discard). *)
  Render_need.request ();
  Debug.log "send req=%s tab=%d cursor=%d:%d off=%d rev=%d edits=%d buflen=%d"
    req_id tab.id line col origin_offset revision
    (List.length recent_edits) (String.length text);
  let still_mine () = state.in_flight_req_id = Some req_id in
  let clear_in_flight () =
    if still_mine () then begin
      state.in_flight_req_id <- None;
      state.in_flight_tab_id <- None;
      state.in_flight_cancel <- None
    end
  in
  let on_response resp =
    (* Log every response we see — including ones we don't act on —
       so the debug log is a complete trace of bridge traffic. *)
    let mine = still_mine () in
    (match resp with
     | Client.Fim { insertion } ->
       Debug.log "<- req=%s fim=%S mine=%b" req_id insertion mine
     | Client.Edit { start_line; start_col; end_line; end_col; replacement } ->
       Debug.log "<- req=%s edit L%d:%d-L%d:%d=%S mine=%b ignored=phase1"
         req_id start_line start_col end_line end_col replacement mine
     | Client.Error_resp { message; code } ->
       Debug.log "<- req=%s error code=%s msg=%s mine=%b"
         req_id code message mine
     | Client.Done_resp ->
       Debug.log "<- req=%s done mine=%b" req_id mine);
    match resp with
    | Client.Fim { insertion } when mine ->
      let shifted = shifted_insertion ~origin_offset ~insertion buf in
      let cur_off = Buffer.cursor_byte_offset buf in
      Debug.log "   typed=%d shifted=%s"
        (cur_off - origin_offset)
        (match shifted with None -> "<discard>"
                          | Some s -> Printf.sprintf "%S" s);
      (match shifted with
       | Some text when String.trim text <> "" ->
         let (cur_line, cur_col) = Buffer.cursor buf in
         let pt = State.per_tab state tab.id in
         pt.ghost <- Some {
           Per_tab.text;
           origin_line = cur_line;
           origin_col = cur_col;
           origin_revision = Buffer.revision buf;
         };
         state.status <- State.Ready
       | _ -> ())
    | Client.Done_resp when mine ->
      (match state.status with
       | State.Pending -> state.status <- State.Idle
       | _ -> ());
      clear_in_flight ()
    | Client.Error_resp { message; _ } when mine ->
      state.status <- State.Backend_error message;
      clear_in_flight ()
    | _ -> ()
    (* Phase 1 ignores Edit responses for rendering; logged above. *)
  in
  let handle = Client.send ~socket_path:state.socket_path
                 ~request:req ~on_response in
  (match handle with
   | Some t -> state.in_flight_cancel <- Some (fun () -> Client.cancel t)
   | None -> ())

(* Called per frame. Issues a request when appropriate. *)
let tick (state : State.t) ~now ~last_input_time ~active_tab =
  if not state.enabled then ()
  else if state.in_flight_req_id <> None then ()
  else if last_input_time = 0. then ()
  else if now -. last_input_time < debounce_seconds then ()
  else if last_input_time <= state.last_request_time then ()
  else send_request state active_tab ~now
