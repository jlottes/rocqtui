(* Trigger logic: idle FIM requests + explicit edits-shape requests.

   Single-flight: one request at a time across all tabs. The
   shape-specific handling differs in what it does with the response,
   but the common scaffolding (in-flight tracking, cancellation, error
   reporting, logging) is shared between the two paths. *)

let debounce_seconds = 0.300

(* If the user typed since the request fired, see whether what they
   typed is exactly a prefix of the model's suggestion. If so, the
   suggestion is still relevant — just consumed from its start. *)
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

(* Send a request to the bridge. [shape] is "fim" / "edits" / "auto"
   and drives both the request payload and which response shape we
   honor. FIM responses populate [pt.ghost]; Edit responses populate
   [pt.edits]. *)
let send_request (state : State.t) (tab : Tab.t) ~now ~shape =
  let buf = tab.buf in
  let text = Buffer.text buf in
  let (line, col) = Buffer.cursor buf in
  let origin_offset = Buffer.cursor_byte_offset buf in
  let revision = Buffer.revision buf in
  (* Always send the full recent-edits ring. The bridge's model-based
     classifier inspects the edits to decide shape under "auto"; for
     explicit "fim" / "edits" the bridge ignores them when picking
     shape but uses them as context inside the chosen prompt. *)
  let recent_edits =
    List.map (fun e -> Region_buffer.(e.before, e.after))
      (Region_buffer.recent_edits tab.rb)
  in
  let req_id = Printf.sprintf "r%d-%d" (int_of_float (now *. 1000.)) tab.id in
  let req = Client.build_request ~shape ~req_id ~buffer:text
              ~cursor_line:line ~cursor_col:col ~recent_edits () in
  state.in_flight_req_id <- Some req_id;
  state.in_flight_tab_id <- Some tab.id;
  state.last_request_time <- now;
  state.status <- State.Pending;
  Render_need.request ();
  Debug.log "send req=%s shape=%s tab=%d cursor=%d:%d off=%d rev=%d edits=%d buflen=%d"
    req_id shape tab.id line col origin_offset revision
    (List.length recent_edits) (String.length text);
  let pt = State.per_tab state tab.id in
  (* For an edits-shape request, replace any prior overlay with a
     fresh empty one so streamed Edit responses accumulate cleanly. *)
  if shape = "edits" then begin
    pt.edits <- Some { Per_tab.changes = []; origin_revision = revision };
    pt.ghost <- None
  end;
  let still_mine () = state.in_flight_req_id = Some req_id in
  let clear_in_flight () =
    if still_mine () then begin
      state.in_flight_req_id <- None;
      state.in_flight_tab_id <- None;
      state.in_flight_cancel <- None
    end
  in
  let on_response resp =
    let mine = still_mine () in
    (match resp with
     | Client.Fim { insertion } ->
       Debug.log "<- req=%s fim=%S mine=%b" req_id insertion mine
     | Client.Edit { start_line; start_col; end_line; end_col; replacement } ->
       Debug.log "<- req=%s edit L%d:%d-L%d:%d=%S mine=%b"
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
         pt.ghost <- Some {
           Per_tab.text;
           origin_line = cur_line;
           origin_col = cur_col;
           origin_revision = Buffer.revision buf;
         };
         state.status <- State.Ready
       | _ -> ())
    | Client.Edit { start_line; start_col; end_line; end_col; replacement }
      when mine ->
      (* Stale check: if the user has typed since the request was
         issued, the offsets may not line up with the current buffer.
         Drop the change in that case. *)
      if Buffer.revision buf = revision then begin
        (* If this is the first Edit response on an "auto" shape, we
           may not have an overlay yet (the bridge picked edits via
           classifier). Create one lazily. *)
        let o = match pt.edits with
          | Some o -> o
          | None ->
            let o = { Per_tab.changes = []; origin_revision = revision } in
            pt.edits <- Some o;
            pt.ghost <- None;
            o
        in
        let c = {
          Per_tab.start_line; start_col; end_line; end_col; replacement
        } in
        o.changes <- o.changes @ [c];
        state.status <- State.Ready
      end
    | Client.Done_resp when mine ->
      (* If shape=edits and no changes arrived, drop the empty overlay
         so the status indicator returns to Idle cleanly. *)
      (match pt.edits with
       | Some o when shape = "edits" && o.changes = [] -> pt.edits <- None
       | _ -> ());
      (match state.status with
       | State.Pending -> state.status <- State.Idle
       | _ -> ());
      clear_in_flight ()
    | Client.Error_resp { message; _ } when mine ->
      state.status <- State.Backend_error message;
      clear_in_flight ()
    | _ -> ()
  in
  let handle = Client.send ~socket_path:state.socket_path
                 ~request:req ~on_response in
  (match handle with
   | Some t -> state.in_flight_cancel <- Some (fun () -> Client.cancel t)
   | None -> ())

(* Idle FIM trigger — called per frame from the main loop. *)
let tick (state : State.t) ~now ~last_input_time ~active_tab =
  if not state.enabled then ()
  else if state.in_flight_req_id <> None then ()
  else if last_input_time = 0. then ()
  else if now -. last_input_time < debounce_seconds then ()
  else if last_input_time <= state.last_request_time then ()
  (* Send "auto" — the bridge's model classifier decides between
     FIM, edits, and no-suggestion. Earlier phases hard-coded "fim"
     to bypass a too-eager heuristic; that's no longer needed now
     that the classifier is model-based. *)
  else send_request state active_tab ~now ~shape:"auto"

(* Explicit edits-shape trigger — F10. Cancels any in-flight request
   and issues a fresh edits-shape one. *)
let request_edits (state : State.t) (tab : Tab.t) =
  if state.in_flight_req_id <> None then
    State.cancel_in_flight state;
  send_request state tab ~now:(Unix.gettimeofday ()) ~shape:"edits"
