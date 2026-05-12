(* View: rendering functions extracted from Editor. *)

(* Modal helpers — access ctx.modal *)
let is_help ctx = Modal.is_open ctx.Editor_context.modal (Modal.Help { scroll = 0 })
let is_options ctx = Modal.is_open ctx.Editor_context.modal Modal.OptionsMenu
let is_query ctx = Modal.is_open ctx.Editor_context.modal Modal.QueryMenu
let is_theme ctx = Modal.is_open ctx.Editor_context.modal Modal.ThemeMenu
let is_build ctx = Modal.is_open ctx.Editor_context.modal Modal.BuildMenu
let get_picker ctx = Modal.get_file_picker ctx.Editor_context.modal

let get_help_scroll ctx = match Modal.top ctx.Editor_context.modal with
  | Some (Modal.Help { scroll }) -> scroll
  | _ -> 0

let set_help_scroll ctx v = match Modal.top ctx.Editor_context.modal with
  | Some (Modal.Help h) -> h.scroll <- v
  | _ -> ()

(* Pane selection helpers *)
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
      let line = (List.nth lines i : Styled.line).text in
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

(* Format a key code as a readable character *)
let key_to_string k =
  if k = 27 then "\xe2\x90\x9b"  (* Compose/Escape *)
  else if k >= 32 && k < 127 then String.make 1 (Char.chr k)
  else Printf.sprintf "<%d>" k

let format_compose_status r cs =
  let pressed = Compose.keys_so_far cs in
  let completions = Compose.completions cs in
  let (_, status_cols) = Render.pane_dims r Render.PStatus in
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
        Stdlib.Buffer.add_string buf " \xe2\x80\xa6";
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

(* Width of the script-pane gutter (line numbers + reserved marker
   column) for a given buffer. Returns 0 when disabled. *)
let gutter_width buf =
  if not !Config.show_line_numbers then 0
  else begin
    let n = max 1 (Buffer.line_count buf) in
    let rec count k = if k = 0 then 0 else 1 + count (k / 10) in
    let digits = max 1 (count n) in
    1 + max 4 digits + 1
  end

(* UTF-8 superscript digits ⁰¹²³⁴⁵⁶⁷⁸⁹ for line numbers. *)
let superscript_digits =
  [| "\xe2\x81\xb0"; "\xc2\xb9"; "\xc2\xb2"; "\xc2\xb3";
     "\xe2\x81\xb4"; "\xe2\x81\xb5"; "\xe2\x81\xb6";
     "\xe2\x81\xb7"; "\xe2\x81\xb8"; "\xe2\x81\xb9" |]

let superscript_of_int n =
  let buf = Stdlib.Buffer.create 8 in
  let rec emit k =
    if k >= 10 then emit (k / 10);
    Stdlib.Buffer.add_string buf superscript_digits.(k mod 10)
  in
  emit (max 0 n);
  Stdlib.Buffer.contents buf

(* Apply a chgat to a byte range within a line, adjusting for hscroll
   and the gutter offset. [content_cols] is the visible content width
   (pane cols minus gutter). [col_offset] is added to the resulting
   column when emitting (typically the gutter width). *)
let chgat_byte_range r pane line row hscroll content_cols col_offset
    byte_start byte_end grid_attr =
  let scol = Utf8.byte_to_col line byte_start - hscroll in
  let ecol = Utf8.byte_to_col line byte_end - hscroll in
  let scol = max 0 scol in
  let ecol = min content_cols ecol in
  let w = ecol - scol in
  if w > 0 && scol < content_cols then
    Render.chgat r pane ~row ~col:(col_offset + scol) ~width:w grid_attr

