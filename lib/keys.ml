(* Centralized key binding registry.
   All key bindings are defined here with their keycodes, display strings,
   and descriptions. Other modules reference these by name. *)

type context =
  | Global
  | Script
  | GoalsMessages
  | QueryMenu
  | BuildMenu
  | ThemeMenu
  | OptionsMenu
  | HelpScreen
  | FilePicker

type binding = {
  name : string;
  codes : int list;
  kitty_codes : (int * int) list;  (* (keycode, modifier) pairs for Kitty protocol *)
  display : string;
  context : context;
  description : string;
}

let kitty_enabled = ref false

let match_key ch b =
  List.mem ch b.codes

(* Kitty CSI u decoded key *)
type kitty_key = {
  kk_keycode : int;
  kk_modifier : int;  (* 1-based: 1=none, 2=shift, 3=alt, 5=ctrl, etc. *)
}

let match_kitty_key kk b =
  List.exists (fun (kc, m) ->
    kk.kk_keycode = kc && kk.kk_modifier = m
  ) b.kitty_codes

(* --- Ctrl key helpers --- *)
let ctrl c = Char.code c - Char.code 'a' + 1

(* --- Global bindings --- *)

let quit = {
  name = "quit"; codes = [ctrl 'x']; kitty_codes = []; display = "^X";
  context = Global; description = "Exit" }

let close_tab = {
  name = "close_tab"; codes = [ctrl 'w']; kitty_codes = []; display = "^W";
  context = Global; description = "Close tab" }

let save = {
  name = "save"; codes = [ctrl 's']; kitty_codes = []; display = "^S";
  context = Global; description = "Save" }

let jump_back = {
  name = "jump_back"; codes = [ctrl 'b']; kitty_codes = []; display = "^B";
  context = Global; description = "Jump back" }

let open_file = {
  name = "open_file"; codes = [ctrl 'o']; kitty_codes = []; display = "^O";
  context = Global; description = "Open file" }

let interrupt = {
  name = "interrupt"; codes = [ctrl 'c']; kitty_codes = []; display = "^C";
  context = Global; description = "Interrupt" }

let step_forward = {
  name = "step_forward"; codes = [526; 532; 517]; kitty_codes = [];
  display = "Alt+Down"; context = Global; description = "Step forward" }

let step_backward = {
  name = "step_backward"; codes = [567; 573; 558]; kitty_codes = [];
  display = "Alt+Up"; context = Global; description = "Step backward" }

let go_to_cursor = {
  name = "go_to_cursor"; codes = [ctrl 'e']; kitty_codes = []; display = "^E";
  context = Global; description = "Go to cursor" }

let toggle_hyps = {
  name = "toggle_hyps"; codes = [ctrl 'g']; kitty_codes = []; display = "^G";
  context = Global; description = "Toggle hypotheses" }

let options_menu = {
  name = "options_menu"; codes = [ctrl 't']; kitty_codes = []; display = "^T";
  context = Global; description = "Print options" }

let query_menu = {
  name = "query_menu"; codes = [ctrl 'q']; kitty_codes = []; display = "^Q";
  context = Global; description = "Query menu" }

let cycle_pane = {
  name = "cycle_pane"; codes = [ctrl 'p']; kitty_codes = []; display = "^P";
  context = Global; description = "Cycle pane" }

let jump_to_def = {
  name = "jump_to_def"; codes = [ctrl 'l']; kitty_codes = []; display = "^L";
  context = Global; description = "Jump to definition" }

let about = {
  name = "about"; codes = [ctrl 'a']; kitty_codes = []; display = "^A";
  context = Global; description = "About" }

let print_query = {
  name = "print_query"; codes = [ctrl 'd']; kitty_codes = []; display = "^D";
  context = Global; description = "Print" }

let copy = {
  name = "copy"; codes = [ctrl 'y']; kitty_codes = []; display = "^Y";
  context = Global; description = "Copy" }

let undo = {
  name = "undo"; codes = [ctrl 'z']; kitty_codes = []; display = "^Z";
  context = Global; description = "Undo" }

let redo = {
  name = "redo"; codes = [ctrl 'r']; kitty_codes = []; display = "^R";
  context = Global; description = "Redo" }

let new_tab = {
  name = "new_tab"; codes = [ctrl 'n']; kitty_codes = []; display = "^N";
  context = Global; description = "New tab" }

let prev_tab = {
  name = "prev_tab"; codes = [552]; kitty_codes = []; display = "Alt+Left";
  context = Global; description = "Prev tab" }

let next_tab = {
  name = "next_tab"; codes = [567]; kitty_codes = []; display = "Alt+Right";
  context = Global; description = "Next tab" }

(* --- Script-only bindings --- *)

let cut = {
  name = "cut"; codes = [ctrl 'k']; kitty_codes = []; display = "^K";
  context = Script; description = "Cut line" }

