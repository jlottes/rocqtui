(* tterm — terminal-only sibling of rocqtui. Hosts a tabbed bank of
   embedded terminals organized in a split layout. No Rocq, no
   script pane, no MCP. *)

open Rocqtui_lib

let xterm_set_title text =
  Term.write_stdout (Printf.sprintf "\x1b]0;%s\x07" text)

(* ----- Per-leaf terminal ownership ----- *)

(* leaf id -> terminals owned by that leaf. Authoritative for which
   terminals each leaf's Msg_pane.t should show. Not a strict
   partition of [Terminal.all ()] in transient moments (between
   spawn and the next sync), but is by the next render. *)
let owned : (int, Terminal.t list) Hashtbl.t = Hashtbl.create 8

let get_owned (l : Layout.leaf) =
  try Hashtbl.find owned l.id with Not_found -> []

let set_owned (l : Layout.leaf) ts =
  Hashtbl.replace owned l.id ts

let add_owned (l : Layout.leaf) t =
  set_owned l (get_owned l @ [t])

let remove_owned (l : Layout.leaf) t =
  set_owned l (List.filter (fun x -> not (x == t)) (get_owned l))

let drop_owner (l : Layout.leaf) =
  Hashtbl.remove owned l.id

(* Sync every leaf's Msg_pane against its owned list. Also prunes
   dead terminals (any that vanished from [Terminal.all ()]). *)
let sync_all_leaves layout =
  let live = Terminal.all () in
  Layout.iter_leaves layout (fun l ->
    let still_owned =
      List.filter (fun t -> List.exists (fun t' -> t' == t) live)
        (get_owned l)
    in
    set_owned l still_owned;
    Msg_pane.sync_terminals_in l.mp still_owned)

(* ----- Spawning / collapsing ----- *)

let spawn_in_leaf (l : Layout.leaf) =
  let body = Layout.leaf_body_rect l in
  let w = max 1 body.width in
  let h = max 1 body.height in
  let cwd = Sys.getcwd () in
  let term = Terminal.create ~cwd ~w ~h () in
  add_owned l term;
  Msg_pane.sync_terminals_in l.mp (get_owned l);
  Msg_pane.activate_in l.mp (Msg_pane.Terminal term);
  term

(* ----- Mouse handling ----- *)

(* Track per-leaf selection state: the leaf inside which a left-press
   started a vterm selection, plus the active terminal it targeted.
   Cleared on release. *)
type selection_state = {
  leaf : Layout.leaf;
  term : Terminal.t;
}

(* Higher-priority drag state. While this is non-Idle, motion events
   are routed to it instead of doing the leaf-hit-test dispatch. *)
type drag_state =
  | Drag_idle
  | Drag_border of { dir : [ `V | `H ]; split : Layout.split }
  | Drag_tab_pressed of {
      source : Layout.leaf;
      tab_index : int;
      start_x : int;
      start_y : int;
    }
  | Drag_tab_dragging of {
      source : Layout.leaf;
      tab : Msg_pane.tab;
      mutable cursor_x : int;
      mutable cursor_y : int;
    }

(* Promote-to-drag threshold. *)
let drag_threshold_x = 3
let drag_threshold_y = 1