(* Apply sentence status coloring with syntax colors preserved *)
let render_sentence_regions r buf session spans =
  match session with
  | None -> ()
  | Some sess ->
    let ranges = Session.sentence_ranges sess in
    if ranges = [] then ()
    else begin
      let (rows, cols) = Render.pane_dims r Render.PScript in
      let gw = gutter_width buf in
      let content_cols = max 0 (cols - gw) in
      let scroll = Buffer.scroll_top buf in
      let hscroll = Buffer.hscroll buf in
      let a = Theme.attrs () in
      List.iter (fun (sd : Session.sentence_display) ->
        let default_attr, attr_fn = match sd.sd_status with
          | Session.Verified ->
            (a.ga_default_v, fun (span : Highlight.span) ->
              let ga = span.grid_attr in
              { ga with bg = a.ga_verified.bg })
          | Session.Processing ->
            (a.ga_default_p, fun (span : Highlight.span) ->
              let ga = span.grid_attr in
              { ga with bg = a.ga_processing.bg })
          | Session.Error _ ->
            (a.ga_error, fun _span -> a.ga_error)
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
            chgat_byte_range r Render.PScript line row hscroll content_cols gw s e default_attr;
            (* Re-apply syntax spans with status-colored background *)
            if i < Array.length spans then
              List.iter (fun (span : Highlight.span) ->
                let sb = line_start + span.start_col in
                let se = sb + span.length in
                if se > sd.sd_start && sb < sd.sd_end then begin
                  let cs = max s span.start_col in
                  let ce = min e (span.start_col + span.length) in
                  if ce > cs then
                    chgat_byte_range r Render.PScript line row hscroll content_cols gw cs ce
                      (attr_fn span)
                end
              ) spans.(i)
          end;
          byte_off := line_end + 1
        done
      ) ranges
    end

(* Wrap lines to fit a given width, returning a flat list of screen lines *)
(* Render a scrollable text pane with optional selection highlight *)
let render_text_pane ?(sel : Tab.pane_selection option) ?set_cache
    ?(hanging=0) r pane scroll_ref lines_list =
  Render.clear_pane r pane;
  let (rows, cols) = Render.pane_dims r pane in
  let wrapped = Styled.wrap ~hanging cols lines_list in
  (match set_cache with Some f -> f wrapped | None -> ());
  let n = List.length wrapped in
  scroll_ref := max 0 (min !scroll_ref (max 0 (n - rows)));
  let default_attr = (Theme.attrs ()).ga_default in
  List.iteri (fun i (line : Styled.line) ->
    let row = i - !scroll_ref in
    if row >= 0 && row < rows then begin
      ignore (Render.put_str r pane ~row ~col:1 line.text default_attr);
      (* Apply spans (in list order, so later spans overlay earlier). *)
      List.iter (fun (sp : Styled.span) ->
        let s_col = Utf8.byte_to_col line.text sp.start + 1 in
        let e_col = Utf8.byte_to_col line.text (sp.start + sp.len) + 1 in
        let s_col = max 1 s_col in
        let e_col = min cols e_col in
        let w = e_col - s_col in
        if w > 0 then
          Render.chgat r pane ~row ~col:s_col ~width:w sp.attr
      ) line.spans
    end
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
     let selection_attr = (Theme.attrs ()).ga_selection in
     for i = sl to min el (n - 1) do
       let row = i - scroll in
       if row >= 0 && row < rows then begin
         let line = (List.nth wrapped i).text in
         let len = String.length line in
         let s = if i = sl then min sc len else 0 in
         let e = if i = el then min ec len else len in
         let s_col = Utf8.byte_to_col line s + 1 in (* +1 for margin *)
         let e_col = Utf8.byte_to_col line e + 1 in
         let w = e_col - s_col in
         if w > 0 && s_col < cols then
           Render.chgat r pane ~row ~col:s_col ~width:(min w (cols - s_col))
             selection_attr
       end
     done
   | _ -> ())

(* Pp pretty-printing target width for a pane. Subtracts the two-space
   indent that format_goals prefixes onto the rendered hyps/goals so
   the output fits within the visible width. Lower bound at 20 keeps
   formatting sane even in tiny panes. *)
let pp_width_for_pane r pane =
  let rect = Render.pane_rect r pane in
  max 20 (rect.Render.width - 2)

