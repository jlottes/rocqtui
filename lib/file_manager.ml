(* File manager: owns the inotify watcher, dispatches change events
   against open tabs (auto-reload vs notify) and against the project
   tree (refresh hint for File_tree). *)

type file_event =
  | Reloaded of string          (* file was auto-reloaded *)
  | DiskChanged of string       (* file changed, buffer is dirty — notify only *)
  | VerifiedAffected of string  (* file changed within verified region — notify only *)
  | ProjectChanged              (* project tree gained/lost entries *)
  | SourcesChanged              (* .v contents or project file changed — rerun rocq dep *)
  | BuildArtifactChanged        (* .vo / .v inside project written — refresh build status *)

type t = {
  watcher : File_watch.t;
  mutable deferred : string list;
  (* Paths whose change events arrived while a tab was locked by
     an external client. Re-tried on each poll until the lock
     releases. *)
  mutable project_dir : string option;
  (* Set of currently watched project subdirectories (relative-or-
     absolute — we store absolute paths). Used to add new watches when
     subdirectories are created, and to track for set_project_dir
     reset. *)
  mutable project_subdirs : string list;
  (* Path to the watched _RocqProject / _CoqProject file, if any.
     FileChanged events on this path are surfaced as ProjectChanged so
     File_tree refreshes when the project file is edited. *)
  mutable project_file_watched : string option;
  (* Per-path callbacks for files that aren't tabs and aren't the
     project file (e.g. ~/.XCompose). FileChanged events with a
     matching path fire the callback and bypass tab dispatch. *)
  mutable file_callbacks : (string * (unit -> unit)) list;
}

let create () =
  { watcher = File_watch.create ();
    deferred = [];
    project_dir = None;
    project_subdirs = [];
    project_file_watched = None;
    file_callbacks = [] }

let register_file_callback t ~path ~on_change =
  t.file_callbacks <-
    (path, on_change) :: List.remove_assoc path t.file_callbacks;
  File_watch.add_watch t.watcher path

let watch_fd t = File_watch.watch_fd t.watcher

let add_watch t path =
  File_watch.add_watch t.watcher path

let close t =
  File_watch.close t.watcher

(* --- Project tree watching --- *)

