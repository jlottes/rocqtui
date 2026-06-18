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

(** Rendered header + body as styled lines, formatted to [width] columns
    and syntax-highlighted. Cached; recomputed when [width] changes or
    the underlying result changes. *)
val render : width:int -> Styled.line list

(** Force the next {!render} to rebuild (e.g. after a theme change). *)
val invalidate : unit -> unit
