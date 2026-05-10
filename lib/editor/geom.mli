(** Screen ↔ buffer/pane coordinate conversion. *)

(** Convert a screen (x, y) to a script buffer (line, byte_col).
    Returns [None] when the coordinates are outside the script pane. *)
val screen_to_buffer_pos :
  Render.t -> Buffer.t -> x:int -> y:int -> (int * int) option

(** Convert a screen (x, y) to (line, byte_col) inside a right-side pane.
    Returns [None] when outside the pane or past the cached lines. *)
val screen_to_pane_pos :
  Tab.t -> Render.t ->
  x:int -> y:int -> [`Goals | `Messages] -> (int * int) option

(** State driving message-pane click/selection: the pane-selection,
    cached wrapped lines, and current scroll for the active sub-tab.
    Rocq state is per-file (from [tab.rocq_msg]); Build/Errors live
    on the global {!Msg_pane}. Terminal sub-tabs aren't text panes. *)
val active_msg_pane_state :
  Tab.t ->
  [ `Text of Tab.pane_selection * Styled.line list * int
  | `Terminal ]

(** Convenience: pane-selection only, used by callers that need to
    update or clear the selection without inspecting cache/scroll. *)
val active_msg_pane_sel : Tab.t -> Tab.pane_selection
