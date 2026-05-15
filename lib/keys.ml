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
  name = "quit"; codes = [ctrl 'q']; kitty_codes = []; display = "^Q";
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
  name = "interrupt"; codes = []; kitty_codes = [(46, 3)]; display = "Alt+.";
  context = Global; description = "Interrupt" }

let step_forward = {
  name = "step_forward"; codes = []; kitty_codes = [(258, 3)];
  display = "Alt+Down"; context = Global; description = "Step forward" }

let step_backward = {
  name = "step_backward"; codes = []; kitty_codes = [(259, 3)];
  display = "Alt+Up"; context = Global; description = "Step backward" }

let go_to_cursor = {
  name = "go_to_cursor"; codes = [ctrl 'e']; kitty_codes = [(101, 3)];
  display = "^E/Alt+E"; context = Global; description = "Go to cursor" }

let step_to_start = {
  name = "step_to_start"; codes = [];
  kitty_codes = [(262, 3); (114, 3)];  (* Alt+Home, Alt+R *)
  display = "Alt+Home/Alt+R"; context = Global;
  description = "Rewind to start" }

let step_to_end = {
  name = "step_to_end"; codes = [];
  kitty_codes = [(360, 3)];  (* Alt+End *)
  display = "Alt+End"; context = Global;
  description = "Verify to end" }

let toggle_hyps = {
  name = "toggle_hyps"; codes = [ctrl 'g']; kitty_codes = []; display = "^G";
  context = Global; description = "Toggle hypotheses" }

let toggle_gutter = {
  name = "toggle_gutter"; codes = []; kitty_codes = [(108, 3)];
  display = "Alt+L"; context = Global; description = "Toggle line numbers" }

let options_menu = {
  name = "options_menu"; codes = [266]; kitty_codes = []; display = "F2";
  context = Global; description = "Print options" }

let query_menu = {
  name = "query_menu"; codes = []; kitty_codes = [(113, 3)]; display = "Alt+Q";
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
  name = "copy"; codes = [ctrl 'c'; ctrl 'y']; kitty_codes = [(99, 5)];
  display = "^C/^Y"; context = Global; description = "Copy" }

let undo = {
  name = "undo"; codes = [ctrl 'z']; kitty_codes = []; display = "^Z";
  context = Global; description = "Undo" }

let redo = {
  name = "redo"; codes = [ctrl 'r']; kitty_codes = []; display = "^R";
  context = Global; description = "Redo" }

let new_tab = {
  name = "new_tab"; codes = [ctrl 'n']; kitty_codes = []; display = "^N";
  context = Global; description = "New tab" }

let search = {
  name = "search"; codes = [ctrl 'f']; kitty_codes = []; display = "^F";
  context = Global; description = "Find" }

let search_next = {
  name = "search_next"; codes = [267]; kitty_codes = []; display = "F3";
  context = Global; description = "Find next" }

let search_prev = {
  name = "search_prev"; codes = []; kitty_codes = [(267, 2)];
  display = "Shift+F3"; context = Global; description = "Find previous" }

let search_toggle_case = {
  name = "search_toggle_case"; codes = []; kitty_codes = [(99, 3)];
  display = "Alt+C"; context = Global;
  description = "Toggle case (in prompt; smart-case otherwise)" }

let search_toggle_regex = {
  name = "search_toggle_regex"; codes = []; kitty_codes = [(114, 3)];
  display = "Alt+R"; context = Global;
  description = "Toggle regex (in prompt)" }

let search_field_toggle = {
  name = "search_field_toggle"; codes = [9]; kitty_codes = [(9, 1)];
  display = "Tab"; context = Global;
  description = "Toggle Find/Replace field (in prompt)" }

let search_replace_one = {
  name = "search_replace_one"; codes = []; kitty_codes = [(13, 3)];
  display = "Alt+Enter"; context = Global;
  description = "Replace current match (in prompt)" }

let search_replace_all = {
  name = "search_replace_all"; codes = []; kitty_codes = [(97, 3)];
  display = "Alt+A"; context = Global;
  description = "Replace all matches (in prompt)" }

let search_toggle_project = {
  name = "search_toggle_project"; codes = []; kitty_codes = [(112, 3)];
  display = "Alt+P"; context = Global;
  description = "Toggle project-wide search (in prompt)" }

let next_error = {
  name = "next_error"; codes = [273]; kitty_codes = [];
  display = "F9"; context = Global; description = "Next build error" }

let prev_error = {
  name = "prev_error"; codes = []; kitty_codes = [(273, 2)];
  display = "Shift+F9"; context = Global; description = "Previous build error" }

