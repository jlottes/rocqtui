type jump_point = {
  jp_tab_id : int;
  jp_file : string;
  jp_line : int;
  jp_col : int;
}

type action =
  | Continue
  | Quit
  | Close_tab
  | Save_prompt
  | Reload
  | Open_file of string
  | Jump_back of jump_point

let init_error_msg = ref ""
let set_init_error msg = init_error_msg := msg

(* Extra status text (e.g., MCP spinner) set by main.ml *)
let status_extra = ref ""
let set_status_extra s = status_extra := s

(* Blocking getch that works with our select-based main loop.
   Waits for stdin via select (which also dispatches watch callbacks)
   then calls non-blocking getch. *)
let blocking_getch () =
  let rec wait () =
    let ready = Main_loop.select_with_watches [Unix.stdin] 1.0 in
    if List.mem Unix.stdin ready then
      let ch = Curses.getch () in
      if ch = -1 then wait () else ch
    else wait ()
  in
  wait ()

(* Peek getch with short timeout — used for escape sequence detection.
   Returns -1 if no key within timeout_sec. *)
let peek_getch timeout_sec =
  let ready = Main_loop.select_with_watches [Unix.stdin] timeout_sec in
  if List.mem Unix.stdin ready then Curses.getch ()
  else -1

(* Clipboard — shared across tabs *)
let clipboard = ref ""

(* Compose input method *)
let compose_state : Compose.t option ref = ref None

let init_compose () =
  compose_state := Some (Compose.load ())

