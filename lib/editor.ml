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


(* Clipboard -- shared across tabs *)
let clipboard = ref ""

(* Compose input method *)
let compose_state : Compose.t option ref = ref None

let init_compose () =
  compose_state := Some (Compose.load ())

(* Drag state for resizing pane borders -- global since it's display-level *)
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


(* Target position for jump-to-definition (consumed by main.ml after Open_file) *)
let jump_target : (int * int) option ref = ref None  (* (line, col) *)
let take_jump_target () =
  let v = !jump_target in
  jump_target := None;
  v


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

(* Theme/Build modes *)
let in_theme_mode = ref false
let in_build_mode = ref false


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

let render_messages r (tab : Tab.t) =
  update_msg_tabs tab;
  let mt = Tab.active_msg_tab tab.msg in
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

let render_help_screen r =
  let (rows, cols) = Render.pane_dims r Render.PScript in
  Render.clear_pane r Render.PScript;
  let n = List.length help_lines in
  let scroll = !help_scroll in
  for row = 0 to rows - 1 do
    let idx = scroll + row in
    if idx < n then begin
      let line = List.nth help_lines idx in
      let trunc = if String.length line > cols then String.sub line 0 cols
                  else line in
      ignore (Render.put_str r Render.PScript ~row ~col:0 trunc (Theme.attrs ()).ga_default)
    end
  done

let render_script _ctx r (tab : Tab.t) =
  let buf = tab.buf in
  let session = tab.session in
  if !in_help_mode then
    render_help_screen r
  else begin
  let (rows, cols) = Render.pane_dims r Render.PScript in
  if tab.suppress_ensure_visible || !dragging = DragMinimapScroll then
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

(* Check if cursor is in the verified region. *)
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
        Session.go_to_cursor sess
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
    Printf.sprintf "[%s]File [%s]Deps [%s]All [%s]Cursor [%s]Clean  %s:close"
      Keys.build_file.display Keys.build_deps.display Keys.build_all.display
      Keys.build_cursor.display Keys.build_clean.display Keys.build_menu.display
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
  if !in_help_mode then
    Render.set_status r "F1:close  Up/Down/PgUp/PgDn:scroll  any other key:close"
  else if !in_build_mode then
    render_build_bar r
  else if !in_theme_mode then
    render_theme_bar ctx r
  else if !in_options_mode then
    render_options_bar r
  else if !in_query_mode then
    render_query_bar r
  else match !compose_state with
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
  let msg_tab_names = List.map (fun (mt : Tab.msg_tab) -> mt.mt_name)
                        tab.msg.mt_tabs in
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
  (* Hide cursor when not in Script pane or when cursor is scrolled off-screen *)
  let cursor_visible =
    if tab.focused_pane <> `Script then false
    else
      let (cl, _) = Buffer.cursor tab.buf in
      let scroll = Buffer.scroll_top tab.buf in
      let (rows, _) = Render.pane_dims r Render.PScript in
      cl >= scroll && cl < scroll + rows
  in
  let picker_open = File_picker.is_open () in
  let cursor_visible = cursor_visible && not picker_open in
  Render.set_cursor_visible r cursor_visible;
  if picker_open then
    File_picker.render r

(* Convert screen coordinates to buffer (line, byte_col) position.
   Returns None if the coordinates are outside the script pane content. *)
let screen_to_buffer_pos r buf ~x ~y =
  let (rows, cols) = Render.pane_dims r Render.PScript in
  let scroll = Buffer.scroll_top buf in
  let hscroll = Buffer.hscroll buf in
  let script_rect = Render.pane_rect r Render.PScript in
  let row = y - script_rect.row in
  let col = x - script_rect.col in
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
let screen_to_pane_pos (tab : Tab.t) r ~x ~y pane_id =
  let pane = match pane_id with
    | `Goals -> Render.PGoals
    | `Messages -> Render.PMessages
  in
  let rect = Render.pane_rect r pane in
  let (rows, cols) = Render.pane_dims r pane in
  let row = y - rect.row in
  let col = x - rect.col - 1 in (* -1 for margin *)
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
      Some (line_idx, byte_col)
    end
  end

(* Select word at position in a pane's cached lines *)
let [@warning "-32"] pane_select_word (ps : Tab.pane_selection) lines_cache line_idx byte_col =
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

(* --- Input event handling --- *)

(* Helper: match an Input.event against a Keys.binding *)
let match_binding (ev : Input.event) (b : Keys.binding) =
  match ev with
  | Input.Key (cp, mods) ->
    (* Ctrl+letter: cp is the letter, mods.ctrl is true *)
    if mods.ctrl && not mods.alt && not mods.shift then begin
      let ctrl_code = if cp >= 97 && cp <= 122 then cp - 96
                      else if cp >= 65 && cp <= 90 then cp - 64
                      else -1 in
      if ctrl_code > 0 then List.mem ctrl_code b.codes
      else List.mem cp b.codes
    end
    else if not mods.ctrl && not mods.alt && not mods.shift then
      List.mem cp b.codes
    else
      (* Try kitty codes for modified keys *)
      let modifier = 1
        + (if mods.shift then 1 else 0)
        + (if mods.alt then 2 else 0)
        + (if mods.ctrl then 4 else 0) in
      List.exists (fun (kc, m) -> kc = cp && m = modifier) b.kitty_codes
  | Input.Special (key, mods) ->
    (* Map special keys to legacy codes for binding matching *)
    let modifier = 1
      + (if mods.shift then 1 else 0)
      + (if mods.alt then 2 else 0)
      + (if mods.ctrl then 4 else 0) in
    let base_code = match key with
      | Input.Up -> Some 259 | Input.Down -> Some 258
      | Input.Right -> Some 261 | Input.Left -> Some 260
      | Input.Home -> Some 262 | Input.End -> Some 360
      | Input.PageUp -> Some 339 | Input.PageDown -> Some 338
      | Input.Insert -> Some 331 | Input.Delete -> Some 330
      | Input.F n -> Some (264 + n)  (* F1=265, F2=266 etc. *)
      | Input.Backspace -> Some 127
      | Input.Tab -> Some 9
      | Input.Enter -> Some 13
      | Input.Escape -> None  (* Escape handled separately *)
    in
    (match base_code with
     | Some code ->
       if modifier = 1 then
         List.mem code b.codes
       else begin
         (* Modified special keys: try kitty_codes, then legacy shift/alt/ctrl codes *)
         let has_kitty = List.exists (fun (kc, m) ->
           kc = code && m = modifier) b.kitty_codes in
         if has_kitty then true
         else begin
           (* Map modified arrows to legacy ncurses codes *)
           let has_alt = mods.alt in
           let has_ctrl = mods.ctrl in
           let has_shift = mods.shift in
           (* Map modified arrows to ALL legacy ncurses code variants *)
           let mapped = match key with
             | Input.Up ->
               if has_alt then [564; 567; 573; 558]
               else if has_ctrl then [567; 573; 558]
               else if has_shift then [337] else []
             | Input.Down ->
               if has_alt then [523; 526; 532; 517]
               else if has_ctrl then [526; 532; 517]
               else if has_shift then [336] else []
             | Input.Right ->
               if has_alt then [558; 561] else if has_ctrl then [561]
               else if has_shift then [402] else []
             | Input.Left ->
               if has_alt then [543; 546; 552]
               else if has_ctrl then [546]
               else if has_shift then [393] else []
             | _ -> []
           in
           List.exists (fun c -> List.mem c b.codes) mapped
         end
       end
     | None -> false)
  | _ -> false

(* Extract codepoint from event for compose feeding *)
let codepoint_of_event = function
  | Input.Key (cp, _) -> Some cp
  | Input.Special (Input.Tab, _) -> Some 9
  | Input.Special (Input.Enter, _) -> Some 13
  | Input.Special (Input.Backspace, _) -> Some 127
  | _ -> None

let handle_event (ctx : Editor_context.t) (ev : Input.event) (tab : Tab.t) r =
  let buf = tab.buf in
  let session = tab.session in
  (* Handle compose mode first *)
  let compose_handled = match !compose_state with
    | Some cs when Compose.active cs ->
      (match codepoint_of_event ev with
       | Some cp ->
         let result = Compose.feed cs cp in
         (match result with
          | Compose.Pending ->
            Render.set_status r (format_compose_status r cs);
            Render.present r
          | Compose.Composed text ->
            ignore (Buffer.delete_selection buf);
            insert_string tab text
          | Compose.NoMatch ->
            (* If the key that broke compose was Escape, restart compose *)
            (match ev with
             | Input.Special (Input.Escape, _) ->
               Compose.start cs;
               Render.set_status r (format_compose_status r cs);
               Render.present r
             | _ -> ()));
         true
       | None ->
         (* Non-character event in compose mode -- feed 0 to abort *)
         ignore (Compose.feed cs 0);
         false)
    | _ -> false
  in
  if compose_handled then
    Continue
  else if File_picker.is_open () then begin
    let (_box_top, box_left, box_w, _box_h, visible_rows) =
      File_picker.box_geometry r in
    match ev with
    | Input.Mouse mev ->
      let b1_click = mev.button = Input.Left in
      let scroll_up = mev.button = Input.ScrollUp in
      let scroll_down = mev.button = Input.ScrollDown in
      if b1_click then begin
        let (box_top, _, _, _, _) = File_picker.box_geometry r in
        match File_picker.handle_click ~y:mev.y ~x:mev.x ~box_top ~box_left
                ~box_width:box_w ~visible_rows with
        | File_picker.PickerOpen path -> Open_file path
        | _ -> Continue
      end
      else if scroll_up then
        (File_picker.handle_scroll (-1) visible_rows; Continue)
      else if scroll_down then
        (File_picker.handle_scroll 1 visible_rows; Continue)
      else Continue
    | Input.Special (Input.Escape, _) ->
      File_picker.close (); Continue
    | Input.Key (cp, mods) ->
      let ch = if mods.ctrl && cp >= 97 && cp <= 122 then cp - 96 else cp in
      (match File_picker.handle_key ch visible_rows with
       | File_picker.PickerOpen path -> Open_file path
       | File_picker.PickerClose -> Continue
       | File_picker.PickerContinue -> Continue)
    | Input.Special (key, _mods) ->
      let ch = match key with
        | Input.Up -> 259 | Input.Down -> 258
        | Input.PageUp -> 339 | Input.PageDown -> 338
        | Input.Enter -> 13 | Input.Tab -> 9
        | Input.Backspace -> 127
        | _ -> 0
      in
      if ch <> 0 then
        (match File_picker.handle_key ch visible_rows with
         | File_picker.PickerOpen path -> Open_file path
         | File_picker.PickerClose -> Continue
         | File_picker.PickerContinue -> Continue)
      else Continue
    | _ -> Continue
  end
  else
  (* --- Global keys (work in any pane) --- *)
  let handle_global () =
    if match_binding ev Keys.quit then Some Quit
    else if match_binding ev Keys.close_tab then Some Close_tab
    else if match_binding ev Keys.save then Some Save_prompt
    else if match_binding ev Keys.jump_back then begin
      match pop_jump () with
      | Some jp ->
        jump_target := Some (jp.jp_line, jp.jp_col);
        Some (Jump_back jp)
      | None ->
        Render.set_status r "No previous location.";
        Some Continue
    end
    else if match_binding ev Keys.open_file then begin
      let filename = Buffer.filename buf in
      let dir = match filename with
        | Some f -> Filename.dirname f
        | None -> Sys.getcwd ()
      in
      (match Project.find_project_file dir with
       | Some (project_dir, project_file) ->
         File_picker.open_picker ~project_dir ~project_file
           ~open_files:(ctx.open_files ())
       | None ->
         Render.set_status r "No _RocqProject found.");
      Some Continue
    end
    else if match_binding ev Keys.interrupt then begin
      (match session with
       | Some s -> (try Unix.kill (Session.pid s) Sys.sigint with _ -> ())
       | None -> ());
      Some Continue
    end
    else if match_binding ev Keys.step_forward then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.step_forward s | None -> ());
      Some Continue
    end
    else if match_binding ev Keys.step_backward then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.step_backward s | None -> ());
      Some Continue
    end
    else if match_binding ev Keys.go_to_cursor then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.go_to_cursor s | None -> ());
      Some Continue
    end
    else if (match ev with Input.Special (Input.Escape, _) -> true | _ -> false) then begin
      if !in_build_mode then
        in_build_mode := false
      else if !in_theme_mode then
        in_theme_mode := false
      else if !in_options_mode then begin
        in_options_mode := false;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
      end else begin
        (* Plain Escape -- start compose *)
        match !compose_state with
        | Some cs ->
          Compose.start cs;
          Render.set_status r (format_compose_status r cs);
          Render.present r
        | None -> ()
      end;
      Some Continue
    end
    else if match_binding ev Keys.toggle_hyps then begin
      tab.show_all_hyps <- not tab.show_all_hyps; Some Continue end
    else if match_binding ev Keys.options_menu then begin
      if !in_options_mode then begin
        in_options_mode := false;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
      end else in_options_mode := true;
      Some Continue
    end
    else if !in_options_mode then begin
      let ch_opt = codepoint_of_event ev in
      match ch_opt with
      | Some ch ->
        let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
        (match List.find_opt (fun (e : Printopts.entry) -> e.key = c) Printopts.entries with
         | Some entry ->
           Printopts.toggle entry;
           (match session with Some s -> Session.sync_options_and_refresh s | None -> ());
           Some Continue
         | None ->
           in_options_mode := false;
           (match session with Some s -> Session.sync_options_and_refresh s | None -> ());
           None)
      | None ->
        in_options_mode := false;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ());
        None
    end
    else if match_binding ev Keys.reload then begin
      Some Reload
    end
    else if match_binding ev Keys.theme_menu then begin
      in_theme_mode := not !in_theme_mode;
      Some Continue
    end
    else if !in_theme_mode then begin
      in_theme_mode := false;
      (match codepoint_of_event ev with
       | Some ch ->
         let idx = ch - Char.code '1' in
         let themes = Theme.available in
         if idx >= 0 && idx < List.length themes then begin
           let name = List.nth themes idx in
           let theme = Theme.find name in
           Theme.apply theme;
           ctx.theme_name <- name
         end
       | None -> ());
      Some Continue
    end
    else if match_binding ev Keys.build_menu then begin
      in_build_mode := not !in_build_mode;
      Some Continue
    end
    else if !in_build_mode then begin
      in_build_mode := false;
      (match codepoint_of_event ev with
       | Some ch ->
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
              else Render.set_status r "Build already running."
            | _, None ->
              Render.set_status r "No project found."
            | None, _ ->
              Render.set_status r "No filename.");
           Some Continue
         end
         else if c = 'd' then begin
           (match Buffer.filename buf, project_info () with
            | Some f, Some pd ->
              if Build.build_deps ~project_dir:pd f then ()
              else Render.set_status r "Build already running."
            | _, None ->
              Render.set_status r "No project found."
            | None, _ ->
              Render.set_status r "No filename.");
           Some Continue
         end
         else if c = 'a' then begin
           (match project_info () with
            | Some pd ->
              if Build.build_all ~project_dir:pd then ()
              else Render.set_status r "Build already running."
            | None ->
              Render.set_status r "No project found.");
           Some Continue
         end
         else if c = 'x' then begin
           (match project_info () with
            | Some pd ->
              if Build.build_clean ~project_dir:pd then ()
              else Render.set_status r "Build already running."
            | None ->
              Render.set_status r "No project found.");
           Some Continue
         end
         else
           (Some Continue)
       | None -> Some Continue)
    end
    else if match_binding ev Keys.query_menu then begin
      in_query_mode := not !in_query_mode;
      Some Continue
    end
    else if !in_query_mode then begin
      in_query_mode := false;
      match codepoint_of_event ev with
      | Some ch ->
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
               let line_has s line =
                 let slen = String.length s in
                 let llen = String.length line in
                 let rec check i =
                   if i + slen > llen then false
                   else if String.sub line i slen = s then true
                   else check (i + 1)
                 in check 0
               in
               let matches_word line =
                 line_has (" " ^ word ^ " >->") line
                 || line_has (">-> " ^ word) line
                 || line_has ("." ^ word ^ " >->") line
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
      | None -> None
    end
    else if match_binding ev Keys.cycle_pane then begin
      tab.focused_pane <- (match tab.focused_pane with
        | `Script -> `Goals | `Goals -> `Messages | `Messages -> `Script);
      Some Continue
    end
    else if (match ev with Input.Resize -> true | _ -> false) then begin
      Render.resize r;
      Some Continue
    end
    else if !in_help_mode then begin
      let (rows, _) = Render.pane_dims r Render.PScript in
      let n = List.length help_lines in
      let max_scroll = max 0 (n - rows) in
      let scroll_by delta =
        help_scroll := max 0 (min max_scroll (!help_scroll + delta)) in
      (match ev with
       | Input.Special (Input.Up, _) ->
         scroll_by (-1); Some Continue
       | Input.Special (Input.Down, _) ->
         scroll_by 1; Some Continue
       | Input.Special (Input.PageUp, _) ->
         scroll_by (-rows); Some Continue
       | Input.Special (Input.PageDown, _) ->
         scroll_by rows; Some Continue
       | Input.Special (Input.Home, _) ->
         help_scroll := 0; Some Continue
       | Input.Special (Input.End, _) ->
         help_scroll := max_scroll; Some Continue
       | Input.Mouse mev ->
         if mev.button = Input.ScrollUp then scroll_by (-3)
         else if mev.button = Input.ScrollDown then scroll_by 3;
         Some Continue
       | _ ->
         in_help_mode := false;
         help_scroll := 0;
         Some Continue)
    end
    else if (match ev with Input.Mouse _ -> true | _ -> false) then begin
      let mev = match ev with Input.Mouse m -> m | _ -> assert false in
      let x = mev.x in
      let y = mev.y in
      let is_release = mev.button = Input.Release in
      let is_left = mev.button = Input.Left in
      let is_scroll_up = mev.button = Input.ScrollUp in
      let is_scroll_down = mev.button = Input.ScrollDown in
      let has_shift = mev.mods.shift in
      let has_cmd = mev.mods.ctrl in  (* Ctrl acts as Cmd on most terminals *)
      if !dragging <> NoDrag then begin
        (* Active border drag *)
        (match !dragging with
         | DragV -> Render.move_split_v r x
         | DragH -> Render.move_split_h r y
         | DragMinimap -> Render.move_minimap_border r x
         | DragMinimapScroll ->
           let mm_rect = Render.pane_rect r Render.PMinimap in
           let mm_row = y - mm_rect.row in
           if mm_row >= 0 && mm_row < mm_rect.height then begin
             let num_lines = Buffer.line_count buf in
             let ypc = Minimap.y_per_cell ~num_lines ~available_rows:mm_rect.height in
             let target_line = mm_row * ypc in
             let (srows, _) = Render.pane_dims r Render.PScript in
             let target_scroll = max 0 (target_line - srows / 2) in
             let max_scroll = max 0 (num_lines - srows) in
             Buffer.set_scroll_top buf (min target_scroll max_scroll);
             tab.suppress_ensure_visible <- true
           end
         | NoDrag -> ());
        if is_release then dragging := NoDrag
      end
      else if tab.mouse_selecting then begin
        (* Active text selection drag *)
        let pane = Render.pane_at r ~x ~y in
        if pane = Render.PScript then begin
          match screen_to_buffer_pos r buf ~x ~y with
          | Some (line, byte_col) -> Buffer.move_to buf line byte_col
          | None -> ()
        end else if pane = Render.PGoals || pane = Render.PMessages then begin
          let (ps, pane_id) =
            if pane = Render.PGoals then (tab.goals_sel, `Goals)
            else ((Tab.active_msg_tab tab.msg).mt_sel, `Messages)
          in
          (match screen_to_pane_pos tab r ~x ~y pane_id with
           | Some (row, byte_col) ->
             ps.ps_cursor_line <- row;
             ps.ps_cursor_col <- byte_col
           | None -> ())
        end;
        if is_release then begin
          tab.mouse_selecting <- false;
          (* If no actual drag occurred (anchor == cursor), clear selection *)
          if Buffer.selection buf = None then
            Buffer.clear_selection buf
        end
      end
      else begin
        let pane = Render.pane_at r ~x ~y in
        if is_scroll_up || is_scroll_down then begin
          let delta = if is_scroll_up then -3 else 3 in
          match pane with
          | Render.PScript ->
            let (rows, _) = Render.pane_dims r Render.PScript in
            let max_scroll = max 0 (Buffer.line_count buf - rows) in
            Buffer.set_scroll_top buf (max 0 (min max_scroll (Buffer.scroll_top buf + delta)));
            tab.suppress_ensure_visible <- true
          | Render.PGoals ->
            tab.goals_scroll <- max 0 (tab.goals_scroll + delta)
          | Render.PMessages ->
            (Tab.active_msg_tab tab.msg).mt_scroll <- max 0 ((Tab.active_msg_tab tab.msg).mt_scroll + delta)
          | _ -> ()
        end
        else if pane = Render.PTabBar && is_left then begin
          ctx.switch_tab x
        end
        else if pane = Render.PBorderH && is_left then begin
          let tab_names = List.map (fun (mt : Tab.msg_tab) -> mt.mt_name)
                            tab.msg.mt_tabs in
          match Render.msg_tab_at_x r ~x ~tab_names with
          | Some i ->
            tab.msg.mt_active <- i
          | None ->
            dragging := DragH
        end
        else if (pane = Render.PBorderV || pane = Render.PBorderMinimap)
                && is_left then
          dragging := (match pane with
            | Render.PBorderMinimap -> DragMinimap
            | _ -> DragV)
        else if (pane = Render.PGoals || pane = Render.PMessages)
                && is_left then begin
          tab.focused_pane <- (if pane = Render.PGoals then `Goals else `Messages);
          let (ps, lines_cache, _scroll_ref, pane_id) =
            if pane = Render.PGoals then
              (tab.goals_sel, tab.goals_lines_cache, tab.goals_scroll, `Goals)
            else
              ((Tab.active_msg_tab tab.msg).mt_sel, (Tab.active_msg_tab tab.msg).mt_lines_cache, (Tab.active_msg_tab tab.msg).mt_scroll, `Messages)
          in
          (* For now, treat all Left clicks as single click *)
          match screen_to_pane_pos tab r ~x ~y pane_id with
          | Some (row, byte_col) ->
            clear_pane_selection ps;
            ps.ps_anchor_line <- row;
            ps.ps_anchor_col <- byte_col;
            ps.ps_cursor_line <- row;
            ps.ps_cursor_col <- byte_col;
            ps.ps_active <- true;
            tab.mouse_selecting <- true;
            ignore lines_cache
          | None -> ()
        end
        else if pane = Render.PMinimap && is_left then begin
          let mm_rect = Render.pane_rect r Render.PMinimap in
          let mm_row = y - mm_rect.row in
          if mm_row >= 0 && mm_row < mm_rect.height then begin
            let num_lines = Buffer.line_count buf in
            let ypc = Minimap.y_per_cell ~num_lines ~available_rows:mm_rect.height in
            let target_line = mm_row * ypc in
            let (srows, _) = Render.pane_dims r Render.PScript in
            let target_scroll = max 0 (target_line - srows / 2) in
            let max_scroll = max 0 (num_lines - srows) in
            Buffer.set_scroll_top buf (min target_scroll max_scroll);
            tab.suppress_ensure_visible <- true
          end;
          dragging := DragMinimapScroll
        end
        else if pane = Render.PScript && is_left then begin
          tab.focused_pane <- `Script;
          clear_pane_selection tab.goals_sel;
          clear_pane_selection (Tab.active_msg_tab tab.msg).mt_sel;
          if has_cmd then begin
            match screen_to_buffer_pos r buf ~x ~y with
            | Some (line, byte_col) ->
              Buffer.move_to buf line byte_col;
              (match session with
               | Some s -> Session.go_to_cursor s
               | None -> ())
            | None -> ()
          end
          else if has_shift then begin
            match screen_to_buffer_pos r buf ~x ~y with
            | Some (line, byte_col) ->
              if Buffer.selection buf = None then Buffer.set_anchor buf;
              Buffer.move_to buf line byte_col
            | None -> ()
          end
          else begin
            (* Click — position cursor; set anchor for potential drag *)
            match screen_to_buffer_pos r buf ~x ~y with
            | Some (line, byte_col) ->
              Buffer.clear_selection buf;
              Buffer.move_to buf line byte_col;
              (* Anchor is set for drag, but cleared on release if no drag occurred *)
              Buffer.set_anchor buf;
              tab.mouse_selecting <- true
            | None -> ()
          end
        end
      end;
      Some Continue
    end
    (* Paste event *)
    else if (match ev with Input.Paste _ -> true | _ -> false) then begin
      let text = match ev with Input.Paste t -> t | _ -> "" in
      if text <> "" && not (cursor_in_target tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        ignore (Buffer.delete_selection buf);
        insert_string tab text;
        clipboard := text
      end;
      Some Continue
    end
    else if match_binding ev Keys.jump_to_def then begin
      let (cl, cc) = Buffer.cursor buf in
      let line = Buffer.get_line buf cl in
      (* Try Require line first *)
      let result = match Locate.parse_require_line line with
        | Some (_, modules) ->
          let modname = Locate.module_at_col modules cc in
          (match modname, session with
           | Some m, Some s ->
             Session.query s ("Locate Library " ^ m ^ ".");
             let msgs = String.concat "\n" (Session.messages s) in
             (match Locate.parse_locate_library msgs with
              | Some vo_path ->
                let v_path = Locate.vo_to_v vo_path in
                if Sys.file_exists v_path then Some (v_path, None)
                else begin
                  Render.set_status r ("Source not found: " ^ v_path);
                  None
                end
              | None ->
                let dir = match Buffer.filename buf with
                  | Some f -> Filename.dirname f | None -> Sys.getcwd () in
                (match Project.find_project_file dir with
                 | Some (_, pf) ->
                   let lps = Project.load_paths pf in
                   (match Project.resolve_module lps m with
                    | Some path -> Some (path, None)
                    | None ->
                      Render.set_status r ("Module not found: " ^ m);
                      None)
                 | None ->
                   Render.set_status r ("Module not found: " ^ m);
                   None))
           | Some m, None ->
             let dir = match Buffer.filename buf with
               | Some f -> Filename.dirname f | None -> Sys.getcwd () in
             (match Project.find_project_file dir with
              | Some (_, pf) ->
                let lps = Project.load_paths pf in
                (match Project.resolve_module lps m with
                 | Some path -> Some (path, None)
                 | None ->
                   Render.set_status r ("Module not found: " ^ m);
                   None)
              | None ->
                Render.set_status r "No session and no project.";
                None)
           | None, _ ->
             Render.set_status r "No module name at cursor.";
             None)
        | None ->
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
                     Render.set_status r ("Source not found: " ^ v_path);
                     None
                   end
                 | None ->
                   Render.set_status r ("Cannot locate library for " ^ module_path);
                   None)
              | None ->
                Render.set_status r ("Cannot locate: " ^ msgs);
                None)
           | Some _, None ->
             Render.set_status r "No session.";
             None
           | None, _ ->
             Render.set_status r "No identifier at cursor.";
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
    else if match_binding ev Keys.help then begin
      if !in_help_mode then begin
        in_help_mode := false;
        help_scroll := 0
      end else
        in_help_mode := true;
      Some Continue
    end
    else if match_binding ev Keys.minimap then begin
      if Render.minimap_width r > 0 then
        Render.set_minimap_width r 0
      else
        Render.set_minimap_width r Minimap.width;
      Some Continue
    end
    else if match_binding ev Keys.about then begin
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
    else if match_binding ev Keys.print_query then begin
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
    else if match_binding ev Keys.copy then begin
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
    else if match_binding ev Keys.undo then begin
      Buffer.undo buf;
      rewind_if_needed tab;
      Some Continue
    end
    else if match_binding ev Keys.redo then begin
      Buffer.redo buf;
      rewind_if_needed tab;
      Some Continue
    end
    else None
  in
  (* --- Scroll keys for Goals/Messages panes --- *)
  let handle_pane_scroll pane_scroll_ref pane =
    match ev with
    | Input.Special (Input.Up, _) ->
      decr pane_scroll_ref; Some Continue
    | Input.Special (Input.Down, _) ->
      incr pane_scroll_ref; Some Continue
    | Input.Special (Input.PageDown, _) ->
      let (rows, _) = Render.pane_dims r pane in
      pane_scroll_ref := !pane_scroll_ref + (rows - 1); Some Continue
    | Input.Special (Input.PageUp, _) ->
      let (rows, _) = Render.pane_dims r pane in
      pane_scroll_ref := max 0 (!pane_scroll_ref - (rows - 1)); Some Continue
    | _ -> None
  in
  (* --- Script pane keys --- *)
  let handle_script () =
    match ev with
    (* Navigation with selection (shift+arrows) *)
    | Input.Special (Input.Left, m) when m.shift ->
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_left buf; Some Continue
    | Input.Special (Input.Right, m) when m.shift ->
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_right buf; Some Continue
    | Input.Special (Input.Up, m) when m.shift ->
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_up buf; Some Continue
    | Input.Special (Input.Down, m) when m.shift ->
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_down buf; Some Continue
    | Input.Special (Input.Home, m) when m.shift ->
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_home buf; Some Continue
    | Input.Special (Input.End, m) when m.shift ->
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      Buffer.move_end buf; Some Continue
    | Input.Special (Input.PageUp, m) when m.shift ->
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      let (rows, _) = Render.pane_dims r Render.PScript in
      Buffer.move_page_up buf (rows - 1); Some Continue
    | Input.Special (Input.PageDown, m) when m.shift ->
      if Buffer.selection buf = None then Buffer.set_anchor buf;
      let (rows, _) = Render.pane_dims r Render.PScript in
      Buffer.move_page_down buf (rows - 1); Some Continue
    (* Navigation without selection *)
    | Input.Special (Input.Up, _) ->
      Buffer.clear_selection buf; Buffer.move_up buf; Some Continue
    | Input.Special (Input.Down, _) ->
      Buffer.clear_selection buf; Buffer.move_down buf; Some Continue
    | Input.Special (Input.Left, _) ->
      Buffer.clear_selection buf; Buffer.move_left buf; Some Continue
    | Input.Special (Input.Right, _) ->
      Buffer.clear_selection buf; Buffer.move_right buf; Some Continue
    | Input.Special (Input.Home, _) ->
      Buffer.clear_selection buf; Buffer.move_home buf; Some Continue
    | Input.Special (Input.End, _) ->
      Buffer.clear_selection buf; Buffer.move_end buf; Some Continue
    | Input.Special (Input.PageDown, _) ->
      Buffer.clear_selection buf;
      let (rows, _) = Render.pane_dims r Render.PScript in
      Buffer.move_page_down buf (rows - 1); Some Continue
    | Input.Special (Input.PageUp, _) ->
      Buffer.clear_selection buf;
      let (rows, _) = Render.pane_dims r Render.PScript in
      Buffer.move_page_up buf (rows - 1); Some Continue
    (* Clipboard *)
    | _ when match_binding ev Keys.cut ->
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
    | _ when match_binding ev Keys.paste ->
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
    (* Delete *)
    | Input.Special (Input.Delete, _) ->
      if not (cursor_in_target tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        (match Buffer.delete_selection buf with
         | Some _ -> () | None -> Buffer.delete_char_at buf)
      end;
      Some Continue
    (* Backspace *)
    | Input.Special (Input.Backspace, _) ->
      if not (cursor_in_target ~for_backspace:true tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        (match Buffer.delete_selection buf with
         | Some _ -> () | None -> Buffer.delete_char_before buf)
      end;
      Some Continue
    (* Enter *)
    | Input.Special (Input.Enter, _) ->
      if not (cursor_in_target tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        ignore (Buffer.delete_selection buf);
        Buffer.insert_newline buf
      end;
      Some Continue
    (* Printable character *)
    | Input.Key (cp, mods) when cp >= 32 && not mods.ctrl && not mods.alt ->
      if not (cursor_in_target tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        ignore (Buffer.delete_selection buf);
        (* Encode codepoint as UTF-8 and insert *)
        if cp < 128 then
          Buffer.insert_char buf (Char.chr cp)
        else begin
          let s =
            if cp < 0x800 then
              let b = Bytes.create 2 in
              Bytes.set b 0 (Char.chr (0xC0 lor (cp lsr 6)));
              Bytes.set b 1 (Char.chr (0x80 lor (cp land 0x3F)));
              Bytes.to_string b
            else if cp < 0x10000 then
              let b = Bytes.create 3 in
              Bytes.set b 0 (Char.chr (0xE0 lor (cp lsr 12)));
              Bytes.set b 1 (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
              Bytes.set b 2 (Char.chr (0x80 lor (cp land 0x3F)));
              Bytes.to_string b
            else
              let b = Bytes.create 4 in
              Bytes.set b 0 (Char.chr (0xF0 lor (cp lsr 18)));
              Bytes.set b 1 (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
              Bytes.set b 2 (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
              Bytes.set b 3 (Char.chr (0x80 lor (cp land 0x3F)));
              Bytes.to_string b
          in
          insert_string tab s
        end
      end;
      Some Continue
    | _ -> None
  in
  let action =
    match handle_global () with
    | Some a -> a
    | None ->
      match tab.focused_pane with
      | `Goals ->
        let scroll_r = ref tab.goals_scroll in
        let result = handle_pane_scroll scroll_r Render.PGoals in
        tab.goals_scroll <- !scroll_r;
        (match result with Some a -> a | None -> Continue)
      | `Messages ->
        let scroll_r = ref (Tab.active_msg_tab tab.msg).mt_scroll in
        let result = handle_pane_scroll scroll_r Render.PMessages in
        (Tab.active_msg_tab tab.msg).mt_scroll <- !scroll_r;
        (match result with Some a -> a | None -> Continue)
      | `Script ->
        (match handle_script () with
         | Some a -> a | None -> Continue)
  in
  action