let handle_mouse (ctx : Editor_context.t) (mev : Input.mouse_event)
    ~(layout : Layout.t)
    ~(active_leaf : Layout.leaf ref)
    ~(selection : selection_state option ref)
    ~(drag : drag_state ref)
    =
  let x = mev.x in
  let y = mev.y in
  let is_release = mev.button = Input.Release in
  let is_left = mev.button = Input.Left in
  let is_middle = mev.button = Input.Middle in
  let is_scroll_up = mev.button = Input.ScrollUp in
  let is_scroll_down = mev.button = Input.ScrollDown in
  let has_shift = mev.mods.shift in
  let has_cmd = mev.mods.ctrl in

  let leaf_active_term (l : Layout.leaf) =
    match l.mp.tabs with
    | [] -> None
    | _ ->
      match Msg_pane.active_kind_in l.mp with
      | Msg_pane.Terminal t -> Some t
      | _ -> None
  in
  let leaf_at = Layout.find_leaf_at layout ~x ~y in
  let border_at = Layout.find_split_border_at layout ~x ~y in

  (* Update a split's [frac] from a cursor position. compute_rects
     re-clamps next frame; we just keep it in (0,1) for sanity. *)
  let update_border_frac dir (s : Layout.split) =
    let usable, raw =
      match dir with
      | `V -> max 1 (s.rect.width - 1), x - s.rect.col
      | `H -> max 1 (s.rect.height - 1), y - s.rect.row
    in
    let f = float_of_int raw /. float_of_int usable in
    s.frac <- max 0.0 (min 1.0 f)
  in

  (* Tab hit-test helper for a leaf's strip: returns the index of
     the tab under [x] (if any). Uses the same layout that
     [View_terminal.draw_leaf_strip] uses, so truncated/scrolled
     tabs have hit areas matching what's actually painted. *)
  let tab_index_at_x (leaf : Layout.leaf) =
    let names = List.map Msg_pane.display_name leaf.mp.tabs in
    let focused = leaf.id = (!active_leaf).id in
    let visibles = Render.tab_strip_layout
      ~focused ~display_names:names ~active:leaf.mp.active
      ~width:leaf.rect.width () in
    List.find_map (fun (v : Render.visible_tab) ->
      let lo = leaf.rect.col + v.col_offset in
      let hi = lo + v.cell_width in
      if x >= lo && x < hi then Some v.orig_index else None
    ) visibles
  in
  (* Active border / drag-tab drag takes precedence. *)
  match !drag with
  | Drag_border { dir; split } ->
    if is_release then drag := Drag_idle
    else update_border_frac dir split
  | Drag_tab_pressed p ->
    if is_release then begin
      (* Click without drag → ordinary activate. *)
      drag := Drag_idle;
      if p.tab_index >= 0
         && p.tab_index < List.length p.source.mp.tabs then begin
        active_leaf := p.source;
        Msg_pane.activate_in p.source.mp
          (List.nth p.source.mp.tabs p.tab_index).kind
      end
    end
    else if abs (x - p.start_x) >= drag_threshold_x
         || abs (y - p.start_y) >= drag_threshold_y then begin
      (* Promote to dragging. *)
      if p.tab_index >= 0
         && p.tab_index < List.length p.source.mp.tabs then begin
        let tab = List.nth p.source.mp.tabs p.tab_index in
        drag := Drag_tab_dragging {
          source = p.source; tab;
          cursor_x = x; cursor_y = y;
        }
      end
      else drag := Drag_idle
    end
  | Drag_tab_dragging d ->
    if is_release then begin
      (* Drop. *)
      drag := Drag_idle;
      let target_leaf = Layout.find_leaf_at layout ~x ~y in
      (match target_leaf with
       | Some target when target.id <> d.source.id ->
         (* Move the terminal + sub-tab. *)
         (match d.tab.kind with
          | Msg_pane.Terminal term ->
            if Msg_pane.take_tab_in d.source.mp d.tab then begin
              remove_owned d.source term;
              add_owned target term;
              Msg_pane.insert_in target.mp d.tab;
              active_leaf := target
            end
          | _ -> ())
       | _ -> ())
    end
    else begin
      d.cursor_x <- x;
      d.cursor_y <- y
    end
  | Drag_idle ->

  (* In-progress selection drag: route to its leaf regardless of
     current cursor position so drags can extend past the leaf
     boundary. *)
  (match !selection with
   | Some sel ->
     let vt = Terminal.vterm sel.term in
     let body = Layout.leaf_body_rect sel.leaf in
     let vy = y - body.row in
     let vx = x - body.col in
     let (line, col) = Vterm_lib.Vterm_api.hit_test vt ~row:vy ~col:vx in
     Vterm_lib.Vterm_api.sel_extend vt ~line ~col;
     if is_release then selection := None
   | None ->
     match leaf_at, border_at with
     | None, Some `VBorder s when is_left ->
       drag := Drag_border { dir = `V; split = s }
     | None, Some `HBorder s when is_left ->
       drag := Drag_border { dir = `H; split = s }
     | None, _ -> ()  (* Click on a divider with the wrong button, or outside. *)
     | Some leaf, _ ->
       let on_tab_strip = y = leaf.rect.row in
       let body = Layout.leaf_body_rect leaf in
       let in_body =
         y >= body.row && y < body.row + body.height
         && x >= body.col && x < body.col + body.width
       in
       let active_term = leaf_active_term leaf in
       (* Drag/release for mouse-reporting terminals — route via the
          leaf we're inside. *)
       let term_reported_handled = ref false in
       (match active_term with
        | Some term when Terminal.reported_buttons term <> 0 && in_body ->
          let vt = Terminal.vterm term in
          let mm = Vterm_lib.Vterm_api.mouse_mode vt in
          let mf = Vterm_lib.Vterm_api.mouse_flags vt in
          let cx = x - body.col + 1 in
          let cy = y - body.row + 1 in
          let mods_i = (if has_shift then 1 else 0)
            lor (if mev.mods.alt then 2 else 0)
            lor (if has_cmd then 4 else 0) in
          if is_release then begin
            for button = 1 to 5 do
              if Terminal.reported_buttons term land (1 lsl button) <> 0 then begin
                let seq = Vterm_lib.Vterm_api.mouseseq ~button ~modifiers:mods_i
                  ~cx ~cy ~ev:Vterm_lib.Vterm_api.mouse_ev_release ~mode:mm ~flags:mf in
                Terminal.send term seq
              end
            done;
            Terminal.set_reported_buttons term 0;
            term_reported_handled := true
          end
          else if not is_scroll_up && not is_scroll_down then begin
            if mm >= Vterm_lib.Vterm_api.mouse_mode_btn then begin
              let seq = Vterm_lib.Vterm_api.mouseseq ~button:1 ~modifiers:mods_i
                ~cx ~cy ~ev:Vterm_lib.Vterm_api.mouse_ev_motion ~mode:mm ~flags:mf in
              Terminal.send term seq
            end;
            term_reported_handled := true
          end
        | _ -> ());
       if !term_reported_handled then ()
       else if on_tab_strip && is_left then begin
         (* Tab-strip left-press → enter [Drag_tab_pressed]. The
            click vs. drag decision happens on motion or release. *)
         match tab_index_at_x leaf with
         | Some i ->
           drag := Drag_tab_pressed {
             source = leaf; tab_index = i;
             start_x = x; start_y = y;
           }
         | None -> ()
       end
       else if on_tab_strip && (is_scroll_up || is_scroll_down) then begin
         active_leaf := leaf;
         if is_scroll_up then Msg_pane.activate_prev_in leaf.mp
         else Msg_pane.activate_next_in leaf.mp
       end
       else if in_body && (is_scroll_up || is_scroll_down) then begin
         active_leaf := leaf;
         match active_term with
         | None -> ()
         | Some term ->
           let vt = Terminal.vterm term in
           let mm = Vterm_lib.Vterm_api.mouse_mode vt in
           let mf = Vterm_lib.Vterm_api.mouse_flags vt in
           let alt = Vterm_lib.Vterm_api.alt_screen vt in
           let mouse_active = mm <> 0 && not has_shift in
           let handled = ref false in
           if not mouse_active then begin
             if alt && (mf land Vterm_lib.Vterm_api.mouse_alt_scroll <> 0) then begin
               let mode = Vterm_lib.Vterm_api.term_mode vt in
               let seq = if mode land Vterm_lib.Vterm_api.mode_app_cursor <> 0
                 then (if is_scroll_up then "\027OA" else "\027OB")
                 else (if is_scroll_up then "\027[A" else "\027[B") in
               Terminal.send term seq;
               handled := true
             end
             else if mm = 0 || not alt then begin
               ignore (Vterm_lib.Vterm_api.scroll vt
                 (if is_scroll_up then -3 else 3));
               handled := true
             end
           end;
           if not !handled && mm <> 0 then begin
             let cx = x - body.col + 1 in
             let cy = y - body.row + 1 in
             let button = if is_scroll_up then 4 else 5 in
             let mods_i = (if has_shift then 1 else 0)
               lor (if mev.mods.alt then 2 else 0)
               lor (if has_cmd then 4 else 0) in
             let seq = Vterm_lib.Vterm_api.mouseseq ~button ~modifiers:mods_i
               ~cx ~cy ~ev:Vterm_lib.Vterm_api.mouse_ev_press ~mode:mm ~flags:mf in
             Terminal.send term seq
           end
       end
       else if in_body && is_left then begin
         active_leaf := leaf;
         match active_term with
         | None -> ()
         | Some term ->
           let vt = Terminal.vterm term in
           let mm = Vterm_lib.Vterm_api.mouse_mode vt in
           let forwarded =
             if mm <> 0 && not has_shift then begin
               let mf = Vterm_lib.Vterm_api.mouse_flags vt in
               let cx = x - body.col + 1 in
               let cy = y - body.row + 1 in
               let mods_i = (if has_shift then 1 else 0)
                 lor (if mev.mods.alt then 2 else 0)
                 lor (if has_cmd then 4 else 0) in
               let seq = Vterm_lib.Vterm_api.mouseseq ~button:1 ~modifiers:mods_i
                 ~cx ~cy ~ev:Vterm_lib.Vterm_api.mouse_ev_press ~mode:mm ~flags:mf in
               Terminal.send term seq;
               Terminal.set_reported_buttons term
                 (Terminal.reported_buttons term lor (1 lsl 1));
               true
             end else false
           in
           if not forwarded then begin
             let vy = y - body.row in
             let vx = x - body.col in
             let (line, col) = Vterm_lib.Vterm_api.hit_test vt ~row:vy ~col:vx in
             if has_shift && Vterm_lib.Vterm_api.has_selection vt then
               Vterm_lib.Vterm_api.sel_extend vt ~line ~col
             else
               Vterm_lib.Vterm_api.sel_start vt ~line ~col;
             selection := Some { leaf; term }
           end
       end
       else if in_body && is_middle then begin
         active_leaf := leaf;
         (match active_term with
          | Some term when ctx.clipboard <> "" ->
            let vt = Terminal.vterm term in
            if Vterm_lib.Vterm_api.bracketed_paste vt then
              Terminal.send term
                ("\x1b[200~" ^ ctx.clipboard ^ "\x1b[201~")
            else
              Terminal.send term ctx.clipboard
          | _ -> ())
       end)