let render_goals (ctx : Editor_context.t) r (tab : Tab.t) =
  let session = tab.session in
  let lines : Styled.line list = match session with
    | None ->
      let msg = if ctx.init_error <> "" then ctx.init_error
                else "No Rocq session." in
      Styled.of_strings (String.split_on_char '\n' msg)
    | Some sess ->
      let width = pp_width_for_pane r Render.PGoals in
      match Session.goals_text ~all_hyps:tab.show_all_hyps ~width sess with
      | None -> [Styled.plain "No proof in progress."]
      | Some text -> Styled.of_strings (String.split_on_char '\n' text)
  in
  let gs = ref tab.goals_scroll in
  render_text_pane ~sel:tab.goals_sel
    ~set_cache:(fun l -> tab.goals_lines_cache <- l)
    r Render.PGoals gs lines;
  tab.goals_scroll <- !gs

(* Tracks the last-rendered active index so we only auto-scroll the
   Errors tab when the cursor actually changes (F9 or click), not on
   every frame. *)
let errors_last_active : int option ref = ref None

(* Sync the global Msg_pane sub-tab list with current global state.
   Purely passive — never changes which sub-tab is active. Auto-switch
   is handled at action-handler call sites. *)
let update_msg_tabs r (tab : Tab.t) =
  (* Rocq tab is always present. Its content (and scroll/sel) is
     pulled at render time from the active file. *)
  ignore (Msg_pane.ensure Msg_pane.Rocq);
  let _ = r in
  (* Build tab: ensured when there is build output or a running build. *)
  let build_output = Build.output () in
  let build_lines = Styled.of_strings build_output in
  if build_lines <> [] || Build.is_running () then begin
    let bt = Msg_pane.ensure Msg_pane.Build in
    if build_lines <> bt.lines then bt.lines <- build_lines
  end;
  (* Errors tab: ensure when entries exist; remove when empty. *)
  let project_dir = match Build.project_dir () with
    | Some d -> d
    | None -> Sys.getcwd () in
  let entries = Build_errors.all () in
  if entries = [] then begin
    if !errors_last_active <> None then errors_last_active := None;
    Msg_pane.remove Msg_pane.Errors
  end else begin
    let et = Msg_pane.ensure Msg_pane.Errors in
    let (lines, active_row) = Build_errors.render_errors_tab ~project_dir in
    if lines <> et.lines then et.lines <- lines;
    let cur = Build_errors.current_index () in
    if cur <> !errors_last_active && cur <> None then begin
      errors_last_active := cur;
      match active_row with
      | None -> ()
      | Some ar ->
        let (rows, _) = Render.pane_dims r Render.PMessages in
        let scroll = et.scroll in
        if ar < scroll then et.scroll <- ar
        else if ar >= scroll + rows then
          et.scroll <- max 0 (ar - rows + 1)
    end else if cur = None then
      errors_last_active := None
  end;
  ignore tab

let render_messages r (tab : Tab.t) =
  update_msg_tabs r tab;
  Msg_pane.sync_terminals ();
  (* Resize all terminals to current messages pane dims. No-op if
     unchanged, so safe to call every frame. *)
  let mrect = Render.pane_rect r Render.PMessages in
  List.iter (fun t -> Terminal.resize t ~w:mrect.width ~h:mrect.height)
    (Terminal.all ());
  let active = Msg_pane.active_tab () in
  match active.kind with
  | Msg_pane.Terminal term ->
    let rect = Render.pane_rect r Render.PMessages in
    Terminal.render term (Render.curr r) ~row:rect.row ~col:rect.col
      ~width:rect.width ~height:rect.height
  | Msg_pane.Rocq ->
    (* Per-file content: pull lines from active session each frame.
       Scroll/sel/cache live on tab.rocq_msg. *)
    let lines : Styled.line list = match tab.session with
      | None -> []
      | Some sess ->
        let width = pp_width_for_pane r Render.PMessages in
        List.concat_map (fun msg ->
          List.map Styled.plain (String.split_on_char '\n' msg)
        ) (Session.messages ~width sess)
    in
    let ms = ref tab.rocq_msg.rms_scroll in
    render_text_pane ~sel:tab.rocq_msg.rms_sel
      ~set_cache:(fun l -> tab.rocq_msg.rms_lines_cache <- l)
      r Render.PMessages ms lines;
    tab.rocq_msg.rms_scroll <- !ms
  | Msg_pane.Build | Msg_pane.Errors ->
    let ms = ref active.scroll in
    let hanging = match active.kind with Msg_pane.Errors -> 6 | _ -> 0 in
    render_text_pane ~sel:active.sel
      ~set_cache:(fun l -> active.lines_cache <- l)
      ~hanging
      r Render.PMessages ms active.lines;
    active.scroll <- !ms

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

