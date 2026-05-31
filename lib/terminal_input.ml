type result =
  | Continue
  | Pass_to_term
  | Quit
  | Closed_term
  | Open_term
  | Open_claude
  | Save_prompt
  | Cycle_pane
  | Build_menu
  | Help

let handle ?(include_rocqtui_bindings = true)
    (ctx : Editor_context.t) (ev : Input.event)
    ~(active : Terminal.t option) r =
  if Keymatch.match_binding ev Keys.quit then Quit
  else if Keymatch.match_binding ev Keys.close_tab then begin
    (* Destroy the terminal; leave [Msg_pane] resyncing to the
       caller (rocqtui's render path / tterm's leaf collapse). *)
    (match active with
     | Some term -> Terminal.destroy term
     | None -> ());
    Closed_term
  end
  else if Keymatch.match_binding ev Keys.open_terminal then Open_term
  else if Keymatch.match_binding ev Keys.copy
          && not (match ev with
            | Input.Key (3, _) -> true
            | Input.Key (99, m) when m.ctrl -> true
            | _ -> false) then begin
    (* Copy terminal selection (^Y only; ^C goes to terminal). *)
    (match active with
     | Some term ->
       let vt = Terminal.vterm term in
       if Vterm_lib.Vterm_api.has_selection vt then
         (match Vterm_lib.Vterm_api.sel_text vt with
          | Some text ->
            ctx.clipboard <- text;
            Clipboard.copy_to_system text
          | None -> ())
     | None -> ());
    Continue
  end
  else if (match ev with
      | Input.Special (Input.Escape, _) -> true | _ -> false) then begin
    (* ESC starts compose mode; double-ESC sends ESC to terminal
       (handled by the compose-NoMatch path in Editor / by ordinary
       pass-through in tterm). *)
    (match ctx.compose with
     | Some cs ->
       Compose.start cs;
       Render.set_status r (View.format_compose_status r cs);
       Render.present r
     | None -> ());
    Continue
  end
  else if include_rocqtui_bindings then begin
    if Keymatch.match_binding ev Keys.cycle_pane then Cycle_pane
    else if Keymatch.match_binding ev Keys.save then Save_prompt
    else if Keymatch.match_binding ev Keys.build_menu then Build_menu
    else if Keymatch.match_binding ev Keys.help then Help
    else if Keymatch.match_binding ev Keys.open_claude then Open_claude
    else Pass_to_term
  end
  else Pass_to_term