(* ----- Main ----- *)

let () =
  let xcompose = ref false in
  Array.iter (fun a ->
    if a = "--xcompose" || a = "-xcompose" then xcompose := true
  ) Sys.argv;

  Sys.set_signal Sys.sigint Sys.Signal_ignore;
  Sys.set_signal Sys.sigtstp Sys.Signal_ignore;
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Printexc.record_backtrace true;
  Term.init ();
  (* Restore the terminal on every exit path (same scheme as rocqtui's
     main): at_exit covers plain [exit]; the uncaught-exception handler
     tears down before printing so the error lands on the main screen.
     Term.teardown is idempotent. *)
  at_exit Term.teardown;
  Printexc.set_uncaught_exception_handler (fun e bt ->
    Term.teardown ();
    Printf.eprintf "Fatal error: exception %s\n%s%!"
      (Printexc.to_string e) (Printexc.raw_backtrace_to_string bt));
  let r = Render.create () in
  Theme.apply Theme.default;

  let ctx = Editor_context.create
    ~switch_tab:(fun _ -> ())
    ~switch_to_tab_id:(fun _ -> ())
    ~open_files:(fun () -> [])
    ~tabs:(fun () -> [])
    () in
  ctx.focus <- Editor_context.FMessages;
  if !xcompose then Editor.init_compose ctx;

  Terminal.set_clipboard_hook (fun text ->
    ctx.clipboard <- text;
    Clipboard.copy_to_system text);

  (* Initial layout: one leaf, one terminal in it. *)
  let root_leaf = Layout.new_leaf () in
  let layout = ref (Layout.Leaf root_leaf) in
  let active_leaf = ref root_leaf in
  let initial_bounds = View_terminal.body_rect r in
  Layout.compute_rects !layout ~bounds:initial_bounds;
  ignore (spawn_in_leaf root_leaf);

  let input = Input.create () in
  let last_host_title = ref "" in
  let sync_host_title () =
    let title =
      let l = !active_leaf in
      match l.mp.tabs with
      | [] -> "tterm"
      | _ ->
        match Msg_pane.active_kind_in l.mp with
        | Msg_pane.Terminal t -> "tterm — " ^ Terminal.title t
        | _ -> "tterm"
    in
    if title <> !last_host_title then begin
      xterm_set_title title;
      last_host_title := title
    end
  in
  sync_host_title ();

  let stdin_fd = Unix.stdin in
  let running = ref true in
  let selection : selection_state option ref = ref None in
  let drag : drag_state ref = ref Drag_idle in

  (* Per-frame prep: lay out, sync, resize. *)
  let prepare_frame () =
    Layout.compute_rects !layout ~bounds:(View_terminal.body_rect r);
    sync_all_leaves !layout;
    Layout.iter_leaves !layout (fun l ->
      let body = Layout.leaf_body_rect l in
      List.iter (fun t ->
        Terminal.resize t ~w:body.width ~h:body.height
      ) (get_owned l))
  in

  (* If we're in tab-drag mode, paint a 1-row ghost label at the
     cursor + (optional) a reverse-video highlight over the target
     leaf's tab strip. Both reuse the existing render-overlay slot,
     drawn last so they sit on top of the laid-out scene. *)
  let make_overlay () : (Grid.t -> unit) option =
    match !drag with
    | Drag_tab_dragging d ->
      let label = " " ^ Msg_pane.display_name d.tab ^ " " in
      let cur_x = d.cursor_x in
      let cur_y = d.cursor_y in
      let target = Layout.find_leaf_at !layout ~x:cur_x ~y:cur_y in
      Some (fun g ->
        (* Drop-target highlight on a different leaf's strip. *)
        (match target with
         | Some tgt when tgt.id <> d.source.id ->
           let attr = (Theme.attrs ()).ga_tab_active in
           Grid.fill g ~row:tgt.rect.row ~col:tgt.rect.col
             ~width:tgt.rect.width ' ' attr
         | _ -> ());
        (* Ghost label at cursor position. *)
        let attr = (Theme.attrs ()).ga_tab_active in
        ignore (Grid.put_str g ~row:cur_y ~col:cur_x label attr))
    | _ -> None
  in
  let render_frame ?(force=false) () =
    prepare_frame ();
    View_terminal.render_all ctx r !layout
      ~active_leaf_id:(!active_leaf).id ~overlay:(make_overlay ());
    Render.present ~force r
  in

  (* After a terminal is destroyed in a leaf, sync and collapse if
     empty. Also reassign [active_leaf] if it was the collapsed leaf. *)
  let collapse_if_empty (l : Layout.leaf) =
    sync_all_leaves !layout;
    if l.mp.tabs = [] then begin
      drop_owner l;
      match Layout.collapse_leaf !layout l with
      | None ->
        (* Was the last leaf. *)
        running := false
      | Some new_root ->
        layout := new_root;
        if (!active_leaf).id = l.id then begin
          match Layout.leaves new_root with
          | first :: _ -> active_leaf := first
          | [] -> running := false
        end
    end
  in

  render_frame ();

  while !running do
    let term_fds = Terminal.fds () in
    (* A held lone ESC resolves on the next idle cycle — keep it short. *)
    let timeout = if Input.pending input then 0.05 else 0.1 in
    let ready =
      try
        Main_loop.select_with_watches
          (stdin_fd :: List.map fst term_fds) timeout
      with Unix.Unix_error (Unix.EINTR, _, _) -> []
    in

    List.iter (fun (fd, term) ->
      if List.mem fd ready then begin
        if Terminal.poll term then Render_need.request ()
      end
    ) term_fds;
    List.iter (fun (_, term) ->
      let pty = Terminal.pty term in
      if Vterm_lib.Pty.has_buffered pty then
        Vterm_lib.Pty.flush_write pty
    ) term_fds;

    (* A shell exiting on its own counts as a leaf-level close too. *)
    let any_died = ref false in
    Layout.iter_leaves !layout (fun l ->
      let live = Terminal.all () in
      let owned_l = get_owned l in
      List.iter (fun t ->
        if not (List.exists (fun t' -> t' == t) live) then any_died := true;
        ignore (t, owned_l)
      ) owned_l);
    if !any_died then begin
      (* Walk leaves and collapse any that emptied. *)
      let to_check = Layout.leaves !layout in
      List.iter collapse_if_empty to_check
    end;

    if Term.check_resize () then begin
      Render.resize r;
      Render_need.request_full ()
    end;

    if List.mem stdin_fd ready then ignore (Input.read_available input stdin_fd);
    (* A lone ESC with no follow-up byte this cycle resolves to Escape. *)
    if not (List.mem stdin_fd ready) && Input.pending input then
      Input.flush input;
    if !running then begin
      let rec drain () =
        match Input.next_event input with
        | None -> ()
        | Some Input.Resize ->
          Render.resize r;
          Render_need.request_full ();
          if !running then drain ()
        | Some (Input.Mouse mev) ->
          handle_mouse ctx mev ~layout:!layout
            ~active_leaf ~selection ~drag;
          (* A drag-tab drop can leave the source leaf empty. *)
          List.iter collapse_if_empty (Layout.leaves !layout);
          Render_need.request ();
          if !running then drain ()
        | Some ev ->
          (* Cancel any in-flight tab drag on a non-mouse event so a
             keystroke during drag doesn't leave a stuck ghost. *)
          (match !drag with
           | Drag_tab_pressed _ | Drag_tab_dragging _ ->
             drag := Drag_idle
           | _ -> ());
          let leaf = !active_leaf in
          let active = match leaf.mp.tabs with
            | [] -> None
            | _ ->
              (match Msg_pane.active_kind_in leaf.mp with
               | Msg_pane.Terminal t -> Some t
               | _ -> None)
          in
          let compose_handled = match ctx.compose with
            | Some cs when Compose.active cs ->
              (match Keymatch.codepoint_of_event ev with
               | Some cp ->
                 (match Compose.feed cs cp with
                  | Compose.Pending ->
                    Render.set_status r (View.format_compose_status r cs);
                    Render.present r
                  | Compose.Composed text ->
                    (match active with
                     | Some term -> Terminal.send term text
                     | None -> ())
                  | Compose.NoMatch ->
                    (match ev, active with
                     | Input.Special (Input.Escape, _), Some term ->
                       (* Emit a plain ESC byte to the leaf's active
                          terminal. [Pty.send_escape] uses the
                          singleton's active terminal, so we bypass
                          it for tterm. *)
                       Terminal.send term "\x1b"
                     | _ -> ()));
                 true
               | None ->
                 ignore (Compose.feed cs 0);
                 false)
            | _ -> false
          in
          if compose_handled then begin
            Render_need.request ();
            if !running then drain ()
          end
          else if Keymatch.match_binding ev Keys.split_vertical then begin
            let nl = Layout.new_leaf () in
            layout := Layout.split_leaf !layout
              ~existing:leaf ~inserted:nl ~dir:`V;
            (* Recompute rects so the new leaf has a body big enough
               to host its terminal. *)
            Layout.compute_rects !layout
              ~bounds:(View_terminal.body_rect r);
            ignore (spawn_in_leaf nl);
            active_leaf := nl;
            Render_need.request ();
            if !running then drain ()
          end
          else if Keymatch.match_binding ev Keys.split_horizontal then begin
            let nl = Layout.new_leaf () in
            layout := Layout.split_leaf !layout
              ~existing:leaf ~inserted:nl ~dir:`H;
            Layout.compute_rects !layout
              ~bounds:(View_terminal.body_rect r);
            ignore (spawn_in_leaf nl);
            active_leaf := nl;
            Render_need.request ();
            if !running then drain ()
          end
          else begin
            match Terminal_input.handle
                    ~include_rocqtui_bindings:false
                    ctx ev ~active r with
            | Terminal_input.Quit -> running := false
            | Terminal_input.Closed_term ->
              collapse_if_empty leaf
            | Terminal_input.Open_term ->
              ignore (spawn_in_leaf leaf)
            | Terminal_input.Pass_to_term ->
              (match active with
               | Some term -> Editor.Pty.forward_event term ev
               | None -> ())
            | Terminal_input.Continue -> ()
            | Terminal_input.Open_claude
            | Terminal_input.Save_prompt
            | Terminal_input.Cycle_pane
            | Terminal_input.Build_menu
            | Terminal_input.Help -> ();
            Render_need.request ();
            if !running then drain ()
          end
      in
      drain ()
    end;

    if !running then begin
      sync_host_title ();
      match Render_need.take () with
      | Render_need.No -> ()
      | Render_need.Yes -> render_frame ()
      | Render_need.Full -> render_frame ~force:true ()
    end
  done;

  List.iter (fun t -> try Terminal.destroy t with _ -> ())
    (Terminal.all ());
  xterm_set_title "";
  Term.teardown ()