let render_help_screen (ctx : Editor_context.t) r =
  let (rows, _cols) = Render.pane_dims r Render.PScript in
  Render.clear_pane r Render.PScript;
  let n = List.length help_lines in
  let scroll = get_help_scroll ctx in
  for row = 0 to rows - 1 do
    let idx = scroll + row in
    if idx < n then begin
      let line = List.nth help_lines idx in
      ignore (Render.put_str r Render.PScript ~row ~col:0 line (Theme.attrs ()).ga_default)
    end
  done

let render_script (ctx : Editor_context.t) r (tab : Tab.t) =
  let buf = tab.buf in
  let session = tab.session in
  if is_help ctx then
    render_help_screen ctx r
  else begin
  let (rows, cols) = Render.pane_dims r Render.PScript in
  let gw = gutter_width buf in
  let content_cols = max 1 (cols - gw) in
  let cur = Buffer.cursor buf in
  if tab.last_ensured_cur <> Some cur then begin
    Buffer.ensure_visible_h buf rows content_cols;
    tab.last_ensured_cur <- Some cur
  end;
  let scroll = Buffer.scroll_top buf in
  let hscroll = Buffer.hscroll buf in
  Render.clear_pane r Render.PScript;
  let spans = Highlight.highlight_buffer buf in
  let a_attrs = Theme.attrs () in
  let default_attr = a_attrs.ga_default in
  let gutter_attr = a_attrs.ga_gutter in
  let line_count = Buffer.line_count buf in
  let buf_filename = Buffer.filename buf in
  for row = 0 to rows - 1 do
    let line_idx = scroll + row in
    (* Paint the gutter area (always — including past EOF) *)
    if gw > 0 then begin
      Render.fill r Render.PScript ~row ~col:0 ~width:gw ' ' gutter_attr;
      if line_idx < line_count then begin
        let line_no = line_idx + 1 in
        let n_digits = String.length (string_of_int line_no) in
        let digit_col = gw - 1 - n_digits in
        let digits = superscript_of_int line_no in
        ignore (Render.put_str r Render.PScript ~row ~col:digit_col
                  digits gutter_attr);
        (* Build-error marker in column 0 *)
        (match buf_filename with
         | None -> ()
         | Some f ->
           match Build_errors.severity_for_line ~file:f ~line:line_no with
           | None -> ()
           | Some sev ->
             let glyph, attr = match sev with
               | Build_errors.Error -> "\xe2\x9c\x98", a_attrs.ga_marker_error
               | Build_errors.Warning -> "\xe2\x9a\xa0", a_attrs.ga_marker_warning
             in
             ignore (Render.put_str r Render.PScript ~row ~col:0 glyph attr))
      end
    end;
    if line_idx < line_count then begin
      let line = Buffer.get_line buf line_idx in
      let (visible, _vstart_byte) = visible_portion line hscroll content_cols in
      ignore (Render.put_str r Render.PScript ~row ~col:gw visible default_attr);
      (* Apply highlighting -- adjust for horizontal scroll *)
      if line_idx < Array.length spans then
        List.iter (fun (span : Highlight.span) ->
          let scol = Utf8.byte_to_col line span.start_col - hscroll in
          let ecol = Utf8.byte_to_col line (span.start_col + span.length) - hscroll in
          let scol = max 0 scol in
          let ecol = min content_cols ecol in
          let width = ecol - scol in
          if scol < content_cols && width > 0 then
            Render.chgat r Render.PScript ~row ~col:(gw + scol) ~width span.grid_attr
        ) spans.(line_idx)
    end
  done;
  render_sentence_regions r buf session spans;
  (* Overlay pending region (go_to_cursor target) *)
  let a = Theme.attrs () in
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
           chgat_byte_range r Render.PScript line row hscroll content_cols gw s e
             a.ga_default_p
         end;
         byte_off := line_end + 1
       done
     end
   | None -> ());
  (* Helper to iterate over byte ranges that overlap a region *)
  let overlay_range range_start range_end grid_attr =
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
        chgat_byte_range r Render.PScript line row hscroll content_cols gw s e grid_attr
      end;
      byte_off := line_end + 1
    done
  in
  (* Overlay explicit error range *)
  (match session with
   | Some sess ->
     (match Session.error_range sess with
      | Some (err_start, err_end) ->
        overlay_range err_start err_end a.ga_error
      | None -> ())
   | None -> ());
  (* Overlay selection highlight *)
  (match Buffer.selection buf with
   | Some (sel_start, sel_end) ->
     overlay_range sel_start sel_end a.ga_selection
   | None -> ());
  (* Overlay search matches: all matches with the subtle attr first,
     then the current match on top with the high-contrast attr. *)
  (match Tab.search_state tab with
   | Some s when Array.length s.matches > 0 ->
     let overlay_match (m : Search.match_) attr =
       let row = m.start_.line - scroll in
       if row >= 0 && row < rows
          && m.start_.line = m.end_.line
          && m.start_.line < Buffer.line_count buf then
         chgat_byte_range r Render.PScript
           (Buffer.get_line buf m.start_.line)
           row hscroll content_cols gw m.start_.col m.end_.col attr
     in
     Array.iter (fun m -> overlay_match m a.ga_search_match) s.matches;
     (match Search.current_match s with
      | Some m -> overlay_match m a.ga_search_current
      | None -> ())
   | _ -> ());
  (* Minimap -- render into the minimap pane *)
  if Render.minimap_width r > 0 then begin
    let mm_rect = Render.pane_rect r Render.PMinimap in
    let lines = Array.init (Buffer.line_count buf) (Buffer.get_line buf) in
    let num_lines = Array.length lines in
    let mm_rows_avail = mm_rect.height in
    let mm_braille_cols = mm_rect.width - 1 in  (* -1 for separator column *)
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
    let border_attr = a.ga_border in
    Minimap.draw (Render.curr r) ~base_row:mm_rect.row ~base_col:mm_rect.col
      ~sep_col:0 ~col_offset:1 ~win_rows:mm_rows_avail
      ~minimap_rows:(Array.length mm_data)
      ~scroll ~visible_lines:rows ~ypc ~border_attr mm_data
  end;
  let (cl, cc) = Buffer.cursor buf in
  let cursor_row = cl - scroll in
  let script_rect = Render.pane_rect r Render.PScript in
  if cursor_row >= 0 && cursor_row < rows then begin
    let line = Buffer.get_line buf cl in
    let cursor_col = min (Utf8.byte_to_col line cc - hscroll) (content_cols - 1) in
    let cursor_col = max 0 cursor_col in
    Render.place_cursor r ~row:(script_rect.row + cursor_row)
      ~col:(script_rect.col + gw + cursor_col)
  end else
    Render.place_cursor r ~row:script_rect.row ~col:script_rect.col
  end (* if not in_help_mode *)