let prev_tab = {
  name = "prev_tab"; codes = []; kitty_codes = [(260, 3)]; display = "Alt+Left";
  context = Global; description = "Prev tab" }

let next_tab = {
  name = "next_tab"; codes = []; kitty_codes = [(261, 3)]; display = "Alt+Right";
  context = Global; description = "Next tab" }

(* --- Script-only bindings --- *)

let cut = {
  name = "cut"; codes = [ctrl 'x'; ctrl 'k']; kitty_codes = []; display = "^X/^K";
  context = Script; description = "Cut line" }

let paste = {
  name = "paste"; codes = [ctrl 'u']; kitty_codes = []; display = "^U";
  context = Script; description = "Paste" }

(* --- Function keys --- *)

let help = {
  name = "help"; codes = [265]; kitty_codes = []; display = "F1";
  context = Global; description = "Help" }

let minimap = {
  name = "minimap"; codes = []; kitty_codes = [(109, 5)];
  display = "^M"; context = Global; description = "Minimap" }

let theme_menu = {
  name = "theme_menu"; codes = [271]; kitty_codes = []; display = "F7";
  context = Global; description = "Theme" }

let reload = {
  name = "reload"; codes = [268]; kitty_codes = []; display = "F4";
  context = Global; description = "Reload" }

let build_menu = {
  name = "build_menu"; codes = [269]; kitty_codes = []; display = "F5";
  context = Global; description = "Build" }

let refresh_screen = {
  name = "refresh_screen"; codes = [276]; kitty_codes = [];
  display = "F12"; context = Global; description = "Refresh screen" }

let toggle_file_tree = {
  name = "toggle_file_tree"; codes = [272]; kitty_codes = [];
  display = "F8"; context = Global; description = "File tree" }

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

let open_terminal = {
  name = "open_terminal"; codes = [ctrl 't']; kitty_codes = [(116, 5)];
  display = "^T"; context = Global; description = "Terminal" }

let open_claude = {
  name = "open_claude"; codes = [270]; kitty_codes = [];
  display = "F6"; context = Global; description = "Claude" }

(* --- AI suggestions --- *)

let ai_toggle = {
  name = "ai_toggle"; codes = [ctrl 'g']; kitty_codes = []; display = "^G";
  context = Global; description = "Toggle AI suggestions" }

let ai_accept = {
  name = "ai_accept"; codes = [9]; kitty_codes = []; display = "Tab";
  context = Script; description = "Accept AI suggestion" }

let ai_dismiss = {
  name = "ai_dismiss"; codes = [27]; kitty_codes = []; display = "Esc";
  context = Script; description = "Dismiss AI suggestion" }

let ai_accept_word = {
  name = "ai_accept_word"; codes = []; kitty_codes = [(119, 3)];
  display = "Alt+W"; context = Script;
  description = "Accept next word of AI suggestion" }

let ai_predict_edits = {
  name = "ai_predict_edits"; codes = [274]; kitty_codes = [];
  display = "F10"; context = Global;
  description = "Predict edits (force edits-shape AI request)" }

(* --- Grouped for help/status generation --- *)

