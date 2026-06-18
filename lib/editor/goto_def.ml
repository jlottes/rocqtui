(* Jump-to-definition helpers shared by the ^L key and the live-info 🔍
   glyph. Resolve an identifier (or a Required module) to its source via
   [Locate] + the .glob index, then open it. Factored out of the ^L
   handler so the live-info pane can reuse the exact same path. *)

let format_msgs pps = String.concat "\n" (List.map Session.string_of_pp pps)

let try_project (ctx : Editor_context.t) m =
  match ctx.project with
  | Some p -> Project.resolve_module p m
  | None -> None

let finalize (ctx : Editor_context.t) (tab : Tab.t) ?target_line path =
  Jump.push ctx tab;
  ctx.jump_target <- (match target_line with Some l -> Some (l, 0) | None -> None);
  ctx.pending_open <- Some path

(* [Locate Library M.] → the .v source; for an identifier, then use the
   .glob index to find [def_name]'s line within it. *)
let jump_to_library_ident ctx r tab module_path def_name pps =
  match Locate.parse_locate_library (format_msgs pps) with
  | Some vo_path ->
    let v_path = Locate.vo_to_v vo_path in
    if Sys.file_exists v_path then begin
      let glob_path = Locate.vo_to_glob vo_path in
      let target_line =
        if Sys.file_exists glob_path then
          let entries = Glob.parse glob_path in
          (match Glob.find_definition entries def_name with
           | Some e -> Glob.byte_offset_to_line v_path e.Glob.bp
           | None -> None)
        else None
      in
      finalize ctx tab ?target_line v_path
    end else Render.set_status r ("Source not found: " ^ v_path)
  | None -> Render.set_status r ("Cannot locate library for " ^ module_path)

let of_ident (ctx : Editor_context.t) r ~(tab : Tab.t) ~session w =
  Session.query session ("Locate " ^ w ^ ".") ~on_done:(fun pps ->
    match Locate.parse_locate (format_msgs pps) with
    | Some (_kind, module_path, def_name) ->
      Session.query session ("Locate Library " ^ module_path ^ ".")
        ~on_done:(jump_to_library_ident ctx r tab module_path def_name)
    | None -> Render.set_status r ("Cannot locate: " ^ format_msgs pps))

let of_require_module (ctx : Editor_context.t) r ~(tab : Tab.t) ~session m =
  let after pps =
    match Locate.parse_locate_library (format_msgs pps) with
    | Some vo_path ->
      let v_path = Locate.vo_to_v vo_path in
      if Sys.file_exists v_path then finalize ctx tab v_path
      else Render.set_status r ("Source not found: " ^ v_path)
    | None ->
      (match try_project ctx m with
       | Some path -> finalize ctx tab path
       | None -> Render.set_status r ("Module not found: " ^ m))
  in
  match session with
  | Some s -> Session.query s ("Locate Library " ^ m ^ ".") ~on_done:after
  | None ->
    (match try_project ctx m with
     | Some path -> finalize ctx tab path
     | None -> Render.set_status r ("Module not found: " ^ m))
