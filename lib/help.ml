let text = {|
  Rocqtui — Terminal IDE for the Rocq Proof Assistant

  ─── Navigation ───────────────────────────────
  Arrows        Move cursor
  Home / End    Start / end of line
  PgUp / PgDn   Page up / down
  ^W            Cycle pane focus (Script→Goals→Messages)

  ─── Editing ──────────────────────────────────
  ^O            Save file
  ^X            Exit (prompts if unsaved)
  ^K            Cut line (or cut selection)
  ^U            Paste
  ^Y            Copy selection
  ^Z            Undo
  ^R            Redo
  Shift+Arrows  Select text
  ESC           Compose key (XCompose input)

  ─── Rocq ─────────────────────────────────────
  Alt+Down / ^N  Step forward
  Alt+Up   / ^P  Step backward
  ^E             Go to cursor
  ^C             Interrupt rocqtop
  ^A             About (word at cursor)
  ^D             Print (word at cursor)

  ─── Display ──────────────────────────────────
  ^G            Toggle hypotheses (focused / all)
  ^T            Printing options panel
  F1            This help screen

  ─── Compose (ESC) ────────────────────────────
  ESC then key sequence from ~/.XCompose
  Examples:  ESC - >  →     ESC f a  ∀
             ESC e x  ∃     ESC | -  ⊢

  ─── Themes ───────────────────────────────────
  Use -theme NAME on the command line:
    solarized-dark  solarized-light  classic
    monokai  nord

  Press any key to close this help screen.
|}
