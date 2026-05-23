(* Per-file build status for the project's .v files, derived from
   mtimes against the dep graph from [Dep_runner] / [Dep_graph].
   Maintained as global state, like [Build_errors] — refreshed
   explicitly from the main loop on graph or build state changes. *)

type status =
  | Built_fresh    (* .vo exists and is newer than its .v + every transitive dep .vo *)
  | Stale          (* .vo missing, older than .v, or behind a dep .vo *)
  | Build_error    (* most recent build emitted Error: for this file *)
  | Never_built    (* .vo missing AND no prior error pinned to this file *)

let table : (string, status) Hashtbl.t = Hashtbl.create 64

let clear () = Hashtbl.reset table

let get rel_path =
  match Hashtbl.find_opt table rel_path with
  | Some s -> s
  | None -> Never_built

let stat_mtime path =
  try Some (Unix.stat path).Unix.st_mtime with _ -> None

let vo_of_v rel_v =
  if Filename.check_suffix rel_v ".v" then
    Filename.chop_suffix rel_v ".v" ^ ".vo"
  else rel_v ^ "o"

let refresh ~project_dir ~graph ~error_files =
  let topo = Dep_graph.toposort graph in
  let error_set = Hashtbl.create (List.length error_files) in
  List.iter (fun p -> Hashtbl.replace error_set p ()) error_files;
  let vo_mtime_tbl : (string, float option) Hashtbl.t =
    Hashtbl.create (List.length topo) in
  Hashtbl.reset table;
  List.iter (fun rel_v ->
    let v_path = Filename.concat project_dir rel_v in
    let vo_path = Filename.concat project_dir (vo_of_v rel_v) in
    let v_mtime = stat_mtime v_path in
    let vo_mtime = stat_mtime vo_path in
    Hashtbl.replace vo_mtime_tbl rel_v vo_mtime;
    let mtime_status =
      match vo_mtime with
      | None -> Never_built
      | Some vot ->
        let own_stale =
          match v_mtime with
          | Some vt -> vt > vot
          | None -> false  (* .v missing — leave to make to complain *)
        in
        if own_stale then Stale
        else
          let parents = Dep_graph.deps graph rel_v in
          let propagated_stale =
            List.exists (fun p ->
              match Hashtbl.find_opt table p with
              | Some (Stale | Never_built | Build_error) -> true
              | _ ->
                match Hashtbl.find_opt vo_mtime_tbl p with
                | Some (Some pt) -> pt > vot
                | _ -> false
            ) parents
          in
          if propagated_stale then Stale else Built_fresh
    in
    let final =
      if Hashtbl.mem error_set rel_v then Build_error else mtime_status
    in
    Hashtbl.replace table rel_v final
  ) topo
