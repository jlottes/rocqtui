let text = {|
  Rocqtui — Terminal IDE for the Rocq Proof Assistant

  ─── Navigation ───────────────────────────────
  Arrows         Move cursor
  Home / End     Start / end of line
  PgUp / PgDn    Page up / down
  ^W             Cycle pane focus (Script→Goals→Messages)
  Click          Position cursor / focus pane
  Scroll wheel   Scroll pane under mouse

  ─── Editing ──────────────────────────────────
  ^O             Save file
  ^X             Exit (prompts if unsaved)
  ^K             Cut line (or cut selection)
  ^U             Paste
  ^Y             Copy selection (also to system clipboard)
  ^Z             Undo
  ^R             Redo
  Shift+Arrows   Select text
  Mouse drag     Select text
  Double-click   Select word
  ESC            Compose key (XCompose input)

  ─── Rocq ─────────────────────────────────────
  Alt+Down / ^N  Step forward (advance target)
  Alt+Up   / ^P  Step backward (retract target)
  ^E             Go to cursor (set target to cursor)
  Cmd+Click      Go to cursor (at click position)
  ^C             Interrupt rocqtop

  ─── Queries ──────────────────────────────────
  ^A             About (word/selection at cursor)
  ^D             Print (word/selection at cursor)
  ^Q             Query menu (About, Print, Show Proof,
                   Show Existentials)

  ─── Display ──────────────────────────────────
  ^G             Toggle hypotheses (focused / all)
  ^T             Printing options panel
  F1             This help screen
  Drag borders   Resize panes

  ─── Compose (ESC) ────────────────────────────
  ESC then key sequence from ~/.XCompose
  Completions shown in status bar as you type.
  Examples:  ESC - >  →     ESC f a  ∀
             ESC e x  ∃     ESC | -  ⊢

  ─── Themes ───────────────────────────────────
  Use -theme NAME on the command line:
    solarized-dark  solarized-light  classic
    monokai  nord

  Press any key to close this help screen.
|}