let render_query_bar r =
  let text = Printf.sprintf "[%s]About [%s]Check [%s]Print [%s]Coercions [%s]Locate [%s]Show Proof [%s]Existentials  %s:close"
    Keys.query_about.display Keys.query_check.display Keys.query_print.display
    Keys.query_coercions.display Keys.query_locate.display Keys.query_proof.display
    Keys.query_existentials.display Keys.query_menu.display in
  Render.set_status r text

let render_theme_bar (ctx : Editor_context.t) r =
  let parts = List.mapi (fun i name ->
    let key = Char.chr (Char.code '1' + i) in
    let marker = if name = ctx.theme_name then "*" else "" in
    Printf.sprintf "[%c]%s%s" key name marker
  ) Theme.available in
  Render.set_status r (String.concat "  " parts ^ "  " ^ Keys.theme_menu.display ^ ":close")

let render_build_bar r =
  let running = Build.is_running () in
  let text = if running then
    let desc = match Build.description () with
      | Some d -> d | None -> "building" in
    Printf.sprintf "  Building: %s  [c]Cancel" desc
  else
    Printf.sprintf "[%s]File [%s]Deps [%s]All [%s]Cursor [%s]Clean  %s:close"
      Keys.build_file.display Keys.build_deps.display Keys.build_all.display
      Keys.build_cursor.display Keys.build_clean.display
      Keys.build_menu.display
  in
  Render.set_status r text

