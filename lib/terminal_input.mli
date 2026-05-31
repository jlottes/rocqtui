(** Keybindings that rocqtui intercepts while a terminal sub-tab is
    focused. The exact set is shared between rocqtui (called by
    [Editor.handle_event]) and [tterm] (called unconditionally for
    every keyboard event), so behavior cannot drift between the two
    binaries.

    Anything not in the intercepted set returns {!Pass_to_term} and
    should be forwarded to the active terminal by the caller. *)

type result =
  | Continue
    (** Handled inline (e.g. copy, compose-start). Caller need only
        re-render. *)
  | Pass_to_term
    (** Not intercepted. Caller should forward to the active
        terminal via [Pty.forward_event] (or equivalent). *)
  | Quit
    (** Ctrl+Q. Caller exits. *)
  | Closed_term
    (** Ctrl+W. The terminal has already been destroyed. Caller
        post-processes — including resyncing the relevant
        [Msg_pane] instance — and decides what comes next
        (rocqtui refocuses the script pane and lets its render
        sync the singleton; tterm syncs the leaf, collapses if
        empty, possibly exits). *)
  | Open_term
    (** Ctrl+T. Caller spawns a new terminal using whatever [cwd]
        convention fits its binary. *)
  | Open_claude
    (** F6 in rocqtui — opens a [claude] subprocess. Only returned
        when [include_rocqtui_bindings] is true. *)
  | Save_prompt
    (** Ctrl+S in rocqtui. Only returned when
        [include_rocqtui_bindings] is true. *)
  | Cycle_pane
    (** Ctrl+P in rocqtui. Only returned when
        [include_rocqtui_bindings] is true. *)
  | Build_menu
    (** F5 in rocqtui. Only returned when [include_rocqtui_bindings]
        is true. *)
  | Help
    (** F1 in rocqtui. Only returned when [include_rocqtui_bindings]
        is true. *)

(** Dispatch a single input event.

    [include_rocqtui_bindings] (default [true]) controls whether
    Save_prompt, Cycle_pane, Build_menu, Help, and Open_claude are
    matched. When [false] (tterm), those bindings are not intercepted
    — they pass through to the terminal as ordinary keys. The
    universally-useful intercepts (Quit, Closed_term, Open_term,
    Copy, Compose-start) are always matched.

    Caller passes the currently-active terminal in [active] (or
    [None] when there is none; the few cases that need it then
    no-op). The [Render.t] handle is used only for the immediate
    compose-status repaint. *)
val handle :
  ?include_rocqtui_bindings:bool ->
  Editor_context.t ->
  Input.event ->
  active:Terminal.t option ->
  Render.t ->
  result