(* Drag state for resizing pane borders — global since it's display-level *)
type drag_mode = NoDrag | DragV | DragH | DragMinimap | DragMinimapScroll
let dragging = ref NoDrag

let clear_pane_selection (ps : Tab.pane_selection) =
  ps.ps_active <- false

let pane_selection_text (ps : Tab.pane_selection) lines_cache =
  if not ps.ps_active then None
  else begin
    let lines = lines_cache in
    let n = List.length lines in
    let al = ps.ps_anchor_line in
    let ac = ps.ps_anchor_col in
    let cl = ps.ps_cursor_line in
    let cc = ps.ps_cursor_col in
    let (sl, sc, el, ec) =
      if al < cl || (al = cl && ac <= cc) then (al, ac, cl, cc)
      else (cl, cc, al, ac)
    in
    let buf = Stdlib.Buffer.create 128 in
    for i = sl to min el (n - 1) do
      let line = List.nth lines i in
      let len = String.length line in
      let s = if i = sl then min sc len else 0 in
      let e = if i = el then min ec len else len in
      if e > s then
        Stdlib.Buffer.add_string buf (String.sub line s (e - s));
      if i < el then Stdlib.Buffer.add_char buf '\n'
    done;
    let text = Stdlib.Buffer.contents buf in
    if text = "" then None else Some text
  end

let [@warning "-32"] select_all_pane (ps : Tab.pane_selection) lines_cache =
  let lines = !lines_cache in
  let n = List.length lines in
  if n = 0 then ()
  else begin
    ps.ps_anchor_line <- 0;
    ps.ps_anchor_col <- 0;
    ps.ps_cursor_line <- n - 1;
    ps.ps_cursor_col <- String.length (List.nth lines (n - 1));
    ps.ps_active <- true
  end

(* Tab bar click callback *)
let tab_bar_click_handler : (int -> unit) option ref = ref None
let set_tab_bar_click_handler f = tab_bar_click_handler := Some f

(* Callback to get list of open file paths (for file picker markers) *)
let open_files_fn : (unit -> string list) ref = ref (fun () -> [])
let set_open_files_fn f = open_files_fn := f

(* Target position for jump-to-definition (consumed by main.ml after Open_file) *)
let jump_target : (int * int) option ref = ref None  (* (line, col) *)
let take_jump_target () =
  let v = !jump_target in
  jump_target := None;
  v

let current_theme_name = ref "solarized-dark"
let set_current_theme name = current_theme_name := name

(* Jump stack for go-back. *)
let jump_stack : jump_point list ref = ref []

let push_jump (tab : Tab.t) =
  let (line, col) = Buffer.cursor tab.buf in
  let file = match Buffer.filename tab.buf with
    | Some f -> f | None -> "" in
  jump_stack := { jp_tab_id = tab.id; jp_file = file;
                  jp_line = line; jp_col = col } :: !jump_stack

let pop_jump () =
  match !jump_stack with
  | [] -> None
  | jp :: rest ->
    jump_stack := rest;
    Some jp

(* Print options mode *)
let in_options_mode = ref false

(* Query mode *)
let in_query_mode = ref false

(* Help screen mode *)
let in_help_mode = ref false
let help_scroll = ref 0


(* Apply a chgat to a byte range within a line, adjusting for hscroll *)
let chgat_byte_range win line row hscroll cols byte_start byte_end attr color =
  let scol = Utf8.byte_to_col line byte_start - hscroll in
  let ecol = Utf8.byte_to_col line byte_end - hscroll in
  let scol = max 0 scol in
  let ecol = min cols ecol in
  let w = ecol - scol in
  if w > 0 && scol < cols then
    Curses.mvwchgat win row scol w attr color

(* Apply sentence status coloring with syntax colors preserved *)
let render_sentence_regions display buf session spans =
  match session with
  | None -> ()
  | Some sess ->
    let ranges = Session.sentence_ranges sess in
    if ranges = [] then ()
    else begin
      let win = Display.script_win display in
      let (rows, cols) = Display.script_dims display in
      let scroll = Buffer.scroll_top buf in
      let hscroll = Buffer.hscroll buf in
      List.iter (fun (sd : Session.sentence_display) ->
        let default_pair, pair_fn = match sd.sd_status with
          | Session.Verified ->
            (Highlight.color_default_v, Highlight.verified_pair)
          | Session.Processing ->
            (Highlight.color_default_p, Highlight.processing_pair)
          | Session.Error _ ->
            (Display.color_error, fun _ -> Display.color_error)
        in
        let byte_off = ref 0 in
        for i = 0 to Buffer.line_count buf - 1 do
          let line = Buffer.get_line buf i in
          let line_len = String.length line in
          let line_start = !byte_off in
          let line_end = line_start + line_len in
          let row = i - scroll in
          if row >= 0 && row < rows
             && line_end > sd.sd_start && line_start < sd.sd_end then begin
            let s = max 0 (sd.sd_start - line_start) in
            let e = min line_len (sd.sd_end - line_start) in
            (* Default background for the status region *)
            chgat_byte_range win line row hscroll cols s e
              Curses.A.normal default_pair;
            (* Re-apply syntax spans with status-colored background *)
            if i < Array.length spans then
              List.iter (fun (span : Highlight.span) ->
                let sb = line_start + span.start_col in
                let se = sb + span.length in
                if se > sd.sd_start && sb < sd.sd_end then begin
                  let cs = max s span.start_col in
                  let ce = min e (span.start_col + span.length) in
                  if ce > cs then
                    chgat_byte_range win line row hscroll cols cs ce
                      span.attr (pair_fn span.color)
                end
              ) spans.(i)
          end;
          byte_off := line_end + 1
        done
      ) ranges
    end

(* Wrap lines to fit a given width, returning a flat list of screen lines *)
let wrap_lines width lines_list =
  let avail = max 1 (width - 2) in
  let result = ref [] in
  List.iter (fun line ->
    let line_w = Utf8.string_width line in
    if line_w <= avail then
      result := line :: !result
    else begin
      let len = String.length line in
      let i = ref 0 in
      while !i < len do
        let start = !i in
        let col = ref 0 in
        let stop = ref false in
        while !i < len && not !stop do
          let (cp, n) = Utf8.decode line !i in
          let w = Utf8.codepoint_width cp in
          if !col + w > avail then
            stop := true
          else begin
            col := !col + w;
            i := !i + n
          end
        done;
        (* Safety: always advance at least one codepoint *)
        if !i = start then
          i := Utf8.next line !i;
        result := String.sub line start (!i - start) :: !result
      done
    end
  ) lines_list;
  List.rev !result

(* Render a scrollable text pane with optional selection highlight *)
let render_text_pane ?(sel : Tab.pane_selection option) ?set_cache win scroll_ref lines_list =
  let _ = Curses.werase win in
  let (rows, cols) = Curses.getmaxyx win in
  Curses.scrollok win false;
  let wrapped = wrap_lines cols lines_list in
  (match set_cache with Some f -> f wrapped | None -> ());
  let n = List.length wrapped in
  scroll_ref := max 0 (min !scroll_ref (max 0 (n - rows)));
  List.iteri (fun i line ->
    let row = i - !scroll_ref in
    if row >= 0 && row < rows then
      ignore (Curses.mvwaddstr win row 1 line)
  ) wrapped;
  (* Highlight selection if any *)
  (match sel with
   | Some ps when ps.ps_active ->
     let scroll = !scroll_ref in
     let al = ps.ps_anchor_line in
     let ac = ps.ps_anchor_col in
     let cl = ps.ps_cursor_line in
     let cc = ps.ps_cursor_col in
     let (sl, sc, el, ec) =
       if al < cl || (al = cl && ac <= cc) then (al, ac, cl, cc)
       else (cl, cc, al, ac)
     in
     for i = sl to min el (n - 1) do
       let row = i - scroll in
       if row >= 0 && row < rows then begin
         let line = List.nth wrapped i in
         let len = String.length line in
         let s = if i = sl then min sc len else 0 in
         let e = if i = el then min ec len else len in
         let s_col = Utf8.byte_to_col line s + 1 in (* +1 for margin *)
         let e_col = Utf8.byte_to_col line e + 1 in
         let w = e_col - s_col in
         if w > 0 && s_col < cols then
           Curses.mvwchgat win row s_col (min w (cols - s_col))
             Curses.A.normal Theme.pair_selection
       end
     done
   | _ -> ());
  Curses.scrollok win true;
  let _ = Curses.wnoutrefresh win in
  ()

let render_goals display (tab : Tab.t) =
  let session = tab.session in
  let win = Display.goals_win display in
  let lines = match session with
    | None ->
      let msg = if !init_error_msg <> "" then !init_error_msg
                else "No Rocq session." in
      String.split_on_char '\n' msg
    | Some sess ->
      match Session.goals_text ~all_hyps:tab.show_all_hyps sess with
      | None -> ["No proof in progress."]
      | Some text -> String.split_on_char '\n' text
  in
  let gs = ref tab.goals_scroll in
  render_text_pane ~sel:tab.goals_sel
    ~set_cache:(fun l -> tab.goals_lines_cache <- l)
    win gs lines;
  tab.goals_scroll <- !gs

(* Update messages sub-tab contents. Call before rendering. *)
let update_msg_tabs (tab : Tab.t) =
  let session = tab.session in
  (* Update Rocq tab *)
  let rocq = Tab.ensure_msg_tab tab.msg "Rocq" in
  let rocq_lines = match session with
    | None -> []
    | Some sess ->
      List.concat_map (fun msg ->
        String.split_on_char '\n' msg
      ) (Session.messages sess)
  in
  (* Auto-activate Rocq tab if content changed *)
  if rocq_lines <> rocq.mt_lines && rocq_lines <> [] then begin
    rocq.mt_lines <- rocq_lines;
    Tab.activate_msg_tab tab.msg "Rocq"
  end else
    rocq.mt_lines <- rocq_lines;
  (* Update Build tab *)
  let build_lines = Build.output () in
  if build_lines <> [] || Build.is_running () then begin
    let build = Tab.ensure_msg_tab tab.msg "Build" in
    if build_lines <> build.mt_lines then begin
      build.mt_lines <- build_lines;
      if Build.is_running () then
        Tab.activate_msg_tab tab.msg "Build"
    end
  end

let render_messages display (tab : Tab.t) =
  update_msg_tabs tab;
  let win = Display.messages_win display in
  let mt = Tab.active_msg_tab tab.msg in
  let ms = ref mt.mt_scroll in
  render_text_pane ~sel:mt.mt_sel
    ~set_cache:(fun l -> mt.mt_lines_cache <- l)
    win ms mt.mt_lines;
  mt.mt_scroll <- !ms

(* Extract the visible substring of a line given horizontal scroll.
   Returns (display_string, byte_offset_of_first_visible_char). *)
let visible_portion line hscroll cols =
  let len = String.length line in
  (* Find byte offset of first visible column *)
  let start_byte = Utf8.col_to_byte line hscroll in
  (* Find byte offset of last visible column *)
  let end_byte = Utf8.col_to_byte line (hscroll + cols) in
  let end_byte = min end_byte len in
  if start_byte >= len then ("", len)
  else (String.sub line start_byte (end_byte - start_byte), start_byte)

let help_lines = String.split_on_char '\n' (Keys.generate_help ())

let render_help_screen display =
  let win = Display.script_win display in
  let (rows, cols) = Curses.getmaxyx win in
  let _ = Curses.werase win in
  Curses.scrollok win false;
  let n = List.length help_lines in
  let scroll = !help_scroll in
  for row = 0 to rows - 1 do
    let idx = scroll + row in
    if idx < n then begin
      let line = List.nth help_lines idx in
      ignore (Curses.mvwaddnstr win row 0 line 0 (min (String.length line) cols))
    end
  done;
  let _ = Curses.wnoutrefresh win in
  ()

let render_script display (tab : Tab.t) =
  let buf = tab.buf in
  let session = tab.session in
  if !in_help_mode then
    render_help_screen display
  else begin
  let win = Display.script_win display in
  let (rows, cols) = Display.script_dims display in
  if tab.suppress_ensure_visible || !dragging = DragMinimapScroll then
    tab.suppress_ensure_visible <- false
  else
    Buffer.ensure_visible_h buf rows cols;
  let scroll = Buffer.scroll_top buf in
  let hscroll = Buffer.hscroll buf in
  let _ = Curses.werase win in
  Curses.scrollok win false;
  let spans = Highlight.highlight_buffer buf in
  for row = 0 to rows - 1 do
    let line_idx = scroll + row in
    if line_idx < Buffer.line_count buf then begin
      let line = Buffer.get_line buf line_idx in
      let (visible, _vstart_byte) = visible_portion line hscroll cols in
      let _ = Curses.mvwaddstr win row 0 visible in
      (* Apply highlighting — adjust for horizontal scroll *)
      if line_idx < Array.length spans then
        List.iter (fun (span : Highlight.span) ->
          let scol = Utf8.byte_to_col line span.start_col - hscroll in
          let ecol = Utf8.byte_to_col line (span.start_col + span.length) - hscroll in
          let scol = max 0 scol in
          let ecol = min cols ecol in
          let width = ecol - scol in
          if scol < cols && width > 0 then
            Curses.mvwchgat win row scol width span.attr span.color
        ) spans.(line_idx)
    end
  done;
  render_sentence_regions display buf session spans;
  (* Overlay pending region (go_to_cursor target) *)
  (match session with
   | Some sess ->
     let vend = Session.verified_end sess in
     let pend = Session.pending_end sess in
     if pend > vend then begin
       let byte_off = ref 0 in
       for i = 0 to Buffer.line_count buf - 1 do
         let line = Buffer.get_line buf i in
         let line_len = String.length line in
         let line_start = !byte_off in
         let line_end = line_start + line_len in
         let row = i - scroll in
         if row >= 0 && row < rows
            && line_end > vend && line_start < pend then begin
           let s = max 0 (vend - line_start) in
           let e = min line_len (pend - line_start) in
           chgat_byte_range win line row hscroll cols s e
             Curses.A.normal Highlight.color_default_p
         end;
         byte_off := line_end + 1
       done
     end
   | None -> ());
  (* Helper to iterate over byte ranges that overlap a region *)
  let overlay_range range_start range_end attr color =
    let byte_off = ref 0 in
    for i = 0 to Buffer.line_count buf - 1 do
      let line = Buffer.get_line buf i in
      let line_len = String.length line in
      let line_start = !byte_off in
      let line_end = line_start + line_len in
      let row = i - scroll in
      if row >= 0 && row < rows
         && line_end > range_start && line_start < range_end then begin
        let s = max 0 (range_start - line_start) in
        let e = min line_len (range_end - line_start) in
        chgat_byte_range win line row hscroll cols s e attr color
      end;
      byte_off := line_end + 1
    done
  in
  (* Overlay explicit error range *)
  (match session with
   | Some sess ->
     (match Session.error_range sess with
      | Some (err_start, err_end) ->
        overlay_range err_start err_end Curses.A.normal Display.color_error
      | None -> ())
   | None -> ());
  (* Overlay selection highlight *)
  (match Buffer.selection buf with
   | Some (sel_start, sel_end) ->
     overlay_range sel_start sel_end Curses.A.normal Theme.pair_selection
   | None -> ());
  (* Minimap — render into its own window *)
  (match Display.minimap_win display with
   | Some mm_win ->
     let lines = Array.init (Buffer.line_count buf) (Buffer.get_line buf) in
     let num_lines = Array.length lines in
     let (mm_rows_avail, mm_cols_total) = Curses.getmaxyx mm_win in
     let mm_braille_cols = mm_cols_total - 1 in  (* -1 for separator column *)
     let verified_end = match session with
       | Some s -> Session.verified_end s | None -> 0 in
     let pending_end = match session with
       | Some s -> Session.pending_end s | None -> 0 in
     let error_range = match session with
       | Some s -> Session.error_range s | None -> None in
     let ypc = Minimap.y_per_cell ~num_lines ~available_rows:mm_rows_avail in
     let mm_data = Minimap.render ~lines ~num_lines
         ~verified_end ~pending_end ~error_range ~ypc
         ~cols:mm_braille_cols in
     let border_attr = Curses.A.color_pair Display.color_border in
     let _ = Curses.werase mm_win in
     Minimap.draw mm_win ~sep_col:0 ~col_offset:1 ~win_rows:mm_rows_avail
       ~minimap_rows:(Array.length mm_data)
       ~scroll ~visible_lines:rows ~ypc ~border_attr mm_data
   | None -> ());
  let (cl, cc) = Buffer.cursor buf in
  let cursor_row = cl - scroll in
  if cursor_row >= 0 && cursor_row < rows then begin
    let line = Buffer.get_line buf cl in
    let cursor_col = min (Utf8.byte_to_col line cc - hscroll) (cols - 1) in
    let cursor_col = max 0 cursor_col in
    Display.place_cursor display ~row:cursor_row ~col:cursor_col
  end else
    Display.place_cursor display ~row:0 ~col:0
  end (* if not in_help_mode *)

(* Check if cursor is in the verified region.
   [for_backspace] uses <= to also block editing at the boundary
   (since backspace reaches backward into verified text). *)
let cursor_byte_offset buf =
  let (cl, cc) = Buffer.cursor buf in
  let off = ref 0 in
  for i = 0 to cl - 1 do
    off := !off + String.length (Buffer.get_line buf i) + 1
  done;
  !off + cc

let cursor_in_target ?(for_backspace=false) (tab : Tab.t) =
  let buf = tab.buf in
  let session = tab.session in
  match session with
  | None -> false
  | Some sess ->
    let tend = Session.pending_end sess in
    if tend = 0 then false
    else
      let off = cursor_byte_offset buf in
      if for_backspace then off <= tend
      else off < tend

(* After undo/redo, retract target if the edit is inside the target region *)
let rewind_if_needed (tab : Tab.t) =
  let buf = tab.buf in
  let session = tab.session in
  match session with
  | None -> ()
  | Some sess ->
    let tend = Session.pending_end sess in
    if tend = 0 then ()
    else begin
      let cursor_off = cursor_byte_offset buf in
      if cursor_off < tend then
        (* Undo put cursor inside the target region — retract via go_to_cursor *)
        Session.go_to_cursor sess
    end

(* Format a key code as a readable character *)
let key_to_string k =
  if k = 27 then "␛"  (* Compose/Escape *)
  else if k >= 32 && k < 127 then String.make 1 (Char.chr k)
  else Printf.sprintf "<%d>" k

let format_compose_status cs =
  let pressed = Compose.keys_so_far cs in
  let completions = Compose.completions cs in
  let (_, status_cols) = Curses.getmaxyx (Curses.stdscr ()) in
  let avail = status_cols - 2 in
  let buf = Stdlib.Buffer.create 64 in
  let col = ref 0 in
  let truncated = ref false in
  let n = ref 0 in
  List.iter (fun (remaining, output) ->
    if !truncated then ()
    else begin
      let entry_buf = Stdlib.Buffer.create 16 in
      List.iter (fun k ->
        Stdlib.Buffer.add_string entry_buf (key_to_string k)
      ) pressed;
      List.iter (fun k ->
        Stdlib.Buffer.add_string entry_buf (key_to_string k)
      ) remaining;
      Stdlib.Buffer.add_char entry_buf ':';
      Stdlib.Buffer.add_string entry_buf output;
      let entry = Stdlib.Buffer.contents entry_buf in
      let entry_w = Utf8.string_width entry in
      let sep = if !n > 0 then 1 else 0 in
      if !col + sep + entry_w + 3 > avail && !n > 0 then begin
        Stdlib.Buffer.add_string buf " …";
        truncated := true
      end else begin
        if !n > 0 then Stdlib.Buffer.add_char buf ' ';
        Stdlib.Buffer.add_string buf entry;
        col := !col + sep + entry_w;
        incr n
      end
    end
  ) completions;
  Stdlib.Buffer.contents buf

(* Get the subject for a query from whichever pane is focused *)
let query_subject (tab : Tab.t) =
  let buf = tab.buf in
  match tab.focused_pane with
  | `Goals -> pane_selection_text tab.goals_sel tab.goals_lines_cache
  | `Messages -> pane_selection_text (Tab.active_msg_tab tab.msg).mt_sel (Tab.active_msg_tab tab.msg).mt_lines_cache
  | `Script ->
    match Buffer.selected_text buf with
    | Some text -> Some text
    | None -> Buffer.word_at_cursor buf

let run_query session phrase =
  match session with
  | Some s -> Session.query s phrase
  | None -> ()

let render_query_bar display =
  let text = Printf.sprintf "[%s]About [%s]Check [%s]Print [%s]Coercions [%s]Locate [%s]Show Proof [%s]Existentials  %s:close"
    Keys.query_about.display Keys.query_check.display Keys.query_print.display
    Keys.query_coercions.display Keys.query_locate.display Keys.query_proof.display
    Keys.query_existentials.display Keys.query_menu.display in
  Display.set_status display text

let in_theme_mode = ref false
let in_build_mode = ref false

let render_theme_bar display =
  let parts = List.mapi (fun i name ->
    let key = Char.chr (Char.code '1' + i) in
    let marker = if name = !current_theme_name then "*" else "" in
    Printf.sprintf "[%c]%s%s" key name marker
  ) Theme.available in
  Display.set_status display (String.concat "  " parts ^ "  F3:close")

let render_build_bar display =
  let running = Build.is_running () in
  let text = if running then
    let desc = match Build.description () with
      | Some d -> d | None -> "building" in
    Printf.sprintf "  Building: %s  [c]Cancel" desc
  else
    Printf.sprintf "[%s]File [%s]Deps [%s]All [%s]Cursor [%s]Clean  %s:close"
      Keys.build_file.display Keys.build_deps.display Keys.build_all.display
      Keys.build_cursor.display Keys.build_clean.display Keys.build_menu.display
  in
  Display.set_status display text

let render_options_bar display =
  let parts = List.map (fun (e : Printopts.entry) ->
    if e.enabled then
      Printf.sprintf "[%c]%s*" e.key e.label
    else
      Printf.sprintf "[%c]%s" e.key e.label
  ) Printopts.entries in
  let text = String.concat " " parts in
  Display.set_status display text

let update_status display (tab : Tab.t) =
  let buf = tab.buf in
  let session = tab.session in
  if !in_help_mode then
    Display.set_status display "F1:close  ↑↓/PgUp/PgDn:scroll  any other key:close"
  else if !in_build_mode then
    render_build_bar display
  else if !in_theme_mode then
    render_theme_bar display
  else if !in_options_mode then
    render_options_bar display
  else if !in_query_mode then
    render_query_bar display
  else match !compose_state with
  | Some cs when Compose.active cs ->
    Display.set_status display (format_compose_status cs)
  | _ -> begin
    let (cl, cc) = Buffer.cursor buf in
    let line = Buffer.get_line buf cl in
    let vcol = Utf8.byte_to_col line cc in
    let fname = Tab.project_relative_path (Buffer.filename buf) in
    let mod_flag =
      (if Buffer.modified buf then "*" else "") ^
      (if Buffer.disk_changed buf then "\xe2\x9f\xb3" else "") in
    let rocq_status = match session with
      | None -> ""
      | Some sess ->
        let ranges = Session.sentence_ranges sess in
        let n_verified = List.length (List.filter (fun (sd : Session.sentence_display) ->
          sd.sd_status = Session.Verified) ranges) in
        let n_processing = List.length (List.filter (fun (sd : Session.sentence_display) ->
          sd.sd_status = Session.Processing) ranges) in
        if n_processing > 0 then Printf.sprintf " [%d verified, %d processing]" n_verified n_processing
        else if n_verified > 0 then Printf.sprintf " [%d verified]" n_verified
        else ""
    in
    let reload_hint = if Buffer.disk_changed buf then
      " " ^ Keys.reload.display ^ ":Reload" else "" in
    let focus_info = match tab.focused_pane with
      | `Script ->
        Printf.sprintf "  %s:Save %s:Close %s:Opts %s:Query %s:Help%s"
          Keys.save.display Keys.close_tab.display Keys.options_menu.display
          Keys.query_menu.display Keys.help.display reload_hint
      | `Goals ->
        Printf.sprintf "  [Goals] %s:Pane %s:Query %s:Help%s"
          Keys.cycle_pane.display Keys.query_menu.display
          Keys.help.display reload_hint
      | `Messages ->
        Printf.sprintf "  [Messages] %s:Pane %s:Query %s:Help%s"
          Keys.cycle_pane.display Keys.query_menu.display
          Keys.help.display reload_hint
    in
    (* Horizontal scroll indicator *)
    let hscroll_ind =
      let hs = Buffer.hscroll buf in
      if hs > 0 then
        let (_, cols) = Display.script_dims display in
        (* Find max line width among visible lines *)
        let max_w = ref 0 in
        let scroll = Buffer.scroll_top buf in
        for i = scroll to min (scroll + 30) (Buffer.line_count buf - 1) do
          let w = Utf8.string_width (Buffer.get_line buf i) in
          if w > !max_w then max_w := w
        done;
        let total = max !max_w (hs + cols) in
        let bar_len = 10 in
        let thumb_start = hs * bar_len / total in
        let thumb_len = max 1 (cols * bar_len / total) in
        let b = Stdlib.Buffer.create 16 in
        Stdlib.Buffer.add_string b " \xe2\x97\x80";  (* ◀ *)
        for i = 0 to bar_len - 1 do
          if i >= thumb_start && i < thumb_start + thumb_len then
            Stdlib.Buffer.add_string b "\xe2\x96\x88"  (* █ *)
          else
            Stdlib.Buffer.add_string b "\xe2\x94\x80"  (* ─ *)
        done;
        Stdlib.Buffer.add_string b "\xe2\x96\xb6";  (* ▶ *)
        Stdlib.Buffer.contents b
      else ""
    in
    let extra = if !status_extra <> "" then "  " ^ !status_extra else "" in
    let status = Printf.sprintf "%s%s  Ln %d, Col %d%s%s%s%s"
      fname mod_flag (cl + 1) (vcol + 1) rocq_status extra hscroll_ind focus_info
    in
    Display.set_status display status
  end

let render_all display (tab : Tab.t) =
  ignore (tab.buf, tab.session);
  let msg_tab_names = List.map (fun (mt : Tab.msg_tab) -> mt.mt_name)
                        tab.msg.mt_tabs in
  Display.draw_chrome
    ~goals_focused:(tab.focused_pane = `Goals)
    ~messages_focused:(tab.focused_pane = `Messages)
    ~msg_tab_names
    ~msg_tab_active:tab.msg.mt_active
    display;
  render_script display tab;
  render_goals display tab;
  render_messages display tab;
  update_status display tab;
  (* Hide cursor when not in Script pane or when cursor is scrolled off-screen *)
  let cursor_visible =
    if tab.focused_pane <> `Script then false
    else
      let (cl, _) = Buffer.cursor tab.buf in
      let scroll = Buffer.scroll_top tab.buf in
      let (rows, _) = Display.script_dims display in
      cl >= scroll && cl < scroll + rows
  in
  let picker_open = File_picker.is_open () in
  let cursor_visible = cursor_visible && not picker_open in
  ignore (Curses.curs_set (if cursor_visible then 1 else 0));
  if picker_open then begin
    Display.refresh_all ~defer_update:true display;
    File_picker.render display;
    ignore (Curses.doupdate ())
  end else
    Display.refresh_all display

(* Convert screen coordinates to buffer (line, byte_col) position.
   Returns None if the coordinates are outside the script pane content. *)
let screen_to_buffer_pos display buf ~x ~y =
  let (rows, cols) = Display.script_dims display in
  let scroll = Buffer.scroll_top buf in
  let hscroll = Buffer.hscroll buf in
  (* x,y are absolute screen coords; subtract script window origin *)
  let (wy, wx) = Curses.getbegyx (Display.script_win display) in
  let row = y - wy in
  let col = x - wx in
  if row < 0 || row >= rows || col < 0 || col >= cols then None
  else begin
    let line_idx = scroll + row in
    if line_idx >= Buffer.line_count buf then None
    else begin
      let line = Buffer.get_line buf line_idx in
      let vcol = hscroll + col in
      let byte_col = Utf8.col_to_byte line vcol in
      Some (line_idx, byte_col)
    end
  end

(* Convert screen coords to a right-pane (line, byte_col) relative to the pane *)
let screen_to_pane_pos (tab : Tab.t) display ~x ~y pane_id =
  let win = match pane_id with
    | `Goals -> Display.goals_win display
    | `Messages -> Display.messages_win display
  in
  let (begy, begx) = Curses.getbegyx win in
  let (rows, cols) = Curses.getmaxyx win in
  let row = y - begy in
  let col = x - begx - 1 in (* -1 for margin *)
  if row < 0 || row >= rows || col < 0 || col >= cols then None
  else begin
    let scroll, lines_cache = match pane_id with
      | `Goals -> (tab.goals_scroll, tab.goals_lines_cache)
      | `Messages -> ((Tab.active_msg_tab tab.msg).mt_scroll, (Tab.active_msg_tab tab.msg).mt_lines_cache)
    in
    let line_idx = scroll + row in
    let lines = lines_cache in
    let n = List.length lines in
    if line_idx >= n then None
    else begin
      let line = List.nth lines line_idx in
      let byte_col = Utf8.col_to_byte line (max 0 col) in
      Some (line_idx, byte_col)  (* absolute line index *)
    end
  end

(* Select word at position in a pane's cached lines *)
let pane_select_word (ps : Tab.pane_selection) lines_cache line_idx byte_col =
  let lines = lines_cache in
  if line_idx >= List.length lines then ()
  else begin
    let line = List.nth lines line_idx in
    let len = String.length line in
    let col = min byte_col len in
    let is_id c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                  || (c >= '0' && c <= '9') || c = '_' || c = '\'' || c = '.' in
    if col < len && is_id line.[col] then begin
      let l = ref col in
      while !l > 0 && is_id line.[!l - 1] do decr l done;
      let r = ref col in
      while !r < len && is_id line.[!r] do incr r done;
      if !r > !l && line.[!r - 1] = '.' then decr r;
      if !r > !l then begin
        ps.ps_anchor_line <- line_idx;
        ps.ps_anchor_col <- !l;
        ps.ps_cursor_line <- line_idx;
        ps.ps_cursor_col <- !r;
        ps.ps_active <- true
      end
    end
  end

let insert_string (tab : Tab.t) s =
  if not (cursor_in_target tab) then
    let buf = tab.buf in
    String.iter (fun c ->
      if c = '\n' then Buffer.insert_newline buf
      else Buffer.insert_char buf c
    ) s

let handle_key ch (tab : Tab.t) display =
  let buf = tab.buf in
  let session = tab.session in
  (* Handle compose mode first *)
  let compose_handled = match !compose_state with
    | Some cs when Compose.active cs ->
      let result = Compose.feed cs ch in
      (match result with
       | Compose.Pending ->
         Display.set_status display (format_compose_status cs);
         Display.refresh_all display
       | Compose.Composed text ->
         ignore (Buffer.delete_selection buf);
         insert_string tab text
       | Compose.NoMatch ->
         (* If the key that broke compose was Escape, restart compose *)
         if ch = 27 then begin
           Compose.start cs;
           Display.set_status display (format_compose_status cs);
           Display.refresh_all display
         end);
      true
    | _ -> false
  in
  if compose_handled then
    Continue
  else if File_picker.is_open () then begin
    let (box_top, box_left, box_w, _box_h, visible_rows) =
      File_picker.box_geometry () in
    if ch = Curses.Key.mouse then begin
      let (_ok, x, y, bstate) = Display.get_mouse () in
      let b1_click = bstate land 0x4 <> 0 in
      let scroll_up = bstate land 0x10000 <> 0 in
      let scroll_down = bstate land 0x200000 <> 0 in
      if b1_click then
        match File_picker.handle_click ~y ~x ~box_top ~box_left
                ~box_width:box_w ~visible_rows with
        | File_picker.PickerOpen path -> Open_file path
        | _ -> Continue
      else if scroll_up then
        (File_picker.handle_scroll (-1) visible_rows; Continue)
      else if scroll_down then
        (File_picker.handle_scroll 1 visible_rows; Continue)
      else Continue
    end else
      match File_picker.handle_key ch visible_rows with
      | File_picker.PickerOpen path -> Open_file path
      | File_picker.PickerClose -> Continue
      | File_picker.PickerContinue -> Continue
  end
  else
  (* --- Global keys (work in any pane) --- *)
  let handle_global () =
    if Keys.match_key ch Keys.quit then Some Quit
    else if Keys.match_key ch Keys.close_tab then Some Close_tab
    else if Keys.match_key ch Keys.save then Some Save_prompt
    else if Keys.match_key ch Keys.jump_back then begin
      match pop_jump () with
      | Some jp ->
        jump_target := Some (jp.jp_line, jp.jp_col);
        Some (Jump_back jp)
      | None ->
        Display.set_status display "No previous location.";
        Some Continue
    end
    else if Keys.match_key ch Keys.open_file then begin
      let filename = Buffer.filename buf in
      let dir = match filename with
        | Some f -> Filename.dirname f
        | None -> Sys.getcwd ()
      in
      (match Project.find_project_file dir with
       | Some (project_dir, project_file) ->
         (* Gather list of currently open files for markers *)
         (* We don't have the tab manager here, so pass empty list.
            main.ml can set this up if needed. *)
         File_picker.open_picker ~project_dir ~project_file
           ~open_files:(!open_files_fn ())
       | None ->
         Display.set_status display "No _RocqProject found.");
      Some Continue
    end
    else if Keys.match_key ch Keys.interrupt then begin
      (match session with
       | Some s -> (try Unix.kill (Session.pid s) Sys.sigint with _ -> ())
       | None -> ());
      Some Continue
    end
    else if Keys.match_key ch Keys.step_forward then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.step_forward s | None -> ());
      Some Continue
    end
    else if Keys.match_key ch Keys.step_backward then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.step_backward s | None -> ());
      Some Continue
    end
    else if Keys.match_key ch Keys.go_to_cursor then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.go_to_cursor s | None -> ());
      Some Continue
    end
    else if ch = 27 then begin (* Escape *)
      if !in_build_mode then
        in_build_mode := false
      else if !in_theme_mode then
        in_theme_mode := false
      else if !in_options_mode then begin
        in_options_mode := false;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
      end else begin
        (* Peek at next char to distinguish bracketed paste from compose *)
        let next = peek_getch 0.025 in
        if next = Char.code '[' then begin
          (* Could be bracketed paste \e[200~ or other escape sequence *)
          let c1 = peek_getch 0.025 in
          let c2 = peek_getch 0.025 in
          let c3 = peek_getch 0.025 in
          let c4 = peek_getch 0.025 in
          if c1 = Char.code '2' && c2 = Char.code '0'
             && c3 = Char.code '0' && c4 = Char.code '~' then begin
            (* Bracketed paste — read until \e[201~ *)
            let paste_buf = Stdlib.Buffer.create 256 in
            let done_ = ref false in
            while not !done_ do
              let c = blocking_getch () in
              if c = 27 then begin
                (* Check for [201~ *)
                let n1 = peek_getch 0.025 in
                if n1 = Char.code '[' then begin
                  let n2 = peek_getch 0.025 in
                  let n3 = peek_getch 0.025 in
                  let n4 = peek_getch 0.025 in
                  let n5 = peek_getch 0.025 in
                  if n2 = Char.code '2' && n3 = Char.code '0'
                     && n4 = Char.code '1' && n5 = Char.code '~' then
                    done_ := true
                  else begin
                    (* Not end marker — add chars to paste buffer *)
                    Stdlib.Buffer.add_char paste_buf '\x1b';
                    Stdlib.Buffer.add_char paste_buf '[';
                    if n2 >= 0 then Stdlib.Buffer.add_char paste_buf (Char.chr n2);
                    if n3 >= 0 then Stdlib.Buffer.add_char paste_buf (Char.chr n3);
                    if n4 >= 0 then Stdlib.Buffer.add_char paste_buf (Char.chr n4);
                    if n5 >= 0 then Stdlib.Buffer.add_char paste_buf (Char.chr n5)
                  end
                end else begin
                  Stdlib.Buffer.add_char paste_buf '\x1b';
                  if n1 >= 0 then Stdlib.Buffer.add_char paste_buf (Char.chr n1)
                end
              end else if c >= 0 then
                Stdlib.Buffer.add_char paste_buf (Char.chr c)
              else
                done_ := true  (* timeout, shouldn't happen *)
            done;
            let text = Stdlib.Buffer.contents paste_buf in
            if text <> "" then begin
              ignore (Buffer.delete_selection buf);
              insert_string tab text;
              clipboard := text
            end
          end
          (* else: some other escape sequence, ignore *)
        end else if next = -1 then begin
          (* Plain Escape with no following char — start compose *)
          match !compose_state with
          | Some cs ->
            Compose.start cs;
            Display.set_status display (format_compose_status cs);
            Display.refresh_all display
          | None -> ()
        end else begin
          (* Escape + some other char — start compose and feed the char *)
          match !compose_state with
          | Some cs ->
            Compose.start cs;
            let result = Compose.feed cs next in
            (match result with
             | Compose.Pending ->
               Display.set_status display (format_compose_status cs);
               Display.refresh_all display
             | Compose.Composed text ->
               ignore (Buffer.delete_selection buf);
               insert_string tab text
             | Compose.NoMatch -> ())
          | None -> ()
        end
      end;
      Some Continue
    end
    else if Keys.match_key ch Keys.toggle_hyps then begin
      tab.show_all_hyps <- not tab.show_all_hyps; Some Continue end
    else if Keys.match_key ch Keys.options_menu then begin
      if !in_options_mode then begin
        in_options_mode := false;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
      end else in_options_mode := true;
      Some Continue
    end
    else if !in_options_mode then begin
      let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
      match List.find_opt (fun (e : Printopts.entry) -> e.key = c) Printopts.entries with
      | Some entry ->
        Printopts.toggle entry;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ());
        Some Continue
      | None ->
        (* Not a valid option key — exit options mode and fall through *)
        in_options_mode := false;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ());
        None
    end
    else if Keys.match_key ch Keys.reload then begin
      Some Reload
    end
    else if Keys.match_key ch Keys.theme_menu then begin
      in_theme_mode := not !in_theme_mode;
      Some Continue
    end
    else if !in_theme_mode then begin
      in_theme_mode := false;
      let idx = ch - Char.code '1' in
      let themes = Theme.available in
      if idx >= 0 && idx < List.length themes then begin
        let name = List.nth themes idx in
        let theme = Theme.find name in
        Theme.apply theme;
        current_theme_name := name
      end;
      Some Continue
    end
    else if Keys.match_key ch Keys.build_menu then begin
      in_build_mode := not !in_build_mode;
      Some Continue
    end
    else if !in_build_mode then begin
      in_build_mode := false;
      let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
      let project_info () =
        let filename = Buffer.filename buf in
        let dir = match filename with
          | Some f -> Filename.dirname f | None -> Sys.getcwd () in
        match Project.find_project_file dir with
        | Some (pd, _) -> Some pd
        | None -> None
      in
      if c = 'c' && Build.is_running () then begin
        Build.cancel ();
        Some Continue
      end
      else if c = 'f' then begin
        (match Buffer.filename buf, project_info () with
         | Some f, Some pd ->
           if Build.build_file ~project_dir:pd f then ()
           else Display.set_status display "Build already running."
         | _, None ->
           Display.set_status display "No project found."
         | None, _ ->
           Display.set_status display "No filename.");
        Some Continue
      end
      else if c = 'd' then begin
        (match Buffer.filename buf, project_info () with
         | Some f, Some pd ->
           if Build.build_deps ~project_dir:pd f then ()
           else Display.set_status display "Build already running."
         | _, None ->
           Display.set_status display "No project found."
         | None, _ ->
           Display.set_status display "No filename.");
        Some Continue
      end
      else if c = 'a' then begin
        (match project_info () with
         | Some pd ->
           if Build.build_all ~project_dir:pd then ()
           else Display.set_status display "Build already running."
         | None ->
           Display.set_status display "No project found.");
        Some Continue
      end
      else if c = 'x' then begin
        (match project_info () with
         | Some pd ->
           if Build.build_clean ~project_dir:pd then ()
           else Display.set_status display "Build already running."
         | None ->
           Display.set_status display "No project found.");
        Some Continue
      end
      else if c = 'c' then begin
        (* Build file at cursor — parse Require line *)
        let (cl, cc) = Buffer.cursor buf in
        let line = Buffer.get_line buf cl in
        (match Locate.parse_require_line line, project_info () with
         | Some (_, modules), Some pd ->
           let modname = Locate.module_at_col modules cc in
           (match modname with
            | Some m ->
              (* Resolve module to .v path *)
              (match Project.find_project_file (Filename.dirname
                       (match Buffer.filename buf with
                        | Some f -> f | None -> Sys.getcwd ())) with
               | Some (_, pf) ->
                 let lps = Project.load_paths pf in
                 (match Project.resolve_module lps m with
                  | Some v_path ->
                    if Build.build_file ~project_dir:pd v_path then ()
                    else Display.set_status display "Build already running."
                  | None ->
                    Display.set_status display ("Module not found: " ^ m))
               | None ->
                 Display.set_status display "No project found.")
            | None ->
              Display.set_status display "No module at cursor.")
         | _, None ->
           Display.set_status display "No project found."
         | None, _ ->
           Display.set_status display "Not on a Require line.");
        Some Continue
      end
      else
        (Some Continue)
    end
    else if Keys.match_key ch Keys.query_menu then begin
      in_query_mode := not !in_query_mode;
      Some Continue
    end
    else if !in_query_mode then begin
      in_query_mode := false;
      let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
      let handled =
        if c = 'a' then begin
          let subject = query_subject tab in
          (match subject with
           | Some word -> run_query session ("About " ^ word ^ ".")
           | None -> ()); true
        end else if c = 'c' then begin
          let subject = query_subject tab in
          (match subject with
           | Some word -> run_query session ("Check " ^ word ^ ".")
           | None -> ()); true
        end else if c = 'd' then begin
          let subject = query_subject tab in
          (match subject with
           | Some word -> run_query session ("Print " ^ word ^ ".")
           | None -> ()); true
        end else if c = 'l' then begin
          let subject = query_subject tab in
          (match subject with
           | Some word -> run_query session ("Locate " ^ word ^ ".")
           | None -> ()); true
        end else if c = 'g' then begin
          let subject = query_subject tab in
          (match subject, session with
           | Some word, Some s ->
             Session.query s "Print Graph.";
             let all_msgs = Session.messages s in
             (* Filter: keep lines containing " word >->" or ">-> word"
                (also match qualified names like "module.word") *)
             let matches_word line =
               let has pat = try
                 let _ = String.index_from line
                   (String.index line (String.get pat 0)) ' ' in
                 false  (* dummy — use simple substring check below *)
               with _ -> false in
               ignore has;
               let line_has s =
                 let slen = String.length s in
                 let llen = String.length line in
                 let rec check i =
                   if i + slen > llen then false
                   else if String.sub line i slen = s then true
                   else check (i + 1)
                 in check 0
               in
               line_has (" " ^ word ^ " >->")
               || line_has (">-> " ^ word)
               || line_has ("." ^ word ^ " >->")
             in
             let filtered = List.concat_map (fun msg ->
               let lines = String.split_on_char '\n' msg in
               List.filter (fun line ->
                 String.length line > 0 && matches_word line
               ) lines
             ) all_msgs in
             if filtered = [] then
               Session.set_messages s ["No coercions found for " ^ word ^ "."]
             else
               Session.set_messages s filtered
           | _, None -> ()
           | None, _ -> ()); true
        end else if c = 'p' then begin
          run_query session "Show Proof."; true
        end else if c = 'e' then begin
          run_query session "Show Existentials."; true
        end else false
      in
      if handled then Some Continue
      else None  (* fall through to normal handling *)
    end
    else if Keys.match_key ch Keys.cycle_pane then begin
      tab.focused_pane <- (match tab.focused_pane with
        | `Script -> `Goals | `Goals -> `Messages | `Messages -> `Script);
      Some Continue
    end
    else if ch = Curses.Key.resize then begin
      Display.resize display; Some Continue
    end
    else if !in_help_mode then begin
      let (rows, _) = Display.script_dims display in
      let n = List.length help_lines in
      let max_scroll = max 0 (n - rows) in
      let scroll_by delta =
        help_scroll := max 0 (min max_scroll (!help_scroll + delta)) in
      if ch = Curses.Key.up || ch = 259 then
        (scroll_by (-1); Some Continue)
      else if ch = Curses.Key.down || ch = 258 then
        (scroll_by 1; Some Continue)
      else if ch = Curses.Key.ppage || ch = 339 then
        (scroll_by (-rows); Some Continue)
      else if ch = Curses.Key.npage || ch = 338 then
        (scroll_by rows; Some Continue)
      else if ch = Curses.Key.home then
        (help_scroll := 0; Some Continue)
      else if ch = Curses.Key.end_ then
        (help_scroll := max_scroll; Some Continue)
      else if ch = Curses.Key.mouse then begin
        let (_ok, _x, _y, bstate) = Display.get_mouse () in
        let scroll_up = bstate land 0x10000 <> 0 in
        let scroll_down = bstate land 0x200000 <> 0 in
        if scroll_up then scroll_by (-3)
        else if scroll_down then scroll_by 3;
        Some Continue
      end
      else begin
        in_help_mode := false;
        help_scroll := 0;
        Some Continue
      end
    end
    else if ch = Curses.Key.mouse then begin
      let (_ok, x, y, bstate) = Display.get_mouse () in
      let b1_release = bstate land 0x1 <> 0 in
      let b1_press = bstate land 0x2 <> 0 in
      let b1_click = bstate land 0x4 <> 0 in
      let b1_dblclick = bstate land 0x8 <> 0 in
      let has_shift = bstate land 0x4000000 <> 0 in
      let has_cmd = bstate land 0x8000000 <> 0 in
      let is_motion = bstate land 0x10000000 <> 0 in
      let b1_any = b1_click || b1_dblclick || b1_press in
      if !dragging <> NoDrag then begin
        (* Active border drag *)
        (match !dragging with
         | DragV -> Display.move_split_v display x
         | DragH -> Display.move_split_h display y
         | DragMinimap -> Display.move_minimap_border display x
         | DragMinimapScroll ->
           (match Display.minimap_win display with
            | Some mm_win ->
              let (mm_begy, _) = Curses.getbegyx mm_win in
              let (mm_rows, _) = Curses.getmaxyx mm_win in
              let mm_row = y - mm_begy in
              if mm_row >= 0 && mm_row < mm_rows then begin
                let num_lines = Buffer.line_count buf in
                let ypc = Minimap.y_per_cell ~num_lines ~available_rows:mm_rows in
                let target_line = mm_row * ypc in
                let (srows, _) = Display.script_dims display in
                let target_scroll = max 0 (target_line - srows / 2) in
                let max_scroll = max 0 (num_lines - srows) in
                Buffer.set_scroll_top buf (min target_scroll max_scroll);
                tab.suppress_ensure_visible <- true
              end
            | None -> ())
         | NoDrag -> ());
        if b1_release then dragging := NoDrag
      end
      else if tab.mouse_selecting then begin
        (* Active text selection drag *)
        let pane = Display.pane_at display ~x ~y in
        if pane = Display.PScript then begin
          match screen_to_buffer_pos display buf ~x ~y with
          | Some (line, byte_col) -> Buffer.move_to buf line byte_col
          | None -> ()
        end else if pane = Display.PGoals || pane = Display.PMessages then begin
          let (ps, pane_id) =
            if pane = Display.PGoals then (tab.goals_sel, `Goals)
            else ((Tab.active_msg_tab tab.msg).mt_sel, `Messages)
          in
          (match screen_to_pane_pos tab display ~x ~y pane_id with
           | Some (row, byte_col) ->
             ps.ps_cursor_line <- row;
             ps.ps_cursor_col <- byte_col
           | None -> ())
        end;
        if b1_release then
          tab.mouse_selecting <- false
      end
      else begin
        let pane = Display.pane_at display ~x ~y in
        let scroll_up = bstate land 0x10000 <> 0 && not b1_any in
        let scroll_down = bstate land 0x200000 <> 0 && not b1_any in
        let scroll_amt = 3 in
        if scroll_up || scroll_down then begin
          let delta = if scroll_up then -scroll_amt else scroll_amt in
          match pane with
          | Display.PScript ->
            let (rows, _) = Display.script_dims display in
            let max_scroll = max 0 (Buffer.line_count buf - rows) in
            Buffer.set_scroll_top buf (max 0 (min max_scroll (Buffer.scroll_top buf + delta)));
            tab.suppress_ensure_visible <- true
          | Display.PGoals ->
            tab.goals_scroll <- max 0 (tab.goals_scroll + delta)
          | Display.PMessages ->
            (Tab.active_msg_tab tab.msg).mt_scroll <- max 0 ((Tab.active_msg_tab tab.msg).mt_scroll + delta)
          | _ -> ()
        end
        else if pane = Display.PTabBar && (b1_click || b1_press) then begin
          (* Tab bar click — delegate to callback *)
          (match !tab_bar_click_handler with
           | Some f -> f x
           | None -> ())
        end
        else if pane = Display.PBorderH && (b1_click || b1_press) then begin
          (* Check if click is on a messages sub-tab name *)
          let tab_names = List.map (fun (mt : Tab.msg_tab) -> mt.mt_name)
                            tab.msg.mt_tabs in
          match Display.msg_tab_at_x display ~x ~tab_names with
          | Some i ->
            tab.msg.mt_active <- i
          | None ->
            if b1_press then dragging := DragH
        end
        else if (pane = Display.PBorderV || pane = Display.PBorderMinimap)
                && b1_press then
          dragging := (match pane with
            | Display.PBorderMinimap -> DragMinimap
            | _ -> DragV)
        else if (pane = Display.PGoals || pane = Display.PMessages)
                && (b1_click || b1_dblclick || b1_press) then begin
          (* Click in right pane — focus it *)
          tab.focused_pane <- (if pane = Display.PGoals then `Goals else `Messages);
          let (ps, lines_cache, _scroll_ref, pane_id) =
            if pane = Display.PGoals then
              (tab.goals_sel, tab.goals_lines_cache, tab.goals_scroll, `Goals)
            else
              ((Tab.active_msg_tab tab.msg).mt_sel, (Tab.active_msg_tab tab.msg).mt_lines_cache, (Tab.active_msg_tab tab.msg).mt_scroll, `Messages)
          in
          if b1_dblclick then begin
            match screen_to_pane_pos tab display ~x ~y pane_id with
            | Some (row, byte_col) ->
              pane_select_word ps lines_cache row byte_col
            | None -> ()
          end
          else if b1_press then begin
            match screen_to_pane_pos tab display ~x ~y pane_id with
            | Some (row, byte_col) ->
              clear_pane_selection ps;
              ps.ps_anchor_line <- row;
              ps.ps_anchor_col <- byte_col;
              ps.ps_cursor_line <- row;
              ps.ps_cursor_col <- byte_col;
              ps.ps_active <- true;
              tab.mouse_selecting <- true
            | None -> ()
          end
          else begin (* b1_click *)
            match screen_to_pane_pos tab display ~x ~y pane_id with
            | Some (_, _) -> clear_pane_selection ps
            | None -> ()
          end
        end
        else if pane = Display.PMinimap && (b1_click || b1_press) then begin
          (* Click/drag on minimap — scroll to that position *)
          (match Display.minimap_win display with
           | Some mm_win ->
             let (mm_begy, _) = Curses.getbegyx mm_win in
             let (mm_rows, _) = Curses.getmaxyx mm_win in
             let mm_row = y - mm_begy in
             if mm_row >= 0 && mm_row < mm_rows then begin
               let num_lines = Buffer.line_count buf in
               let ypc = Minimap.y_per_cell ~num_lines ~available_rows:mm_rows in
               let target_line = mm_row * ypc in
               let (srows, _) = Display.script_dims display in
               let target_scroll = max 0 (target_line - srows / 2) in
               let max_scroll = max 0 (num_lines - srows) in
               Buffer.set_scroll_top buf (min target_scroll max_scroll);
               tab.suppress_ensure_visible <- true
             end;
             if b1_press then dragging := DragMinimapScroll
           | None -> ())
        end
        else if pane = Display.PScript && (b1_click || b1_dblclick || b1_press) then begin
          tab.focused_pane <- `Script;
          clear_pane_selection tab.goals_sel;
          clear_pane_selection (Tab.active_msg_tab tab.msg).mt_sel;
          if has_cmd then begin
            match screen_to_buffer_pos display buf ~x ~y with
            | Some (line, byte_col) ->
              Buffer.move_to buf line byte_col;
              (match session with
               | Some s ->
                 Session.go_to_cursor s
               | None -> ())
            | None -> ()
          end
          else if b1_dblclick then begin
            match screen_to_buffer_pos display buf ~x ~y with
            | Some (line, byte_col) ->
              Buffer.clear_selection buf;
              Buffer.move_to buf line byte_col;
              Buffer.select_word_at_cursor buf
            | None -> ()
          end
          else if has_shift && (b1_click || b1_press) then begin
            match screen_to_buffer_pos display buf ~x ~y with
            | Some (line, byte_col) ->
              if Buffer.selection buf = None then Buffer.set_anchor buf;
              Buffer.move_to buf line byte_col
            | None -> ()
          end
          else if b1_press && not is_motion then begin
            (* Start drag selection *)
            match screen_to_buffer_pos display buf ~x ~y with
            | Some (line, byte_col) ->
              Buffer.clear_selection buf;
              Buffer.move_to buf line byte_col;
              Buffer.set_anchor buf;
              tab.mouse_selecting <- true
            | None -> ()
          end
          else if b1_click then begin
            (* Simple click — just position cursor *)
            match screen_to_buffer_pos display buf ~x ~y with
            | Some (line, byte_col) ->
              Buffer.clear_selection buf;
              Buffer.move_to buf line byte_col
            | None -> ()
          end
        end
      end;
      Some Continue
    end
    else if Keys.match_key ch Keys.jump_to_def then begin
      let (cl, cc) = Buffer.cursor buf in
      let line = Buffer.get_line buf cl in
      (* Try Require line first *)
      let result = match Locate.parse_require_line line with
        | Some (_, modules) ->
          let modname = Locate.module_at_col modules cc in
          (* Use Locate Library to find the .vo *)
          (match modname, session with
           | Some m, Some s ->
             Session.query s ("Locate Library " ^ m ^ ".");
             let msgs = String.concat "\n" (Session.messages s) in
             (match Locate.parse_locate_library msgs with
              | Some vo_path ->
                let v_path = Locate.vo_to_v vo_path in
                if Sys.file_exists v_path then Some (v_path, None)
                else begin
                  Display.set_status display
                    ("Source not found: " ^ v_path);
                  None
                end
              | None ->
                (* Try local resolution *)
                let dir = match Buffer.filename buf with
                  | Some f -> Filename.dirname f | None -> Sys.getcwd () in
                (match Project.find_project_file dir with
                 | Some (_, pf) ->
                   let lps = Project.load_paths pf in
                   (match Project.resolve_module lps m with
                    | Some path -> Some (path, None)
                    | None ->
                      Display.set_status display ("Module not found: " ^ m);
                      None)
                 | None ->
                   Display.set_status display ("Module not found: " ^ m);
                   None))
           | Some m, None ->
             (* No session — try local resolution *)
             let dir = match Buffer.filename buf with
               | Some f -> Filename.dirname f | None -> Sys.getcwd () in
             (match Project.find_project_file dir with
              | Some (_, pf) ->
                let lps = Project.load_paths pf in
                (match Project.resolve_module lps m with
                 | Some path -> Some (path, None)
                 | None ->
                   Display.set_status display ("Module not found: " ^ m);
                   None)
              | None ->
                Display.set_status display "No session and no project.";
                None)
           | None, _ ->
             Display.set_status display "No module name at cursor.";
             None)
        | None ->
          (* Not a Require line — try Locate for identifier *)
          let word = match Buffer.selected_text buf with
            | Some t -> Some t | None -> Buffer.word_at_cursor buf in
          (match word, session with
           | Some w, Some s ->
             Session.query s ("Locate " ^ w ^ ".");
             let msgs = String.concat "\n" (Session.messages s) in
             (match Locate.parse_locate msgs with
              | Some (_kind, module_path, def_name) ->
                Session.query s ("Locate Library " ^ module_path ^ ".");
                let msgs2 = String.concat "\n" (Session.messages s) in
                (match Locate.parse_locate_library msgs2 with
                 | Some vo_path ->
                   let v_path = Locate.vo_to_v vo_path in
                   let target_line =
                     if Sys.file_exists v_path then begin
                       let glob_path = Locate.vo_to_glob vo_path in
                       if Sys.file_exists glob_path then
                         let entries = Glob.parse glob_path in
                         match Glob.find_definition entries def_name with
                         | Some e -> Glob.byte_offset_to_line v_path e.bp
                         | None -> None
                       else None
                     end else None
                   in
                   if Sys.file_exists v_path then
                     Some (v_path, target_line)
                   else begin
                     Display.set_status display
                       ("Source not found: " ^ v_path);
                     None
                   end
                 | None ->
                   Display.set_status display
                     ("Cannot locate library for " ^ module_path);
                   None)
              | None ->
                Display.set_status display
                  ("Cannot locate: " ^ msgs);
                None)
           | Some _, None ->
             Display.set_status display "No session.";
             None
           | None, _ ->
             Display.set_status display "No identifier at cursor.";
             None)
      in
      (match result with
       | Some (path, line_opt) ->
         push_jump tab;
         (match line_opt with
          | Some l -> jump_target := Some (l, 0)
          | None -> jump_target := None);
         Some (Open_file path)
       | None -> Some Continue)
    end
    else if Keys.match_key ch Keys.help then begin
      if !in_help_mode then begin
        in_help_mode := false;
        help_scroll := 0
      end else
        in_help_mode := true;
      Some Continue
    end
    else if Keys.match_key ch Keys.minimap then begin
      if Display.minimap_width display > 0 then
        Display.set_minimap_width display 0
      else
        Display.set_minimap_width display Minimap.width;
      Some Continue
    end
    else if Keys.match_key ch Keys.about then begin
      let subject = match tab.focused_pane with
        | `Goals -> pane_selection_text tab.goals_sel tab.goals_lines_cache
        | `Messages -> pane_selection_text (Tab.active_msg_tab tab.msg).mt_sel (Tab.active_msg_tab tab.msg).mt_lines_cache
        | `Script ->
          match Buffer.selected_text buf with
          | Some text -> Some text | None -> Buffer.word_at_cursor buf
      in
      (match subject, session with
       | Some word, Some s ->
         Session.query s ("About " ^ word ^ ".")       | _ -> ());
      Some Continue
    end
    else if Keys.match_key ch Keys.print_query then begin
      let subject = match tab.focused_pane with
        | `Goals -> pane_selection_text tab.goals_sel tab.goals_lines_cache
        | `Messages -> pane_selection_text (Tab.active_msg_tab tab.msg).mt_sel (Tab.active_msg_tab tab.msg).mt_lines_cache
        | `Script ->
          match Buffer.selected_text buf with
          | Some text -> Some text | None -> Buffer.word_at_cursor buf
      in
      (match subject, session with
       | Some word, Some s ->
         Session.query s ("Print " ^ word ^ ".")       | _ -> ());
      Some Continue
    end
    else if Keys.match_key ch Keys.copy then begin
      let text = match tab.focused_pane with
        | `Goals -> pane_selection_text tab.goals_sel tab.goals_lines_cache
        | `Messages -> pane_selection_text (Tab.active_msg_tab tab.msg).mt_sel (Tab.active_msg_tab tab.msg).mt_lines_cache
        | `Script -> Buffer.selected_text buf
      in
      (match text with
       | Some t ->
         clipboard := t;
         Clipboard.copy_to_system t
       | None -> ());
      Some Continue
    end
    else if Keys.match_key ch Keys.undo then begin
      Buffer.undo buf;
      rewind_if_needed tab;
      Some Continue
    end
    else if Keys.match_key ch Keys.redo then begin
      Buffer.redo buf;
      rewind_if_needed tab;
      Some Continue
    end
    else None
  in
  (* --- Scroll keys for Goals/Messages panes --- *)
  let handle_scroll scroll_ref win_fn =
    if ch = Curses.Key.up then begin decr scroll_ref; Some Continue end
    else if ch = Curses.Key.down then begin incr scroll_ref; Some Continue end
    else if ch = Curses.Key.npage then begin
      let (rows, _) = Curses.getmaxyx (win_fn ()) in
      scroll_ref := !scroll_ref + (rows - 1); Some Continue
    end
    else if ch = Curses.Key.ppage then begin
      let (rows, _) = Curses.getmaxyx (win_fn ()) in
      scroll_ref := max 0 (!scroll_ref - (rows - 1)); Some Continue
    end
    else None
  in
  (* --- Script pane keys --- *)
  let handle_script () =
    (* Navigation with selection *)
    if ch = Curses.Key.sleft then begin
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_left buf; Some Continue
    end
    else if ch = Curses.Key.sright then begin
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_right buf; Some Continue
    end
    else if ch = Curses.Key.sr then begin
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_up buf; Some Continue
    end
    else if ch = Curses.Key.sf then begin
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_down buf; Some Continue
    end
    else if ch = Curses.Key.shome then begin
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_home buf; Some Continue
    end
    else if ch = Curses.Key.send then begin
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_end buf; Some Continue
    end
    else if ch = Curses.Key.sprevious then begin
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      let (rows, _) = Display.script_dims display in
      Buffer.move_page_up buf (rows - 1); Some Continue
    end
    else if ch = Curses.Key.snext then begin
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      let (rows, _) = Display.script_dims display in
      Buffer.move_page_down buf (rows - 1); Some Continue
    end
    (* Navigation without selection *)
    else if ch = Curses.Key.up then begin
      Buffer.clear_selection buf; Buffer.move_up buf; Some Continue
    end
    else if ch = Curses.Key.down then begin
      Buffer.clear_selection buf; Buffer.move_down buf; Some Continue
    end
    else if ch = Curses.Key.left then begin
      Buffer.clear_selection buf; Buffer.move_left buf; Some Continue
    end
    else if ch = Curses.Key.right then begin
      Buffer.clear_selection buf; Buffer.move_right buf; Some Continue
    end
    else if ch = Curses.Key.home then begin
      Buffer.clear_selection buf; Buffer.move_home buf; Some Continue
    end
    else if ch = Curses.Key.end_ then begin
      Buffer.clear_selection buf; Buffer.move_end buf; Some Continue
    end
    else if ch = Curses.Key.npage then begin
      Buffer.clear_selection buf;
      let (rows, _) = Display.script_dims display in
      Buffer.move_page_down buf (rows - 1); Some Continue
    end
    else if ch = Curses.Key.ppage then begin
      Buffer.clear_selection buf;
      let (rows, _) = Display.script_dims display in
      Buffer.move_page_up buf (rows - 1); Some Continue
    end
    (* Clipboard *)
    else if Keys.match_key ch Keys.cut then begin
      if not (cursor_in_target tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        match Buffer.delete_selection buf with
        | Some text ->
          clipboard := text;
          Clipboard.copy_to_system text
        | None ->
          clipboard := "";
          Buffer.cut_line buf
      end;
      Some Continue
    end
    else if Keys.match_key ch Keys.paste then begin
      if not (cursor_in_target tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        ignore (Buffer.delete_selection buf);
        if !clipboard <> "" then
          String.iter (fun c ->
            if c = '\n' then Buffer.insert_newline buf
            else Buffer.insert_char buf c
          ) !clipboard
        else Buffer.paste buf
      end;
      Some Continue
    end
    (* Editing — clear error region on any edit *)
    else if ch = Curses.Key.dc then begin
      let clear_err () = match session with Some s -> Session.clear_error s | None -> () in
      if not (cursor_in_target tab) then begin
        clear_err ();
        (match Buffer.delete_selection buf with
         | Some _ -> () | None -> Buffer.delete_char_at buf)
      end;
      Some Continue
    end
    else if ch = Curses.Key.backspace || ch = 127 || ch = 8 then begin
      if not (cursor_in_target ~for_backspace:true tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        (match Buffer.delete_selection buf with
         | Some _ -> () | None -> Buffer.delete_char_before buf)
      end;
      Some Continue
    end
    else if ch = 10 || ch = 13 || ch = Curses.Key.enter then begin
      if not (cursor_in_target tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        ignore (Buffer.delete_selection buf);
        Buffer.insert_newline buf
      end;
      Some Continue
    end
    else if ch >= 32 && ch < 127 then begin
      if not (cursor_in_target tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        ignore (Buffer.delete_selection buf);
        Buffer.insert_char buf (Char.chr ch)
      end;
      Some Continue
    end
    else None
  in
  let action =
    match handle_global () with
    | Some a -> a
    | None ->
      match tab.focused_pane with
      | `Goals ->
        let r = ref tab.goals_scroll in
        let result = handle_scroll r (fun () -> Display.goals_win display) in
        tab.goals_scroll <- !r;
        (match result with Some a -> a | None -> Continue)
      | `Messages ->
        let r = ref (Tab.active_msg_tab tab.msg).mt_scroll in
        let result = handle_scroll r (fun () -> Display.messages_win display) in
        (Tab.active_msg_tab tab.msg).mt_scroll <- !r;
        (match result with Some a -> a | None -> Continue)
      | `Script ->
        (match handle_script () with
         | Some a -> a | None -> Continue)
  in
  action

(* Convert a Kitty key event to a legacy keycode for handle_key *)
let kitty_to_legacy (kk : Keys.kitty_key) =
  let kc = kk.kk_keycode in
  let m = kk.kk_modifier in
  if m = 1 then
    (* No modifier — use keycode directly for Enter(13), Tab(9), etc.
       For printable chars, use keycode as-is *)
    Some kc
  else if m = 5 then
    (* Ctrl — map letter to ctrl code *)
    if kc >= 97 && kc <= 122 then Some (kc - 96)  (* ctrl+a=1 .. ctrl+z=26 *)
    else None
  else if m = 2 then
    (* Shift — for arrows, map to shift+arrow codes *)
    (match kc with
     | 57352 (* up *) -> Some 337
     | 57353 (* down *) -> Some 336
     | 57354 (* right *) -> Some 402
     | 57355 (* left *) -> Some 393
     | _ ->
       (* Shift+printable: just use the keycode *)
       if kc >= 32 && kc < 127 then Some kc else None)
  else if m = 3 then
    (* Alt — for arrows, map to alt+arrow *)
    (match kc with
     | 57352 -> Some 564  | 57353 -> Some 523
     | 57354 -> Some 558  | 57355 -> Some 543
     | _ -> None)
  else
    None

let handle_key_event (ev : Keys.key_event) (tab : Tab.t) display =
  match ev with
  | Keys.RawKey ch -> handle_key ch tab display
  | Keys.KittyKey kk ->
    (match kitty_to_legacy kk with
     | Some ch -> handle_key ch tab display
     | None -> Continue)
  | Keys.Paste text ->
    let buf = tab.buf in
    if not (cursor_in_target tab) then begin
      (match tab.session with Some s -> Session.clear_error s | None -> ());
      ignore (Buffer.delete_selection buf);
      insert_string tab text
    end;
    Continue
  | Keys.Escape ->
    (* Standalone ESC — start compose *)
    (match !compose_state with
     | Some cs ->
       Compose.start cs;
       Display.set_status display (format_compose_status cs);
       Display.refresh_all display
     | None -> ());
    Continue
