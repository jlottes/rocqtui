(** Live "About / Print" info for the identifier under the cursor.

    A single, global (not per-tab) anticipated query result, shown in the
    [Info] message sub-tab. Collapsed shows the [About <id>.] output;
    expanding fires [Print <id>.] and replaces the body with it.

    Only successful queries ever replace the displayed result — an error
    (cursor on a keyword, a not-yet-defined name, mid-proof tactic
    syntax, …) is discarded so the last good result stays on screen.
    See [docs/LIVE_INFO_PLAN.md]. *)

(** Per-frame driver. Recomputes the qualified identifier at [buf]'s
    cursor and, when [session] is idle, issues [About] for it (deduped
    so each subject is queried at most once until the cursor moves).
    Lazily fetches [Print] when expanded. Caller should only invoke this
    when the Info pane is actually on screen. *)
val tick : Session.t option -> Buffer.t -> unit

(** Whether there is a result to display yet. *)
val has_content : unit -> bool

(** Subject of the currently displayed result, if any. *)
val current_subject : unit -> string option

(** Collapsed (About) vs expanded (Print). *)
val is_expanded : unit -> bool

(** Toggle collapse/expand. The [Print] fetch happens lazily on the
    next idle {!tick}. *)
val toggle_expand : unit -> unit

(** Whether the displayed result is pinned (frozen against
    cursor-following). *)
val is_pinned : unit -> bool

(** Pin the current result (no-op if there's nothing shown), or unpin.
    While pinned the subject is frozen and re-queries target the
    originating session, so the pin survives switching file tabs; it
    still re-queries when that session's tip or the print options change.
    Unpinning resumes cursor-following. *)
val toggle_pin : unit -> unit

(** The qualified identifier under [buf]'s cursor (dotted names), falling
    back to the plain word — the same choice the live tick uses. *)
val subject_at_cursor : Buffer.t -> string option

(** Re-pin to subject [w] queried against session [s] (used by ^A while
    pinned). On success [w] replaces the pinned entry and the pinned
    state is kept; on failure the error is shown in the top row and the
    current entry is left intact. *)
val repin : Session.t -> string -> unit

(** Append the current (main) item to the saved list as a live entry
    (deduped by subject + session); no-op when nothing is shown. *)
val append_current : unit -> unit

(** Remove the [i]th saved entry (0-based, top to bottom). *)
val remove_entry : int -> unit

(** Cycle the [i]th saved entry's collapse level: type → +definition →
    +information → type. *)
val cycle_entry : int -> unit

(** Resolve a click at wrapped-row [row], content column [col] to an
    action on the pane's header glyphs. Rows are indices into the lines
    last returned by {!render}; [`None] when the click hits no glyph.
    [`Goto] / [`EntryGoto i] are the 🔍 go-to-definition glyphs. *)
val target_at :
  row:int -> col:int ->
  [ `None | `Expand | `Pin | `Append | `Goto
  | `Cycle of int | `Remove of int | `EntryGoto of int ]

(** (session, subject) for resolving a go-to-definition: the main item,
    or the [i]th saved entry — each via the session its result came from.
    [None] when there's nothing to resolve. *)
val main_locate : unit -> (Session.t * string) option
val entry_locate : int -> (Session.t * string) option

(** Rendered pane as styled lines, formatted and wrapped to [width]
    columns and syntax-highlighted (reserved error row, main item, then
    the saved list). The lines are already wrapped, so the caller must
    render them with wrapping disabled; row indices line up with
    {!target_at}. Cached; recomputed when [width] or the content changes. *)
val render : width:int -> Styled.line list

(** Force the next {!render} to rebuild (e.g. after a theme change). *)
val invalidate : unit -> unit
