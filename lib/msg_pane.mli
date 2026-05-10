(** Global message-pane sub-tab manager.

    The message pane (the bordered region on the right showing Rocq
    output, build output, errors, terminals) has its own bar of
    sub-tabs. Those sub-tabs are global — they don't change shape
    when the user switches between file tabs.

    The [Rocq] sub-tab is special: its content is pulled from the
    active file's [Session.messages] each frame, and its scroll /
    selection are stored per-file on [Tab.t]. The sub-tabs for
    [Build], [Errors], [Terminal _] each own their own state in
    full.

    Auto-switching policy lives at action handlers — they call
    {!activate} or {!activate_unless_terminal} explicitly. This
    module never auto-switches in response to passive events. *)

(** What kind of content this sub-tab shows. Equality on
    [Terminal _] is by physical identity. *)
type kind =
  | Rocq
  | Build
  | Errors
  | Terminal of Terminal.t

val kind_eq : kind -> kind -> bool

type tab = {
  kind : kind;
  mutable lines : Styled.line list;
  mutable scroll : int;
  sel : Tab.pane_selection;
  mutable lines_cache : Styled.line list;
}

type t = {
  mutable tabs : tab list;
  mutable active : int;
  (** MRU stack of previously-active kinds; the current active is
      {b not} included; deduplicated so each kind appears at most
      once. *)
  mutable history : kind list;
}

(** The single global instance. *)
val state : unit -> t

val active_tab : unit -> tab
val active_kind : unit -> kind
val find : kind -> (int * tab) option

(** Idempotent insert. The [Rocq] tab is created on first access
    and never removed. *)
val ensure : kind -> tab

(** Remove a sub-tab. If it was active, falls back via {!pop_active}.
    Also drops the kind from {!history}. *)
val remove : kind -> unit

(** Activate [kind]. If [kind] doesn't exist as a tab, no-op (caller
    should {!ensure} first if appropriate). Pushes the previously
    active kind onto {!history} (deduplicated). *)
val activate : kind -> unit

(** Like {!activate}, but no-op when the active tab is a
    [Terminal _]. Used for actions whose intent is dual (e.g. F5
    might mean "trigger a build" rather than "watch the build"),
    so we don't yank focus out of a terminal session. *)
val activate_unless_terminal : kind -> unit

(** Restore the most-recently-used existing tab from {!history};
    fallback to [Rocq] if the history is exhausted. Called when
    the active tab vanishes (terminal destroyed, Errors emptied). *)
val pop_active : unit -> unit

(** Display label for a tab — Rocq/Build/Errors are literal,
    Terminal uses the terminal's dynamic title. *)
val display_name : tab -> string

(** Sync sub-tab list against [Terminal.all ()]: append entries
    for new terminals, remove entries whose terminals were
    destroyed. If the active tab was a destroyed terminal, falls
    back via {!pop_active}. *)
val sync_terminals : unit -> unit