let render_search_bar (ctx : Editor_context.t) (tab : Tab.t) r =
  let s = Tab.search_state tab in
  let query, count, idx, case_insensitive, regex =
    match s with
    | None -> "", 0, 0, true, false
    | Some s ->
      s.query, Array.length s.matches,
      (if s.current >= 0 then s.current + 1 else 0),
      Search.is_case_insensitive ~query:s.query ~flags:s.flags,
      s.flags.regex
  in
  let counter =
    if count = 0 && query = "" then "       "  (* keep alignment *)
    else Printf.sprintf "  %d/%d" idx count
  in
  let case_ind = if case_insensitive then "[aa]" else "[Aa]" in
  let regex_ind = if regex then "[.*]" else "[..]" in
  let compose_ind =
    match ctx.compose with
    | Some cs when Compose.active cs ->
      let typed =
        String.concat "" (List.map key_to_string (Compose.keys_so_far cs))
      in
      if typed = "" then "  [c]"
      else Printf.sprintf "  [c: %s]" typed
    | _ -> ""
  in
  Render.set_status r
    (Printf.sprintf "Search: %s%s  %s %s  %s %s%s"
       query counter
       Keys.search_toggle_case.display case_ind
       Keys.search_toggle_regex.display regex_ind
       compose_ind)

let render_options_bar r =
  let parts = List.map (fun (e : Printopts.entry) ->
    if e.enabled then
      Printf.sprintf "[%c]%s*" e.key e.label
    else
      Printf.sprintf "[%c]%s" e.key e.label
  ) Printopts.entries in
  let text = String.concat " " parts in
  Render.set_status r text

let update_status (ctx : Editor_context.t) r (tab : Tab.t) =
  let buf = tab.buf in
  let session = tab.session in
  match Modal.top ctx.modal with
  | Some (Modal.Prompt p) ->
    Render.set_status r p.message
  | Some Modal.SearchPrompt ->
    render_search_bar ctx tab r
  | _ ->
  if is_help ctx then
    Render.set_status r "F1:close  Up/Down/PgUp/PgDn:scroll  any other key:close"
  else if is_build ctx then
    render_build_bar r
  else if is_theme ctx then
    render_theme_bar ctx r
  else if is_options ctx then
    render_options_bar r
  else if is_query ctx then
    render_query_bar r
  else match ctx.compose with
  | Some cs when Compose.active cs ->
    Render.set_status r (format_compose_status r cs)
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
        (match Msg_pane.active_kind () with
         | Msg_pane.Terminal term ->
           let vt = Terminal.vterm term in
           let scroll_info = match Vterm_lib.Vterm_api.scroll_info vt with
             | Some s -> " [" ^ s ^ "]"
             | None -> "" in
           Printf.sprintf "  %s%s  %s:editor %s:close"
             (Terminal.title term) scroll_info
             Keys.cycle_pane.display Keys.close_tab.display
         | _ ->
           Printf.sprintf "  [Messages] %s:Pane %s:Query %s:Help%s"
             Keys.cycle_pane.display Keys.query_menu.display
             Keys.help.display reload_hint)
    in
    (* Horizontal scroll indicator *)
    let hscroll_ind =
      let hs = Buffer.hscroll buf in
      if hs > 0 then
        let (_, cols) = Render.pane_dims r Render.PScript in
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
        Stdlib.Buffer.add_string b " \xe2\x97\x80";  (* triangle left *)
        for i = 0 to bar_len - 1 do
          if i >= thumb_start && i < thumb_start + thumb_len then
            Stdlib.Buffer.add_string b "\xe2\x96\x88"  (* full block *)
          else
            Stdlib.Buffer.add_string b "\xe2\x94\x80"  (* hor line *)
        done;
        Stdlib.Buffer.add_string b "\xe2\x96\xb6";  (* triangle right *)
        Stdlib.Buffer.contents b
      else ""
    in
    let extra = if ctx.status_extra <> "" then "  " ^ ctx.status_extra else "" in
    let search_info = match Tab.search_state tab with
      | None -> ""
      | Some s ->
        let count = Array.length s.matches in
        let idx = if s.current >= 0 then s.current + 1 else 0 in
        Printf.sprintf "  Search: %s %d/%d" s.query idx count
    in
    let status = Printf.sprintf "%s%s  Ln %d, Col %d%s%s%s%s%s"
      fname mod_flag (cl + 1) (vcol + 1) rocq_status search_info extra hscroll_ind focus_info
    in
    Render.set_status r status
  end

