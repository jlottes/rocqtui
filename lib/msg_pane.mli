(** Message-pane sub-tab manager.

    Two surfaces:

    - The **singleton** API ({!ensure}, {!activate}, … no leading
      [_in] suffix) operates on a private default instance. Rocqtui
      uses this exclusively — the bordered message pane has one
      shared tab strip.

    - The **per-instance** API ({!ensure_in}, {!activate_in}, …,
      plus {!create}) is used by [tterm], where each leaf of the
      split layout owns its own sub-tab manager.

    The [Rocq] sub-tab is special in rocqtui: its content is pulled
    from the active file's [Session.messages] each frame, and its
    scroll / selection are stored per-file on [Tab.t]. The sub-tabs
    for [Build], [Errors], [Terminal _] each own their own state in
    full.

    Auto-switching policy lives at action handlers — they call
    {!activate} or {!activate_unless_terminal} explicitly. This
    module never auto-switches in response to passive events. *)

(** What kind of content this sub-tab shows. Equality on
    [Terminal _] is by physical identity. *)
type kind =
  | Rocq
  | Info
  | Build
  | Errors
  | Search
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

(** Display label for a tab — Rocq/Build/Errors are literal,
    Terminal uses the terminal's dynamic title. *)
val display_name : tab -> string

(** {1 Per-instance API} *)

val create : unit -> t

val find_in : t -> kind -> (int * tab) option
val active_tab_in : t -> tab
val active_kind_in : t -> kind
val ensure_in : t -> kind -> tab

(** Like {!ensure_in}, but a newly-created tab is inserted right after
    the first [after] tab (append if [after] is absent). Existing tabs
    are returned unmoved. *)
val ensure_after_in : t -> after:kind -> kind -> tab

val remove_in : t -> kind -> unit
val activate_in : t -> kind -> unit
val activate_unless_terminal_in : t -> kind -> unit
val pop_active_in : t -> unit
val activate_prev_in : t -> unit
val activate_next_in : t -> unit

(** Sync the instance's sub-tab list against [live]: drop Terminal
    sub-tabs whose terminal is not in [live]; append any [live]
    terminal that isn't already a sub-tab. Non-terminal sub-tabs
    untouched. Used by [tterm] so each leaf only "sees" the
    terminals it owns. *)
val sync_terminals_in : t -> Terminal.t list -> unit

(** Remove [tab] from the instance, returning whether it was
    present. The tab record is {b not} freed — the caller is
    expected to hand it to {!insert_in} on the destination
    instance. Used by tterm's drag-tab handling. *)
val take_tab_in : t -> tab -> bool

(** Append [tab] to the instance and make it active. *)
val insert_in : t -> tab -> unit

(** {1 Singleton API}

    Wrappers over a private default instance. Rocqtui uses these. *)

val state : unit -> t
val find : kind -> (int * tab) option
val active_tab : unit -> tab
val active_kind : unit -> kind

(** Idempotent insert. Callers are responsible for ensuring at
    least one tab exists before invoking the [active_*] functions —
    rocqtui ensures [Rocq] at startup; [tterm] ensures the initial
    [Terminal _]. *)
val ensure : kind -> tab

(** Singleton {!ensure_after_in}: ensure [kind], inserting it right after
    the first [after] tab when newly created. *)
val ensure_after : after:kind -> kind -> tab

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
    if the history is exhausted, fall back to the first remaining
    tab (or no-op when there are no tabs at all — the caller, e.g.
    [tterm], is responsible for noticing that case). Called when
    the active tab vanishes (terminal destroyed, Errors emptied). *)
val pop_active : unit -> unit

(** Cycle the active sub-tab. [activate_next] / [activate_prev]
    wrap around. No-op when fewer than two tabs exist. Used by
    [tterm]'s wheel-on-tab-bar handler. *)
val activate_prev : unit -> unit
val activate_next : unit -> unit

(** Sync the singleton's sub-tab list against [Terminal.all ()] —
    rocqtui calls this once per render. Equivalent to
    [sync_terminals_in (state ()) (Terminal.all ())]. *)
val sync_terminals : unit -> unit
