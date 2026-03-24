type action =
  | Continue
  | Quit
  | Save_prompt

let init_error_msg = ref ""
let set_init_error msg = init_error_msg := msg

(* Pane focus *)
type pane = Script | Goals | Messages

let focused_pane = ref Script

(* Scroll state for right panes *)
let goals_scroll = ref 0
let messages_scroll = ref 0

(* Goals display mode *)
let show_all_hyps = ref false

(* Clipboard for copy/paste (separate from cut-line buffer) *)
let clipboard = ref ""

(* Compose input method *)
let compose_state : Compose.t option ref = ref None

let init_compose () =
  compose_state := Some (Compose.load ())

(* Print options mode *)
let in_options_mode = ref false

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

(* Render a scrollable text pane *)
let render_text_pane win scroll_ref lines_list =
  let _ = Curses.werase win in
  let (rows, cols) = Curses.getmaxyx win in
  Curses.scrollok win false;
  let wrapped = wrap_lines cols lines_list in
  let n = List.length wrapped in
  scroll_ref := max 0 (min !scroll_ref (max 0 (n - rows)));
  List.iteri (fun i line ->
    let row = i - !scroll_ref in
    if row >= 0 && row < rows then
      ignore (Curses.mvwaddstr win row 1 line)
  ) wrapped;
  Curses.scrollok win true;
  let _ = Curses.wnoutrefresh win in
  ()

let render_goals display session =
  let win = Display.goals_win display in
  let lines = match session with
    | None ->
      let msg = if !init_error_msg <> "" then !init_error_msg
                else "No Rocq session." in
      String.split_on_char '\n' msg
    | Some sess ->
      match Session.goals_text ~all_hyps:!show_all_hyps sess with
      | None -> ["No proof in progress."]
      | Some text -> String.split_on_char '\n' text
  in
  render_text_pane win goals_scroll lines

let render_messages display session =
  let win = Display.messages_win display in
  let lines = match session with
    | None -> []
    | Some sess ->
      (* Split each message on newlines since Pp output can be multi-line *)
      List.concat_map (fun msg ->
        String.split_on_char '\n' msg
      ) (Session.messages sess)
  in
  render_text_pane win messages_scroll lines

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

let render_script display buf session =
  let win = Display.script_win display in
  let (rows, cols) = Display.script_dims display in
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
  let (cl, cc) = Buffer.cursor buf in
  let line = Buffer.get_line buf cl in
  let cursor_row = cl - scroll in
  let cursor_col = min (Utf8.byte_to_col line cc - hscroll) (cols - 1) in
  let cursor_col = max 0 cursor_col in
  Display.place_cursor display ~row:cursor_row ~col:cursor_col

let cursor_in_verified buf session =
  match session with
  | None -> false
  | Some sess ->
    let vend = Session.verified_end sess in
    if vend = 0 then false
    else begin
      let (cl, cc) = Buffer.cursor buf in
      let off = ref 0 in
      for i = 0 to cl - 1 do
        off := !off + String.length (Buffer.get_line buf i) + 1
      done;
      !off + cc < vend
    end

let render_options_bar display =
  let parts = List.map (fun (e : Printopts.entry) ->
    if e.enabled then
      Printf.sprintf "[%c]%s*" e.key e.label
    else
      Printf.sprintf "[%c]%s" e.key e.label
  ) Printopts.entries in
  let text = String.concat " " parts in
  Display.set_status display text

let update_status display buf session =
  if !in_options_mode then
    render_options_bar display
  else begin
    let (cl, cc) = Buffer.cursor buf in
    let line = Buffer.get_line buf cl in
    let vcol = Utf8.byte_to_col line cc in
    let fname = match Buffer.filename buf with
      | Some f -> Filename.basename f
      | None -> "[new]"
    in
    let mod_flag = if Buffer.modified buf then "*" else "" in
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
    let focus_info = match !focused_pane with
      | Script -> "  ^O:Save ^X:Exit ^T:Opts ^W:Pane"
      | Goals -> "  [Goals] ^W:Pane"
      | Messages -> "  [Messages] ^W:Pane"
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
    let status = Printf.sprintf "%s%s  Ln %d, Col %d%s%s%s"
      fname mod_flag (cl + 1) (vcol + 1) rocq_status hscroll_ind focus_info
    in
    Display.set_status display status
  end

let render_all display buf session =
  Display.draw_chrome
    ~goals_focused:(!focused_pane = Goals)
    ~messages_focused:(!focused_pane = Messages)
    display;
  render_script display buf session;
  render_goals display session;
  render_messages display session;
  update_status display buf session;
  (* Hide cursor when not in Script pane *)
  ignore (Curses.curs_set (if !focused_pane = Script then 1 else 0));
  Display.refresh_all display

let insert_string buf session s =
  if not (cursor_in_verified buf session) then
    String.iter (fun c ->
      if c = '\n' then Buffer.insert_newline buf
      else Buffer.insert_char buf c
    ) s