let render_all (ctx : Editor_context.t) r (tab : Tab.t) =
  (* Refresh parsed build errors before any pane renders so the script
     gutter sees the current set on the same frame the build output
     arrived. *)
  let project_dir = match Build.project_dir () with
    | Some d -> d
    | None -> Sys.getcwd () in
  Build_errors.refresh ~project_dir (Build.output ());
  (* Clear content panes — not the tab bar or other UI chrome *)
  Render.clear_pane r Render.PScript;
  Render.clear_pane r Render.PGoals;
  Render.clear_pane r Render.PMessages;
  Render.clear_pane r Render.PStatus;
  if Render.minimap_width r > 0 then
    Render.clear_pane r Render.PMinimap;
  let mp = Msg_pane.state () in
  let msg_tab_names = List.map Msg_pane.display_name mp.tabs in
  Render.draw_chrome r
    ~goals_focused:(tab.focused_pane = `Goals)
    ~messages_focused:(tab.focused_pane = `Messages)
    ~msg_tab_names
    ~msg_tab_active:mp.active
    ();
  render_script ctx r tab;
  render_goals ctx r tab;
  render_messages r tab;
  update_status ctx r tab;
  (* Cursor visibility and positioning *)
  let active_term = match Msg_pane.active_kind () with
    | Msg_pane.Terminal t -> Some t
    | _ -> None
  in
  let term_focused = tab.focused_pane = `Messages && active_term <> None in
  let cursor_visible =
    if term_focused then begin
      (* Position hardware cursor at vterm cursor location, if visible *)
      match active_term with
      | Some term ->
        let vt = Terminal.vterm term in
        let mode = Vterm_lib.Vterm_api.term_mode vt in
        let show_cursor = mode land 0x10 <> 0 in (* MODE_SHOW_CURSOR *)
        if show_cursor then
          match Vterm_lib.Vterm_api.cursor_info vt with
          | Some ci ->
            let rect = Render.pane_rect r Render.PMessages in
            Render.place_cursor r
              ~row:(rect.row + ci.y)
              ~col:(rect.col + ci.x);
            true
          | None -> false
        else false
      | None -> false
    end
    else if tab.focused_pane <> `Script then false
    else
      let (cl, _) = Buffer.cursor tab.buf in
      let scroll = Buffer.scroll_top tab.buf in
      let (rows, _) = Render.pane_dims r Render.PScript in
      cl >= scroll && cl < scroll + rows
  in
  let picker = get_picker ctx in
  let cursor_visible = cursor_visible && picker = None in
  Render.set_cursor_visible r cursor_visible;
  (match picker with
   | Some fp -> File_picker.render fp r
   | None -> Render.clear_overlay r)
