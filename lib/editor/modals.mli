(** Modal event dispatch and query helpers. *)

(** Subject for a query — pane selection if there is one, else the
    word at the script cursor. *)
val query_subject : Tab.t -> string option

(** Run a Rocq query phrase via the session, no-op if no session. *)
val run_query : Session.t option -> string -> unit

(** Dispatch an event to an active Prompt's handler. Pops the prompt
    on Handled or Dismissed. Returns [Some Continue] when handled or
    ignored; [None] when dismissed (caller should re-dispatch). *)
val handle_prompt :
  Editor_context.t ->
  (Input.event -> Modal.prompt_result) ->
  Input.event ->
  Action.action option

(** Dispatch an event to the file picker. Always consumes. *)
val handle_picker :
  Editor_context.t -> File_picker.t -> Input.event -> Action.action

(** While OptionsMenu is open: toggle a print option, or close.
    Returns [None] only on unrecognized non-character events,
    in which case the modal is closed and the event falls through. *)
val handle_options :
  Editor_context.t -> Input.event -> Tab.t -> Action.action option

(** While ThemeMenu is open: pick a theme by digit, then close. *)
val handle_theme : Editor_context.t -> Input.event -> Action.action option

(** While BuildMenu is open: dispatch f/d/a/x/c, then close. *)
val handle_build :
  Editor_context.t -> Input.event -> Tab.t -> Render.t -> Action.action option

(** While QueryMenu is open: dispatch a/c/d/l/g/p/e on the current
    subject, or close on unrecognized key (returning [None]). *)
val handle_query :
  Editor_context.t -> Input.event -> Tab.t -> Action.action option

(** While Help is open: scroll keys, mouse wheel, or close. *)
val handle_help :
  Editor_context.t -> Input.event -> Render.t -> Action.action option

(** While SearchPrompt is open: edit the query, navigate matches, toggle
    flags. ESC (or ESC ESC under compose) cancels via [logical_escape].
    The prompt absorbs every event — caller never needs to fall through. *)
val handle_search_prompt :
  Editor_context.t -> Input.event -> Tab.t -> Action.action option

(** Advance the tab's current match in the given direction and move the
    buffer cursor to it. No-op if search is inactive on this tab. Used
    by both the search prompt and the global F3 / Shift+F3 bindings. *)
val search_advance : Tab.t -> [ `Next | `Prev ] -> unit

(** Append text to whichever prompt field has focus. Find re-runs the
    matcher; Replace just stores. Used by both the printable-character
    handler in the prompt and the compose layer. *)
val append_to_field : Tab.t -> string -> unit

(** Logical-ESC handler. If the search prompt is open, restores the cursor
    to the position saved when the prompt opened, drops search state, and
    pops the prompt. If a search is active without the prompt, drops state
    without moving the cursor. Returns [true] if either path consumed the
    event. *)
val logical_escape : Editor_context.t -> Tab.t -> bool