let handle_key ch buf display session =
  (* Handle compose mode first *)
  let compose_handled = match !compose_state with
    | Some cs when Compose.active cs ->
      let result = Compose.feed cs ch in
      (match result with
       | Compose.Pending ->
         Display.set_status display "Compose...";
         Display.refresh_all display
       | Compose.Composed text ->
         ignore (Buffer.delete_selection buf);
         insert_string buf session text
       | Compose.NoMatch ->
         (* If the key that broke compose was Escape, restart compose *)
         if ch = 27 then begin
           Compose.start cs;
           Display.set_status display "Compose:";
           Display.refresh_all display
         end);
      true
    | _ -> false
  in
  if compose_handled then begin
    (match !compose_state with
     | Some cs when not (Compose.active cs) ->
       Curses.timeout 100;  (* restore timeout *)
       render_all display buf session
     | _ -> ());
    Continue
  end else
  (* --- Global keys (work in any pane) --- *)
  let handle_global () =
    if ch = 24 then Some Quit
    else if ch = 15 then Some Save_prompt
    else if ch = 3 then begin (* ^C — interrupt rocqtop *)
      (match session with
       | Some s -> (try Unix.kill (Session.pid s) Sys.sigint with _ -> ())
       | None -> ());
      Some Continue
    end
    else if ch = 14 || ch = 526 || ch = 532 || ch = 517 then begin
      goals_scroll := 0; messages_scroll := 0;
      (match session with Some s -> Session.step_forward s | None -> ());
      Some Continue
    end
    else if ch = 16 || ch = 567 || ch = 573 || ch = 558 then begin
      goals_scroll := 0; messages_scroll := 0;
      (match session with Some s -> Session.step_backward s | None -> ());
      Some Continue
    end
    else if ch = 5 then begin (* ^E — go to cursor *)
      goals_scroll := 0; messages_scroll := 0;
      (match session with Some s -> Session.go_to_cursor s | None -> ());
      Some Continue
    end
    else if ch = 27 then begin (* Escape *)
      if !in_options_mode then begin
        in_options_mode := false;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
      end else begin
        match !compose_state with
        | Some cs ->
          Compose.start cs;
          Curses.timeout (-1);
          Display.set_status display "Compose:";
          Display.refresh_all display
        | None -> ()
      end;
      Some Continue
    end
    else if ch = 7 then begin show_all_hyps := not !show_all_hyps; Some Continue end
    else if ch = 20 then begin (* ^T *)
      if !in_options_mode then begin
        in_options_mode := false;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
      end else in_options_mode := true;
      Some Continue
    end
    else if !in_options_mode then begin
      let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
      (match List.find_opt (fun (e : Printopts.entry) -> e.key = c) Printopts.entries with
       | Some entry ->
         Printopts.toggle entry;
         (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
       | None -> ());
      Some Continue
    end
    else if ch = 23 then begin (* ^W *)
      focused_pane := (match !focused_pane with
        | Script -> Goals | Goals -> Messages | Messages -> Script);
      Some Continue
    end
    else if ch = Curses.Key.resize then begin
      Display.resize display; Some Continue
    end
    else if ch = 1 then begin (* ^A — About *)
      let subject = match Buffer.selected_text buf with
        | Some text -> Some text | None -> Buffer.word_at_cursor buf in
      (match subject, session with
       | Some word, Some s ->
         Session.query s ("About " ^ word ^ "."); focused_pane := Messages
       | _ -> ());
      Some Continue
    end
    else if ch = 4 then begin (* ^D — Print *)
      let subject = match Buffer.selected_text buf with
        | Some text -> Some text | None -> Buffer.word_at_cursor buf in
      (match subject, session with
       | Some word, Some s ->
         Session.query s ("Print " ^ word ^ "."); focused_pane := Messages
       | _ -> ());
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
    else if ch = 25 then begin (* ^Y — copy *)
      (match Buffer.selected_text buf with
       | Some text -> clipboard := text | None -> ());
      Some Continue
    end
    else if ch = 11 then begin (* ^K — cut *)
      if not (cursor_in_verified buf session) then begin
        match Buffer.delete_selection buf with
        | Some text -> clipboard := text
        | None -> Buffer.cut_line buf
      end;
      Some Continue
    end
    else if ch = 21 then begin (* ^U — paste *)
      if not (cursor_in_verified buf session) then begin
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
    (* Editing *)
    else if ch = Curses.Key.dc then begin
      if not (cursor_in_verified buf session) then
        (match Buffer.delete_selection buf with
         | Some _ -> () | None -> Buffer.delete_char_at buf);
      Some Continue
    end
    else if ch = Curses.Key.backspace || ch = 127 || ch = 8 then begin
      if not (cursor_in_verified buf session) then
        (match Buffer.delete_selection buf with
         | Some _ -> () | None -> Buffer.delete_char_before buf);
      Some Continue
    end
    else if ch = 10 || ch = 13 || ch = Curses.Key.enter then begin
      if not (cursor_in_verified buf session) then begin
        ignore (Buffer.delete_selection buf);
        Buffer.insert_newline buf
      end;
      Some Continue
    end
    else if ch >= 32 && ch < 127 then begin
      if not (cursor_in_verified buf session) then begin
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
      match !focused_pane with
      | Goals ->
        (match handle_scroll goals_scroll (fun () -> Display.goals_win display) with
         | Some a -> a | None -> Continue)
      | Messages ->
        (match handle_scroll messages_scroll (fun () -> Display.messages_win display) with
         | Some a -> a | None -> Continue)
      | Script ->
        (match handle_script () with
         | Some a -> a | None -> Continue)
  in
  render_all display buf session;
  action
