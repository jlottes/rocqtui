(* AI keystroke surface — the single short-circuit point that
   editor.ml calls. Returns [true] when the event was consumed by AI
   handling, [false] when it should fall through to normal dispatch.

   The caller (editor.ml) is responsible for unwrapping
   [Editor_context.ai] and providing the modal-active flag, so this
   module has no dependency on Editor_context — that's what breaks
   the would-be cycle. *)

(* Accept the active tab's ghost into the buffer. *)
let accept (state : State.t) (tab : Tab.t) : bool =
  let pt = State.per_tab state tab.id in
  match pt.ghost with
  | None -> false
  | Some g ->
    let _ok = Apply.accept_all tab ~text:g.text in
    Per_tab.clear pt;
    state.status <- State.Idle;
    true   (* event consumed regardless of whether the buffer accepted *)

(* Accept the first remaining edit in the active tab's edits overlay.
   Edits are applied in document order; after accepting one, the rest
   stay visible (with offsets implicitly re-anchored, since try_replace
   ran on the current buffer state). *)
let accept_one_edit (state : State.t) (tab : Tab.t) : bool =
  let pt = State.per_tab state tab.id in
  match pt.edits with
  | None -> false
  | Some o ->
    (match o.changes with
     | [] -> Per_tab.clear_edits pt; state.status <- State.Idle; true
     | first :: rest ->
       (* Sort by document position so Tab walks in order. *)
       let sorted = List.sort (fun (a : Per_tab.edit_change) b ->
         compare (a.start_line, a.start_col) (b.start_line, b.start_col)
       ) (first :: rest) in
       (match sorted with
        | [] -> true
        | head :: tail ->
          let _ok = Apply.accept_edit tab head in
          o.changes <- tail;
          if tail = [] then begin
            Per_tab.clear_edits pt;
            state.status <- State.Idle
          end;
          true))

let dismiss_edits (state : State.t) (tab : Tab.t) : bool =
  let pt = State.per_tab state tab.id in
  match pt.edits with
  | None -> false
  | Some _ ->
    Per_tab.clear_edits pt;
    state.status <- State.Idle;
    true

(* Accept only the next chunk of the ghost; leave the remainder
   visible at the new cursor position. *)
let accept_word_action (state : State.t) (tab : Tab.t) : bool =
  let pt = State.per_tab state tab.id in
  match pt.ghost with
  | None -> false
  | Some g ->
    (match Apply.accept_word tab ~text:g.text with
     | None ->
       Per_tab.clear pt;
       state.status <- State.Idle;
       true
     | Some consumed ->
       let rest =
         String.sub g.text consumed (String.length g.text - consumed)
       in
       (if String.trim rest = "" then begin
          Per_tab.clear pt;
          state.status <- State.Idle
        end else begin
          let (cur_line, cur_col) = Buffer.cursor tab.buf in
          pt.ghost <- Some {
            Per_tab.text = rest;
            origin_line = cur_line;
            origin_col = cur_col;
            origin_revision = Buffer.revision tab.buf;
          }
        end);
       true)

let dismiss_active (state : State.t) (tab : Tab.t) : bool =
  let pt = State.per_tab state tab.id in
  match pt.ghost with
  | None -> false
  | Some _ ->
    Per_tab.clear pt;
    state.status <- State.Idle;
    true

let toggle (state : State.t) =
  state.enabled <- not state.enabled;
  if not state.enabled then begin
    State.clear_all_ghosts state;
    state.status <- State.Disabled;
    state.in_flight_req_id <- None;
    state.in_flight_tab_id <- None
  end else
    state.status <- State.Idle

(* Match a raw key against the [codes] field of a binding. Used for
   plain Ctrl-letter combinations (Ctrl+G etc.) that arrive as
   [Input.Key (code, _)]. *)
let key_matches (ev : Input.event) (codes : int list) : bool =
  match ev with
  | Input.Key (ch, _) -> List.mem ch codes
  | _ -> false

(* Tab and Escape are remapped to [Input.Special] in the input
   parser, so they don't match [key_matches] against their raw byte
   codes. Match them directly. Accept consumes plain Tab only —
   Shift+Tab still falls through to normal unindent handling. *)
let is_plain_tab ev =
  match ev with
  | Input.Special (Input.Tab, m)
    when not m.shift && not m.ctrl && not m.alt && not m.super -> true
  | _ -> false

let is_escape ev =
  match ev with
  | Input.Special (Input.Escape, _) -> true
  | _ -> false

(* Alt+W arrives as an Input.Key event with the alt modifier set.
   We bypass the keys.ml [kitty_codes] machinery and just match the
   shape directly. *)
let is_alt_w ev =
  match ev with
  | Input.Key (119, m)
    when m.alt && not m.shift && not m.ctrl && not m.super -> true
  | _ -> false

let is_f10 ev =
  match ev with
  | Input.Special (Input.F 10, _) -> true
  | _ -> false

(* Main entry. [modal_active] = true means a modal pane has input
   focus; AI consumes nothing in that case. *)
let try_handle ~state ~modal_active (ev : Input.event) (tab : Tab.t) : bool =
  match state with
  | None -> false
  | Some state ->
    if modal_active then false
    else if key_matches ev Keys.ai_toggle.codes then begin
      toggle state; true
    end
    else if not state.State.enabled then false
    else if is_f10 ev then begin
      Trigger.request_edits state tab; true
    end
    (* Tab accepts edits if any are pending, otherwise the ghost. *)
    else if is_plain_tab ev then begin
      let pt = State.per_tab state tab.id in
      if pt.edits <> None then accept_one_edit state tab
      else accept state tab
    end
    else if is_alt_w ev then
      accept_word_action state tab
    (* Esc dismisses whichever overlay is active. *)
    else if is_escape ev then begin
      let pt = State.per_tab state tab.id in
      if pt.edits <> None then dismiss_edits state tab
      else dismiss_active state tab
    end
    else begin
      (* Implicit dismiss + cancel-in-flight: any other keystroke
         abandons the current prediction so a fresh one can fire after
         the next debounce. Without the cancel, a slow in-flight
         response would block tick from firing again until it returns
         (typically discarded). *)
      let pt = State.per_tab state tab.id in
      if pt.ghost <> None then Per_tab.clear pt;
      if state.State.in_flight_req_id <> None then
        State.cancel_in_flight state;
      false
    end
