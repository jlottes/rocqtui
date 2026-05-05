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
    flags. ESC starts compose (handled at the editor's compose layer);
    [^G] cancels and restores the saved cursor. The prompt absorbs every
    event — caller never needs to fall through. *)
val handle_search_prompt :
  Editor_context.t -> Input.event -> Tab.t -> Action.action option