let paste = {
  name = "paste"; codes = [ctrl 'u']; kitty_codes = []; display = "^U";
  context = Script; description = "Paste" }

(* --- Function keys --- *)

let help = {
  name = "help"; codes = [Curses.Key.f 1]; kitty_codes = []; display = "F1";
  context = Global; description = "Help" }

let minimap = {
  name = "minimap"; codes = [Curses.Key.f 2]; kitty_codes = [(Char.code 'm', 5)];
  display = "F2"; context = Global; description = "Minimap" }

let theme_menu = {
  name = "theme_menu"; codes = [Curses.Key.f 3]; kitty_codes = []; display = "F3";
  context = Global; description = "Theme" }

let reload = {
  name = "reload"; codes = [Curses.Key.f 4]; kitty_codes = []; display = "F4";
  context = Global; description = "Reload" }

let build_menu = {
  name = "build_menu"; codes = [Curses.Key.f 5]; kitty_codes = []; display = "F5";
  context = Global; description = "Build" }

(* --- Query submenu --- *)

let query_about = {
  name = "query_about"; codes = [Char.code 'a']; kitty_codes = [];
  display = "a"; context = QueryMenu; description = "About" }

let query_check = {
  name = "query_check"; codes = [Char.code 'c']; kitty_codes = [];
  display = "c"; context = QueryMenu; description = "Check" }

let query_print = {
  name = "query_print"; codes = [Char.code 'd']; kitty_codes = [];
  display = "d"; context = QueryMenu; description = "Print" }

let query_coercions = {
  name = "query_coercions"; codes = [Char.code 'g']; kitty_codes = [];
  display = "g"; context = QueryMenu; description = "Coercions" }

let query_locate = {
  name = "query_locate"; codes = [Char.code 'l']; kitty_codes = [];
  display = "l"; context = QueryMenu; description = "Locate" }

let query_proof = {
  name = "query_proof"; codes = [Char.code 'p']; kitty_codes = [];
  display = "p"; context = QueryMenu; description = "Show Proof" }

let query_existentials = {
  name = "query_existentials"; codes = [Char.code 'e']; kitty_codes = [];
  display = "e"; context = QueryMenu; description = "Existentials" }

(* --- Build submenu --- *)

let build_file = {
  name = "build_file"; codes = [Char.code 'f']; kitty_codes = [];
  display = "f"; context = BuildMenu; description = "File" }

let build_deps = {
  name = "build_deps"; codes = [Char.code 'd']; kitty_codes = [];
  display = "d"; context = BuildMenu; description = "Deps" }

let build_all = {
  name = "build_all"; codes = [Char.code 'a']; kitty_codes = [];
  display = "a"; context = BuildMenu; description = "All" }

let build_cursor = {
  name = "build_cursor"; codes = [Char.code 'c']; kitty_codes = [];
  display = "c"; context = BuildMenu; description = "Cursor" }

let build_clean = {
  name = "build_clean"; codes = [Char.code 'x']; kitty_codes = [];
  display = "x"; context = BuildMenu; description = "Clean" }

let build_cancel = {
  name = "build_cancel"; codes = [Char.code 'c']; kitty_codes = [];
  display = "c"; context = BuildMenu; description = "Cancel" }

(* --- Grouped for help/status generation --- *)

let navigation_bindings = [step_forward; step_backward; go_to_cursor; cycle_pane]
let editing_bindings = [open_file; save; close_tab; quit; cut; paste; copy; undo; redo]
let query_bindings = [about; print_query; jump_to_def; jump_back; query_menu]
let display_bindings = [toggle_hyps; options_menu; help; minimap; theme_menu; reload; build_menu]
let tab_bindings = [new_tab; prev_tab; next_tab]

(* Generate a hint string from a list of bindings: "^S:Save ^W:Close ..." *)
let hint_string bindings =
  String.concat " " (List.map (fun b ->
    Printf.sprintf "%s:%s" b.display b.description
  ) bindings)