let navigation_bindings = [step_forward; step_backward; go_to_cursor; step_to_start; step_to_end; cycle_pane]
let editing_bindings = [open_file; save; close_tab; quit; cut; paste; copy; undo; redo]
let query_bindings = [about; print_query; jump_to_def; jump_back; query_menu]
let display_bindings = [toggle_hyps; toggle_gutter; options_menu; help; minimap; theme_menu; reload; build_menu; toggle_file_tree; open_terminal; open_claude; refresh_screen]
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
    { step_to_start with description = "Rewind to start of buffer" };
    { step_to_end with description = "Verify to end of buffer" };
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
    { step_to_start with description = "Rewind to start of buffer" };
    { step_to_end with description = "Verify to end of buffer" };
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
    toggle_gutter;
    options_menu;
    help;
    minimap;
    theme_menu;
    { reload with description = "Reload from disk (prompts if dirty)" };
    { build_menu with description = "Build menu (make file/all/deps)" };
    { toggle_file_tree with description = "Toggle file-tree panel" };
  ];
  section "Terminal" [
    { open_terminal with description = "Open terminal (in project dir)" };
    { open_claude with description = "Open Claude Code (in project dir)" };
    { close_tab with display = "^W"; description = "Close terminal (when focused)" };
    { cycle_pane with description = "Switch focus back to editor" };
    { (let b = { name="dbl_esc"; codes=[]; kitty_codes=[]; display="ESC ESC";
                 context=Global; description="Send ESC to terminal" } in b)
      with name = "dbl_esc" };
  ];
  section "Tabs" [
    new_tab;
    { close_tab with description = "Close tab (exit if last)" };
    prev_tab; next_tab;
  ];
  section "Build errors" [
    { next_error with description = "Next build error / warning" };
    { prev_error with description = "Previous build error / warning" };
    { (let b = { name="click_error"; codes=[]; kitty_codes=[]; display="Click";
                 context=Global; description="Jump to error in Build / Errors tab" } in b)
      with name = "click_error" };
  ];
  section "Search & Replace" [
    { search with description = "Open / re-open find & replace panel" };
    { search_next with description = "Next match (also in prompt)" };
    { search_prev with description = "Previous match (also in prompt)" };
    search_toggle_case;
    search_toggle_regex;
    search_field_toggle;
    { search_replace_one with
      description = "Replace current match, advance to next" };
    { search_replace_all with
      description = "Replace all matches ($1, $&, $$ in regex mode)" };
    { (let b = { name="search_accept"; codes=[]; kitty_codes=[];
                 display="Enter"; context=Global;
                 description="Close prompt, keep search active" } in b)
      with name = "search_accept" };
    { (let b = { name="search_cancel"; codes=[]; kitty_codes=[];
                 display="ESC"; context=Global;
                 description="Cancel: in prompt restores cursor; otherwise clears search (ESC ESC in compose mode)" } in b)
      with name = "search_cancel" };
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
  Stdlib.Buffer.add_string buf (Printf.sprintf "  %s to switch themes, or -theme NAME on command line:\n" theme_menu.display);
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

(* --- Key event type --- *)

type key_event =
  | RawKey of int                     (* traditional getch result *)
  | KittyKey of kitty_key             (* CSI u decoded *)
  | Paste of string                   (* bracketed paste content *)
  | Escape                            (* standalone ESC *)

(* Unified match: works with both RawKey and KittyKey *)
let match_event ev b =
  match ev with
  | RawKey ch -> List.mem ch b.codes
  | KittyKey kk ->
    (* First check kitty_codes, then try mapping keycode to legacy *)
    if match_kitty_key kk b then true
    else if kk.kk_modifier = 1 then
      (* No modifier — keycode might map to a legacy code *)
      List.mem kk.kk_keycode b.codes
    else if kk.kk_modifier = 5 then
      (* Ctrl — map to ctrl code if it's a letter *)
      let kc = kk.kk_keycode in
      if kc >= 97 && kc <= 122 then  (* a-z *)
        List.mem (kc - 96) b.codes  (* ctrl+a=1, ctrl+b=2, etc. *)
      else
        false
    else
      false
  | Paste _ -> false
  | Escape -> false

(* Extract the raw int from a key event (for non-binding checks like printable chars) *)
let raw_key_of_event = function
  | RawKey ch -> Some ch
  | KittyKey kk when kk.kk_modifier = 1 -> Some kk.kk_keycode
  | _ -> None

(* Check if event is a mouse event — legacy, always false in new Input system *)
let is_mouse_event = function
  | RawKey _ch -> false  (* no longer using ncurses mouse codes *)
  | _ -> false

(* Check if event is a resize event — legacy, always false in new Input system *)
let is_resize_event = function
  | RawKey _ch -> false  (* no longer using ncurses resize codes *)
  | _ -> false

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

(* Read a complete key event from the terminal.
   [peek timeout] reads one byte with timeout (returns -1 on timeout).
   [block ()] blocks until a byte is available.
   [getch ()] is a non-blocking read (returns -1 if nothing). *)
let read_key_event ~peek ~block ~getch () =
  let ch = getch () in
  if ch = -1 then None
  else if ch <> 27 then
    Some (RawKey ch)
  else begin
    (* ESC received — peek ahead *)
    let next = peek 0.025 in
    if next = -1 then
      Some Escape  (* standalone ESC *)
    else if next = Char.code '[' then begin
      (* CSI sequence — read parameter bytes until final byte (0x40-0x7E) *)
      let buf = Stdlib.Buffer.create 16 in
      let final = ref (-1) in
      let finished = ref false in
      while not !finished do
        let c = peek 0.050 in
        if c = -1 then
          finished := true
        else if c >= 64 && c <= 126 then begin
          (* Final byte *)
          final := c;
          finished := true
        end else
          Stdlib.Buffer.add_char buf (Char.chr c)
      done;
      let params = Stdlib.Buffer.contents buf in
      if !final = Char.code 'u' then begin
        (* CSI u (Kitty protocol) *)
        match parse_csi_u (params ^ "u") with
        | Some kk -> Some (KittyKey kk)
        | None -> Some (RawKey 27)  (* fallback *)
      end
      else if !final = Char.code '~' then begin
        (* CSI ~ — function key or special *)
        (* Check for bracketed paste: ESC[200~ *)
        if params = "200" then begin
          (* Bracketed paste — read until ESC[201~ *)
          let paste = Stdlib.Buffer.create 256 in
          let done_ = ref false in
          while not !done_ do
            let c = block () in
            if c = 27 then begin
              let n1 = peek 0.025 in
              if n1 = Char.code '[' then begin
                let p = Stdlib.Buffer.create 8 in
                let f = ref (-1) in
                let fin = ref false in
                while not !fin do
                  let c2 = peek 0.050 in
                  if c2 = -1 then fin := true
                  else if c2 >= 64 && c2 <= 126 then
                    (f := c2; fin := true)
                  else
                    Stdlib.Buffer.add_char p (Char.chr c2)
                done;
                if Stdlib.Buffer.contents p = "201" && !f = Char.code '~' then
                  done_ := true
                else begin
                  Stdlib.Buffer.add_char paste '\x1b';
                  Stdlib.Buffer.add_char paste '[';
                  Stdlib.Buffer.add_string paste (Stdlib.Buffer.contents p);
                  if !f >= 0 then Stdlib.Buffer.add_char paste (Char.chr !f)
                end
              end else begin
                Stdlib.Buffer.add_char paste '\x1b';
                if n1 >= 0 then Stdlib.Buffer.add_char paste (Char.chr n1)
              end
            end else
              Stdlib.Buffer.add_char paste (Char.chr c)
          done;
          Some (Paste (Stdlib.Buffer.contents paste))
        end else begin
          (* Other CSI ~ sequence — try to map to a curses key *)
          match int_of_string_opt params with
          | Some 5 -> Some (RawKey 339)  (* page up *)
          | Some 6 -> Some (RawKey 338)  (* page down *)
          | Some n -> Some (RawKey (1000 + n))  (* arbitrary mapping *)
          | None -> Some (RawKey 27)
        end
      end
      else if !final >= Char.code 'A' && !final <= Char.code 'D' then begin
        (* Arrow keys: CSI [modifier] A/B/C/D *)
        let modifier = match int_of_string_opt params with
          | Some n -> n | None ->
            match String.split_on_char ';' params with
            | _ :: m :: _ -> (match int_of_string_opt m with Some n -> n | None -> 1)
            | _ -> 1
        in
        let base = match !final with
          | c when c = Char.code 'A' -> 259  (* up *)
          | c when c = Char.code 'B' -> 258  (* down *)
          | c when c = Char.code 'C' -> 261  (* right *)
          | c when c = Char.code 'D' -> 260  (* left *)
          | _ -> 0
        in
        if modifier = 1 then Some (RawKey base)
        else begin
          (* Map modified arrows to the ncurses extended codes *)
          let bits = modifier - 1 in
          let has_shift = bits land 1 <> 0 in
          let has_alt = bits land 2 <> 0 in
          let has_ctrl = bits land 4 <> 0 in
          (* ncurses shift+up=337, alt+up=564, ctrl+up=567, etc.
             These vary; use KittyKey for precision *)
          let kc = match !final with
            | c when c = Char.code 'A' ->
              if has_alt then 564 else if has_ctrl then 567
              else if has_shift then 337 else base
            | c when c = Char.code 'B' ->
              if has_alt then 523 else if has_ctrl then 526
              else if has_shift then 336 else base
            | c when c = Char.code 'C' ->
              if has_alt then 558 else if has_ctrl then 561
              else if has_shift then 402 else base
            | c when c = Char.code 'D' ->
              if has_alt then 543 else if has_ctrl then 546
              else if has_shift then 393 else base
            | _ -> base
          in
          ignore (has_shift, has_alt, has_ctrl);
          Some (RawKey kc)
        end
      end
      else if !final = Char.code 'H' then Some (RawKey 262)  (* home *)
      else if !final = Char.code 'F' then Some (RawKey 360)  (* end *)
      else if !final = Char.code 'M' then begin
        (* Mouse event — legacy path, should not occur with Input.read_event *)
        Some (RawKey 27)
      end
      else
        Some (RawKey 27)  (* unknown CSI *)
    end
    else begin
      (* ESC + non-[ — could be Alt+key or compose *)
      (* Return ESC; in the new Input system this path shouldn't be used *)
      Some (RawKey 27)
    end
  end