(* Directories we never recurse into. _build is touched on every Rocq
   compile, .git is a giant churn source, and dot-dirs are usually
   tooling caches the user doesn't see in the file tree anyway. *)
let skip_dir name =
  name = "_build" || name = ".git"
  || (String.length name > 0 && name.[0] = '.')

(* Recursively add directory watches under [dir]. Tracks added paths
   in [t.project_subdirs] so [set_project_dir] can tear them down. *)
let rec add_project_subtree t dir =
  if not (List.mem dir t.project_subdirs) then begin
    File_watch.add_dir_watch t.watcher dir;
    t.project_subdirs <- dir :: t.project_subdirs
  end;
  let entries = try Sys.readdir dir with _ -> [||] in
  Array.iter (fun name ->
    if not (skip_dir name) then begin
      let path = Filename.concat dir name in
      try
        if Sys.is_directory path then
          add_project_subtree t path
      with _ -> ()
    end
  ) entries

let clear_project_watches t =
  List.iter (fun dir ->
    File_watch.remove_watch t.watcher dir
  ) t.project_subdirs;
  t.project_subdirs <- [];
  (match t.project_file_watched with
   | Some pf -> File_watch.remove_watch t.watcher pf
   | None -> ());
  t.project_file_watched <- None;
  t.project_dir <- None

(* Conventional project-file names, in priority order. Kept in sync with
   [Project.filenames]; duplicated here to avoid an upward dependency
   from File_manager onto Project. *)
let project_file_candidates = ["_RocqProject"; "_CoqProject"]

(* Filenames whose write/create/delete inside a watched project
   subdirectory should trigger a build-status refresh. .v because make
   compares .v vs .vo mtimes; .vo because that's the artifact whose
   freshness we report. Other build by-products (.glob, .vos, .vok)
   change in lockstep with .vo and add nothing. *)
let affects_build_status name =
  Filename.check_suffix name ".v"
  || Filename.check_suffix name ".vo"

(* Filenames whose appearance / disappearance changes the visible file
   tree (only .v files are rendered) or the dep / search paths
   (project file). The same predicate also covers everything whose
   appearance / disappearance would change what [rocq dep] sees, so
   [ProjectChanged] and [SourcesChanged] are emitted together. Build
   by-products like .vo, .glob, .vos, .vok, .v.d, etc. don't qualify
   — neither does a tmp file from an external editor. *)
let affects_tree_shape name is_dir =
  is_dir
  || Filename.check_suffix name ".v"
  || List.mem name project_file_candidates

let find_project_file_in dir =
  List.find_map (fun name ->
    let path = Filename.concat dir name in
    if Sys.file_exists path then Some path else None
  ) project_file_candidates

let set_project_dir t dir =
  if t.project_dir <> Some dir then begin
    clear_project_watches t;
    t.project_dir <- Some dir;
    add_project_subtree t dir;
    (* Also watch the project file for content changes (-R / -Q
       directives, listed-files lines). *)
    (match find_project_file_in dir with
     | Some pf ->
       File_watch.add_watch t.watcher pf;
       t.project_file_watched <- Some pf
     | None -> ())
  end

(* --- Reload helpers (unchanged) --- *)

(* Reload a tab's buffer from disk: rewind session, reload, re-watch.
   If [keep_verified] is true, skip the session rewind and let the
   gateway decide if the reload preserves the verified region. *)
let reload_tab ?(keep_verified = false) t (tab : Tab.t) path =
  if not keep_verified then
    (match tab.session with
     | Some s -> Session.go_to_offset s 0
     | None -> ());
  let result = Region_buffer.try_reload_from_disk tab.rb in
  (match result with
   | Region_buffer.Applied ->
     Buffer.set_disk_changed tab.buf false;
     File_watch.add_watch t.watcher path
   | Region_buffer.Rejected _ -> ());
  result

(* --- Poll --- *)

(* Process file-content events against open tabs (existing behaviour).
   Events for tabs whose buffer is locked are deferred and retried on
   subsequent polls. Returns reverse-order list of file_events. *)
let process_file_changes t (tabs : Tab.t list) paths =
  if paths = [] then []
  else begin
    let to_process =
      List.sort_uniq String.compare (t.deferred @ paths)
    in
    t.deferred <- [];
    let events = ref [] in
    let still_deferred = ref [] in
    let defer path =
      if not (List.mem path !still_deferred) then
        still_deferred := path :: !still_deferred
    in
    List.iter (fun path ->
      List.iter (fun (tab : Tab.t) ->
        match Buffer.filename tab.buf with
        | Some f when f = path ->
          if Region_buffer.locked tab.rb then
            defer path
          else begin
            Buffer.set_disk_changed tab.buf true;
            if Buffer.modified tab.buf then
              events := DiskChanged path :: !events
            else begin
              let old_text = Buffer.text tab.buf in
              let new_text =
                try In_channel.with_open_text path In_channel.input_all
                with _ -> old_text
              in
              if old_text = new_text then
                Buffer.set_disk_changed tab.buf false
              else begin
                match reload_tab ~keep_verified:true t tab path with
                | Region_buffer.Applied ->
                  events := Reloaded path :: !events
                | Region_buffer.Rejected _ ->
                  events := VerifiedAffected path :: !events
              end
            end
          end
        | _ -> ()
      ) tabs
    ) to_process;
    t.deferred <- !still_deferred;
    List.rev !events
  end

let poll t (tabs : Tab.t list) =
  let raw_events = File_watch.poll t.watcher in
  let file_paths = ref [] in
  let project_touched = ref false in
  let sources_touched = ref false in
  let build_touched = ref false in
  List.iter (function
    | File_watch.FileChanged p ->
      if t.project_file_watched = Some p then begin
        project_touched := true;
        sources_touched := true
      end else
        (match List.assoc_opt p t.file_callbacks with
         | Some cb -> (try cb () with _ -> ())
         | None -> file_paths := p :: !file_paths)
    | File_watch.DirEntryAdded { dir; name; is_dir } ->
      if affects_tree_shape name is_dir then begin
        project_touched := true;
        sources_touched := true
      end;
      if affects_build_status name then build_touched := true;
      if is_dir && name <> "" && not (skip_dir name) then begin
        let path = Filename.concat dir name in
        try add_project_subtree t path with _ -> ()
      end
      else if not is_dir && t.project_file_watched = None
              && List.mem name project_file_candidates
              && t.project_dir = Some dir then begin
        let path = Filename.concat dir name in
        File_watch.add_watch t.watcher path;
        t.project_file_watched <- Some path
      end
    | File_watch.DirEntryRemoved { dir; name; is_dir } ->
      if affects_tree_shape name is_dir then begin
        project_touched := true;
        sources_touched := true
      end;
      if affects_build_status name then build_touched := true;
      let path = Filename.concat dir name in
      if t.project_file_watched = Some path then begin
        File_watch.remove_watch t.watcher path;
        t.project_file_watched <- None
      end
    | File_watch.DirEntryModified { name; _ } ->
      (* In-place rewrite. Tree shape can't change. A .v rewrite might
         have changed its Require/Import lines, so rerun rocq dep; a
         .vo rewrite only affects build status. *)
      if affects_build_status name then build_touched := true;
      if Filename.check_suffix name ".v" then sources_touched := true
  ) raw_events;
  let file_events =
    if !file_paths = [] && t.deferred = [] then []
    else process_file_changes t tabs (List.rev !file_paths)
  in
  let extras =
    (if !project_touched then [ProjectChanged] else [])
    @ (if !sources_touched then [SourcesChanged] else [])
    @ (if !build_touched then [BuildArtifactChanged] else [])
  in
  file_events @ extras