(* Generate help text grouped by section *)
let generate_help () =
  let buf = Stdlib.Buffer.create 1024 in
  let section name bindings =
    Stdlib.Buffer.add_string buf (Printf.sprintf "\n  ─── %s " name);
    let pad = max 0 (45 - String.length name - 5) in
    for _ = 1 to pad do Stdlib.Buffer.add_string buf "─" done;
    Stdlib.Buffer.add_char buf '\n';
    List.iter (fun b ->
      let pad = max 1 (15 - String.length b.display) in
      Stdlib.Buffer.add_string buf (Printf.sprintf "  %s%*s%s\n" b.display pad "" b.description)
    ) bindings
  in
  Stdlib.Buffer.add_string buf "\n  Rocqtui — Terminal IDE for the Rocq Proof Assistant\n";
  section "Navigation" [
    { step_forward with description = "Step forward (advance target)" };
    { step_backward with description = "Step backward (retract target)" };
    { go_to_cursor with description = "Go to cursor (set target to cursor)" };
    cycle_pane;
    { (let b = { name="click"; codes=[]; kitty_codes=[]; display="Click";
                 context=Global; description="Position cursor / focus pane" } in b)
      with name = "click" };
    { (let b = { name="scroll"; codes=[]; kitty_codes=[]; display="Scroll wheel";
                 context=Global; description="Scroll pane under mouse" } in b)
      with name = "scroll" };
  ];
  section "Editing" [
    open_file;
    save;
    { close_tab with description = "Close tab (exit if last)" };
    { quit with description = "Exit all (prompts if unsaved)" };
    { cut with description = "Cut line (or cut selection)" };
    paste;
    { copy with description = "Copy selection (also to system clipboard)" };
    undo; redo;
    { (let b = { name="shift_arrows"; codes=[]; kitty_codes=[]; display="Shift+Arrows";
                 context=Script; description="Select text" } in b) with name = "sel" };
    { (let b = { name="escape"; codes=[]; kitty_codes=[]; display="ESC";
                 context=Global; description="Compose key (XCompose input)" } in b)
      with name = "compose" };
  ];
  section "Rocq" [
    { step_forward with description = "Step forward (advance target)" };
    { step_backward with description = "Step backward (retract target)" };
    go_to_cursor;
    { interrupt with description = "Interrupt rocqtop" };
  ];
  section "Queries" [
    about;
    print_query;
    { jump_to_def with description = "Jump to definition / open module" };
    { jump_back with description = "Jump back (return to previous location)" };
    { query_menu with description = "Query menu" };
  ];
  section "Display" [
    toggle_hyps;
    options_menu;
    help;
    minimap;
    theme_menu;
    { reload with description = "Reload from disk (prompts if dirty)" };
    { build_menu with description = "Build menu (make file/all/deps)" };
  ];
  section "Tabs" [
    new_tab;
    { close_tab with description = "Close tab (exit if last)" };
    prev_tab; next_tab;
  ];
  Stdlib.Buffer.add_string buf "\n  ─── Compose (ESC) ";
  for _ = 1 to 25 do Stdlib.Buffer.add_string buf "─" done;
  Stdlib.Buffer.add_string buf "\n";
  Stdlib.Buffer.add_string buf "  ESC then key sequence from ~/.XCompose\n";
  Stdlib.Buffer.add_string buf "  Completions shown in status bar as you type.\n";
  Stdlib.Buffer.add_string buf "  Examples:  ESC - >  →     ESC f a  ∀\n";
  Stdlib.Buffer.add_string buf "             ESC e x  ∃     ESC | -  ⊢\n";
  Stdlib.Buffer.add_string buf "\n  ─── Themes ";
  for _ = 1 to 33 do Stdlib.Buffer.add_string buf "─" done;
  Stdlib.Buffer.add_string buf "\n";
  Stdlib.Buffer.add_string buf "  F3 to switch themes, or -theme NAME on command line:\n";
  Stdlib.Buffer.add_string buf "    solarized-dark  solarized-light  classic\n";
  Stdlib.Buffer.add_string buf "    monokai  nord\n";
  Stdlib.Buffer.add_string buf "\n  Press any key to close this help screen.\n";
  Stdlib.Buffer.contents buf

(* --- Kitty keyboard protocol --- *)

let kitty_enable_seq = "\x1b[>1u"   (* level 1: disambiguate *)
let kitty_disable_seq = "\x1b[<u"

let enable_kitty () =
  ignore (Unix.write_substring Unix.stdout kitty_enable_seq 0
            (String.length kitty_enable_seq));
  kitty_enabled := true

let disable_kitty () =
  if !kitty_enabled then begin
    ignore (Unix.write_substring Unix.stdout kitty_disable_seq 0
              (String.length kitty_disable_seq));
    kitty_enabled := false
  end

let is_kitty_enabled () = !kitty_enabled

(* Parse a CSI u sequence from a string of bytes after "ESC [".
   Returns Some kitty_key or None. *)
let parse_csi_u bytes =
  let len = String.length bytes in
  if len < 2 then None
  else if bytes.[len - 1] <> 'u' then None
  else begin
    let params = String.sub bytes 0 (len - 1) in
    let parts = String.split_on_char ';' params in
    let keycode = match parts with
      | kc :: _ -> (match int_of_string_opt kc with Some n -> n | None -> 0)
      | [] -> 0
    in
    let modifier = match parts with
      | _ :: m :: _ ->
        let m = match String.split_on_char ':' m with
          | m1 :: _ -> m1 | [] -> m in
        (match int_of_string_opt m with Some n -> n | None -> 1)
      | _ -> 1
    in
    Some { kk_keycode = keycode; kk_modifier = modifier }
  end
