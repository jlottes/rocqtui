(* Renders the Search messages-tab body from a [Search_results.t].
   Same shape as [Build_errors.render_errors_tab]: returns a list of
   styled lines plus the row offset of the current match (for auto-
   scrolling), and stashes a row→entry reverse map so the click
   handler can translate body-row clicks back into (file, match)
   coordinates. *)

(* Row-index → (file_path, match_index) option.
   None = file header row. Refreshed by [render]. *)
let row_map : (string * int) option array ref = ref [||]

let lookup_tab_row row =
  let m = !row_map in
  if row < 0 || row >= Array.length m then None
  else m.(row)

let render results_opt =
  let rows = ref [] in
  let map = ref [] in
  let active_row = ref None in
  let row_count = ref 0 in
  let emit entry line =
    rows := line :: !rows;
    map := entry :: !map;
    incr row_count
  in
  let attrs = Theme.attrs () in
  (match results_opt with
   | None -> ()
   | Some r ->
     let cur = Search_results.current r in
     let header_attrs =
       { attrs.ga_border with bold = true }
     in
     List.iter (fun (fm : Search_results.file_matches) ->
       let count = Array.length fm.fm_matches in
       let display_path =
         if fm.fm_rel_path <> "" then fm.fm_rel_path else fm.fm_path
       in
       let header_text =
         Printf.sprintf "%s  (%d)" display_path count
       in
       emit None (Styled.style header_text header_attrs);
       Array.iteri (fun i (m : Search_results.match_loc) ->
         let is_current = match cur with
           | Some (p, idx) -> p = fm.fm_path && idx = i
           | None -> false
         in
         let prefix_text = if is_current then "  \xe2\x96\xb8 "  (* ▸ *)
                           else "    " in
         let line_no = Printf.sprintf "%4d: " m.ml_line in
         let prefix_len = String.length prefix_text in
         let line_no_len = String.length line_no in
         let body_text = m.ml_line_text in
         let text = prefix_text ^ line_no ^ body_text in
         let line_no_attr = attrs.ga_comment in
         let match_attr =
           (* All match spans share the active-match palette so the
              user actually sees them. The non-current matches get
              reverse-video on top — flipping the bright bg to fg
              dims the cell. The current match stays bright. *)
           if is_current then attrs.ga_search_current
           else { attrs.ga_search_current with reverse = true } in
         let spans = [
           { Styled.start = prefix_len;
             len = line_no_len;
             attr = line_no_attr };
           { Styled.start = prefix_len + line_no_len + m.ml_col_start;
             len = m.ml_col_end - m.ml_col_start;
             attr = match_attr };
         ] in
         if is_current then active_row := Some !row_count;
         emit (Some (fm.fm_path, i)) { Styled.text; spans }
       ) fm.fm_matches
     ) (Search_results.files r));
  let body = List.rev !rows in
  let map_arr = Array.of_list (List.rev !map) in
  row_map := map_arr;
  (body, !active_row)
