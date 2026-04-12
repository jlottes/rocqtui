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

(* Apply a chgat to a byte range within a line, adjusting for hscroll *)
let chgat_byte_range r pane line row hscroll cols byte_start byte_end grid_attr =
  let scol = Utf8.byte_to_col line byte_start - hscroll in
  let ecol = Utf8.byte_to_col line byte_end - hscroll in
  let scol = max 0 scol in
  let ecol = min cols ecol in
  let w = ecol - scol in
  if w > 0 && scol < cols then
    Render.chgat r pane ~row ~col:scol ~width:w grid_attr

(* Apply sentence status coloring with syntax colors preserved *)
let render_sentence_regions r buf session spans =
  match session with
  | None -> ()
  | Some sess ->
    let ranges = Session.sentence_ranges sess in
    if ranges = [] then ()
    else begin
      let (rows, cols) = Render.pane_dims r Render.PScript in
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
            chgat_byte_range r Render.PScript line row hscroll cols s e default_attr;
            (* Re-apply syntax spans with status-colored background *)
            if i < Array.length spans then
              List.iter (fun (span : Highlight.span) ->
                let sb = line_start + span.start_col in
                let se = sb + span.length in
                if se > sd.sd_start && sb < sd.sd_end then begin
                  let cs = max s span.start_col in
                  let ce = min e (span.start_col + span.length) in
                  if ce > cs then
                    chgat_byte_range r Render.PScript line row hscroll cols cs ce
                      (attr_fn span)
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
let render_text_pane ?(sel : Tab.pane_selection option) ?set_cache
    r pane scroll_ref lines_list =
  Render.clear_pane r pane;
  let (rows, cols) = Render.pane_dims r pane in
  let wrapped = wrap_lines cols lines_list in
  (match set_cache with Some f -> f wrapped | None -> ());
  let n = List.length wrapped in
  scroll_ref := max 0 (min !scroll_ref (max 0 (n - rows)));
  List.iteri (fun i line ->
    let row = i - !scroll_ref in
    if row >= 0 && row < rows then
      ignore (Render.put_str r pane ~row ~col:1 line (Theme.attrs ()).ga_default)
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
         let line = List.nth wrapped i in
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

let render_goals (ctx : Editor_context.t) r (tab : Tab.t) =
  let session = tab.session in
  let lines = match session with
    | None ->
      let msg = if ctx.init_error <> "" then ctx.init_error
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
    r Render.PGoals gs lines;
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
  (* Don't auto-switch away from a terminal sub-tab *)
  let active_is_terminal =
    let mt = Tab.active_msg_tab tab.msg in
    mt.mt_terminal <> None
  in
  (* Auto-activate Rocq tab if content changed *)
  if rocq_lines <> rocq.mt_lines && rocq_lines <> [] then begin
    rocq.mt_lines <- rocq_lines;
    if not active_is_terminal then
      Tab.activate_msg_tab tab.msg "Rocq"
  end else
    rocq.mt_lines <- rocq_lines;
  (* Update Build tab *)
  let build_lines = Build.output () in
  if build_lines <> [] || Build.is_running () then begin
    let build = Tab.ensure_msg_tab tab.msg "Build" in
    if build_lines <> build.mt_lines then begin
      build.mt_lines <- build_lines;
      if Build.is_running () && not active_is_terminal then
        Tab.activate_msg_tab tab.msg "Build"
    end
  end

let render_messages r (tab : Tab.t) =
  update_msg_tabs tab;
  Tab.sync_terminals tab.msg;
  (* Resize all terminals to current messages pane dims. No-op if
     unchanged, so safe to call every frame. *)
  let mrect = Render.pane_rect r Render.PMessages in
  List.iter (fun t -> Terminal.resize t ~w:mrect.width ~h:mrect.height)
    (Terminal.all ());
  let mt = Tab.active_msg_tab tab.msg in
  match mt.mt_terminal with
  | Some term ->
    let rect = Render.pane_rect r Render.PMessages in
    Terminal.render term (Render.curr r) ~row:rect.row ~col:rect.col
      ~width:rect.width ~height:rect.height
  | None ->
    let ms = ref mt.mt_scroll in
    render_text_pane ~sel:mt.mt_sel
      ~set_cache:(fun l -> mt.mt_lines_cache <- l)
      r Render.PMessages ms mt.mt_lines;
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
  if tab.suppress_ensure_visible || ctx.dragging = Editor_context.DragMinimapScroll then
    tab.suppress_ensure_visible <- false
  else
    Buffer.ensure_visible_h buf rows cols;
  let scroll = Buffer.scroll_top buf in
  let hscroll = Buffer.hscroll buf in
  Render.clear_pane r Render.PScript;
  let spans = Highlight.highlight_buffer buf in
  let default_attr = (Theme.attrs ()).ga_default in
  for row = 0 to rows - 1 do
    let line_idx = scroll + row in
    if line_idx < Buffer.line_count buf then begin
      let line = Buffer.get_line buf line_idx in
      let (visible, _vstart_byte) = visible_portion line hscroll cols in
      ignore (Render.put_str r Render.PScript ~row ~col:0 visible default_attr);
      (* Apply highlighting -- adjust for horizontal scroll *)
      if line_idx < Array.length spans then
        List.iter (fun (span : Highlight.span) ->
          let scol = Utf8.byte_to_col line span.start_col - hscroll in
          let ecol = Utf8.byte_to_col line (span.start_col + span.length) - hscroll in
          let scol = max 0 scol in
          let ecol = min cols ecol in
          let width = ecol - scol in
          if scol < cols && width > 0 then
            Render.chgat r Render.PScript ~row ~col:scol ~width span.grid_attr
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
           chgat_byte_range r Render.PScript line row hscroll cols s e
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
        chgat_byte_range r Render.PScript line row hscroll cols s e grid_attr
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
    let cursor_col = min (Utf8.byte_to_col line cc - hscroll) (cols - 1) in
    let cursor_col = max 0 cursor_col in
    Render.place_cursor r ~row:(script_rect.row + cursor_row)
      ~col:(script_rect.col + cursor_col)
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
  Render.set_status r (String.concat "  " parts ^ "  F3:close")

let render_build_bar r =
  let running = Build.is_running () in
  let text = if running then
    let desc = match Build.description () with
      | Some d -> d | None -> "building" in
    Printf.sprintf "  Building: %s  [c]Cancel" desc
  else
    Printf.sprintf "[%s]File [%s]Deps [%s]All [%s]Cursor [%s]Clean [%s]Term [%s]Claude  %s:close"
      Keys.build_file.display Keys.build_deps.display Keys.build_all.display
      Keys.build_cursor.display Keys.build_clean.display
      Keys.build_terminal.display Keys.build_claude.display
      Keys.build_menu.display
  in
  Render.set_status r text

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
        Printf.sprintf "  [Messages] %s:Pane %s:Query %s:Help%s"
          Keys.cycle_pane.display Keys.query_menu.display
          Keys.help.display reload_hint
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
    let status = Printf.sprintf "%s%s  Ln %d, Col %d%s%s%s%s"
      fname mod_flag (cl + 1) (vcol + 1) rocq_status extra hscroll_ind focus_info
    in
    Render.set_status r status
  end

let render_all (ctx : Editor_context.t) r (tab : Tab.t) =
  (* Clear content panes — not the tab bar or other UI chrome *)
  Render.clear_pane r Render.PScript;
  Render.clear_pane r Render.PGoals;
  Render.clear_pane r Render.PMessages;
  Render.clear_pane r Render.PStatus;
  if Render.minimap_width r > 0 then
    Render.clear_pane r Render.PMinimap;
  let msg_tab_names = List.map Tab.msg_tab_display_name tab.msg.mt_tabs in
  Render.draw_chrome r
    ~goals_focused:(tab.focused_pane = `Goals)
    ~messages_focused:(tab.focused_pane = `Messages)
    ~msg_tab_names
    ~msg_tab_active:tab.msg.mt_active
    ();
  render_script ctx r tab;
  render_goals ctx r tab;
  render_messages r tab;
  update_status ctx r tab;
  (* Cursor visibility and positioning *)
  let active_mt = Tab.active_msg_tab tab.msg in
  let term_focused = tab.focused_pane = `Messages
    && active_mt.mt_terminal <> None in
  let cursor_visible =
    if term_focused then begin
      (* Position hardware cursor at vterm cursor location, if visible *)
      match active_mt.mt_terminal with
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
