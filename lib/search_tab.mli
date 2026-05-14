(** Render the Search messages-tab body.

    Mirrors [Build_errors.render_errors_tab] in shape: produces a flat
    list of [Styled.line]s (file-header rows interleaved with match
    rows) plus the row offset of the current match (so the caller can
    auto-scroll to it). Also stashes a row→entry reverse map readable
    via [lookup_tab_row] so the click handler can translate body-row
    clicks back into (file, match_index) coordinates. *)

val render :
  Search_results.t option ->
  Styled.line list * int option

(** Row index → (file_path, match_index). [None] = file-header row or
    out-of-bounds. *)
val lookup_tab_row : int -> (string * int) option
