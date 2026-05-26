(* Smoke tests for the inotify-based File_watch.
   Tests rely on a small sleep to let kernel events surface; if they
   ever go flaky on slow CI, raise the wait. *)

open Rocqtui_lib

let wait () = Unix.sleepf 0.1

let mkdtemp prefix =
  let template = Filename.concat (Filename.get_temp_dir_name ())
    (prefix ^ string_of_int (Unix.getpid ()) ^ "_"
     ^ string_of_int (Random.int 1000000)) in
  Unix.mkdir template 0o700;
  template

let rec rm_rf path =
  try
    if Sys.is_directory path then begin
      let entries = Sys.readdir path in
      Array.iter (fun n -> rm_rf (Filename.concat path n)) entries;
      Unix.rmdir path
    end else
      Sys.remove path
  with _ -> ()

let check name cond =
  if cond then Printf.printf "OK: %s\n" name
  else (Printf.printf "FAIL: %s\n" name; exit 1)

let any_match xs f =
  List.exists f xs

let test_dir_watch_create () =
  let dir = mkdtemp "rocqtui_fw_create_" in
  let w = File_watch.create () in
  File_watch.add_dir_watch w dir;
  let f = Filename.concat dir "hello.v" in
  let oc = open_out f in
  output_string oc "Lemma t : True. Proof. trivial. Qed.\n";
  close_out oc;
  wait ();
  let events = File_watch.poll w in
  let saw_add = any_match events (function
    | File_watch.DirEntryAdded { name = "hello.v"; is_dir = false; _ } -> true
    | _ -> false)
  in
  check "DirEntryAdded fires when a file is created" saw_add;
  File_watch.close w;
  rm_rf dir

let test_dir_watch_delete () =
  let dir = mkdtemp "rocqtui_fw_delete_" in
  let f = Filename.concat dir "doomed.v" in
  let oc = open_out f in
  close_out oc;
  let w = File_watch.create () in
  File_watch.add_dir_watch w dir;
  Sys.remove f;
  wait ();
  let events = File_watch.poll w in
  let saw_rm = any_match events (function
    | File_watch.DirEntryRemoved { name = "doomed.v"; _ } -> true
    | _ -> false)
  in
  check "DirEntryRemoved fires when a file is deleted" saw_rm;
  File_watch.close w;
  rm_rf dir

let test_dir_watch_subdir_create () =
  let dir = mkdtemp "rocqtui_fw_subdir_" in
  let w = File_watch.create () in
  File_watch.add_dir_watch w dir;
  let sub = Filename.concat dir "theory" in
  Unix.mkdir sub 0o755;
  wait ();
  let events = File_watch.poll w in
  let saw_subdir = any_match events (function
    | File_watch.DirEntryAdded { name = "theory"; is_dir = true; _ } -> true
    | _ -> false)
  in
  check "DirEntryAdded carries is_dir=true for new subdirectories"
    saw_subdir;
  File_watch.close w;
  rm_rf dir

let test_file_watch_close_write () =
  let dir = mkdtemp "rocqtui_fw_file_" in
  let f = Filename.concat dir "edit.v" in
  let oc = open_out f in
  output_string oc "a";
  close_out oc;
  let w = File_watch.create () in
  File_watch.add_watch w f;
  let oc = open_out f in
  output_string oc "b";
  close_out oc;
  wait ();
  let events = File_watch.poll w in
  let saw = any_match events (function
    | File_watch.FileChanged p when p = f -> true
    | _ -> false)
  in
  check "FileChanged fires when a watched file is rewritten" saw;
  File_watch.close w;
  rm_rf dir

(* Atomic-rename saves over a file-watched path (open buffer scenario).
   The kernel emits MOVE_SELF/DELETE_SELF and IN_IGNORED on the dying
   inode; on some orderings (Claude Code's Edit tool: IGNORED first)
   the IGNORED event must NOT GC the entry before re-attach runs, or
   the next edit goes undetected. Regression for the May 13 dir-watch
   commit. *)
let test_file_watch_atomic_rename () =
  let dir = mkdtemp "rocqtui_fw_atomic_file_" in
  let target = Filename.concat dir "buf.v" in
  let tmp1 = Filename.concat dir "buf.v.tmp1" in
  let tmp2 = Filename.concat dir "buf.v.tmp2" in
  let write_then_rename src content =
    let oc = open_out src in
    output_string oc content;
    close_out oc;
    Sys.rename src target
  in
  write_then_rename tmp1 "v0\n";
  let w = File_watch.create () in
  File_watch.add_watch w target;
  (* First atomic rename — old inode dies, watch must re-attach. *)
  write_then_rename tmp1 "v1\n";
  wait ();
  let events1 = File_watch.poll w in
  let saw1 = any_match events1 (function
    | File_watch.FileChanged p when p = target -> true
    | _ -> false)
  in
  check "first atomic rename of file-watched path yields FileChanged"
    saw1;
  (* Second atomic rename — only fires if the watch was re-attached. *)
  write_then_rename tmp2 "v2\n";
  wait ();
  let events2 = File_watch.poll w in
  let saw2 = any_match events2 (function
    | File_watch.FileChanged p when p = target -> true
    | _ -> false)
  in
  check
    "second atomic rename of file-watched path also yields FileChanged"
    saw2;
  File_watch.close w;
  rm_rf dir

(* Atomic-rename saves (vim, many editors) swap a tmp file onto the
   target inode. This both kills the old file-watch (IN_DELETE_SELF)
   and fires a dir-event (IN_MOVED_TO). Either is enough for one
   ProjectChanged; but the file-watch's re-attach logic must work so
   the NEXT atomic save also fires. *)
let test_project_file_atomic_rename () =
  let dir = mkdtemp "rocqtui_fw_atomic_" in
  let pf = Filename.concat dir "_RocqProject" in
  let tmp = Filename.concat dir "_RocqProject.tmp" in
  let write_then_rename content =
    let oc = open_out tmp in
    output_string oc content;
    close_out oc;
    Sys.rename tmp pf
  in
  write_then_rename "-R . Foo\n";
  let fm = File_manager.create () in
  File_manager.set_project_dir fm dir;
  (* First atomic rename — replaces the inode set_project_dir watched *)
  write_then_rename "-R . Foo\n-Q theory Bar\n";
  wait ();
  let events1 = File_manager.poll fm [] in
  let saw1 = any_match events1 (function
    | File_manager.ProjectChanged -> true
    | _ -> false)
  in
  check "first atomic rename of _RocqProject yields ProjectChanged" saw1;
  (* Second atomic rename — only works if the watch was re-attached *)
  write_then_rename "-R . Foo\n-Q theory Bar\n-Q util Baz\n";
  wait ();
  let events2 = File_manager.poll fm [] in
  let saw2 = any_match events2 (function
    | File_manager.ProjectChanged -> true
    | _ -> false)
  in
  check "second atomic rename of _RocqProject also yields ProjectChanged"
    saw2;
  File_manager.close fm;
  rm_rf dir

(* File_manager.set_project_dir should pick up edits to _RocqProject
   and surface them as ProjectChanged events. *)
let test_project_file_content_change () =
  let dir = mkdtemp "rocqtui_fw_pf_" in
  let pf = Filename.concat dir "_RocqProject" in
  let oc = open_out pf in
  output_string oc "-R . Foo\n";
  close_out oc;
  let fm = File_manager.create () in
  File_manager.set_project_dir fm dir;
  (* Edit the project file *)
  let oc = open_out pf in
  output_string oc "-R . Foo\n-Q theory Bar\n";
  close_out oc;
  wait ();
  let events = File_manager.poll fm [] in
  let saw = any_match events (function
    | File_manager.ProjectChanged -> true
    | _ -> false)
  in
  check "editing _RocqProject surfaces ProjectChanged" saw;
  File_manager.close fm;
  rm_rf dir

(* IN_CLOSE_WRITE on the dir watch must fire DirEntryModified when an
   existing file inside the directory is rewritten (the typical
   [rocqc] in-place .vo clobber). Pure creation already fires
   DirEntryAdded; this catches the "file already there" case. *)
let test_dir_watch_modify () =
  let dir = mkdtemp "rocqtui_fw_mod_" in
  let f = Filename.concat dir "edit.vo" in
  let oc = open_out f in
  output_string oc "v0";
  close_out oc;
  let w = File_watch.create () in
  File_watch.add_dir_watch w dir;
  let oc = open_out f in
  output_string oc "v1";
  close_out oc;
  wait ();
  let events = File_watch.poll w in
  let saw_mod = any_match events (function
    | File_watch.DirEntryModified { name = "edit.vo"; _ } -> true
    | _ -> false)
  in
  check "DirEntryModified fires when a file in a watched dir is rewritten"
    saw_mod;
  File_watch.close w;
  rm_rf dir

(* File_manager should surface BuildArtifactChanged when a .vo is
   written inside a watched project subdirectory — both for new
   files (DirEntryAdded) and in-place rewrites (DirEntryModified).
   The new-file case must NOT also fire ProjectChanged (it's a build
   artifact, not a tree-shape change). *)
let test_build_artifact_create () =
  let dir = mkdtemp "rocqtui_fw_ba_create_" in
  let fm = File_manager.create () in
  File_manager.set_project_dir fm dir;
  let vo = Filename.concat dir "foo.vo" in
  let oc = open_out vo in
  output_string oc "stub";
  close_out oc;
  wait ();
  let events = File_manager.poll fm [] in
  let saw_build = any_match events (function
    | File_manager.BuildArtifactChanged -> true
    | _ -> false)
  in
  let saw_project = any_match events (function
    | File_manager.ProjectChanged -> true
    | _ -> false)
  in
  check "creating a .vo fires BuildArtifactChanged" saw_build;
  check "creating a .vo does NOT fire ProjectChanged"
    (not saw_project);
  File_manager.close fm;
  rm_rf dir

let test_build_artifact_rewrite () =
  let dir = mkdtemp "rocqtui_fw_ba_rewrite_" in
  let vo = Filename.concat dir "foo.vo" in
  let oc = open_out vo in
  output_string oc "v0";
  close_out oc;
  let fm = File_manager.create () in
  File_manager.set_project_dir fm dir;
  let oc = open_out vo in
  output_string oc "v1";
  close_out oc;
  wait ();
  let events = File_manager.poll fm [] in
  let saw_build = any_match events (function
    | File_manager.BuildArtifactChanged -> true
    | _ -> false)
  in
  check "in-place .vo rewrite fires BuildArtifactChanged" saw_build;
  File_manager.close fm;
  rm_rf dir

(* External .v edits should surface BuildArtifactChanged (their mtime
   advancing past their .vo's makes them Stale) AND SourcesChanged
   (Require/Import lines might have changed, so the dep graph needs
   rerunning). They should NOT fire ProjectChanged — the tree shape
   didn't change. *)
let test_build_artifact_v_modified () =
  let dir = mkdtemp "rocqtui_fw_ba_v_" in
  let v = Filename.concat dir "foo.v" in
  let oc = open_out v in
  output_string oc "Lemma t : True. Proof. trivial. Qed.\n";
  close_out oc;
  let fm = File_manager.create () in
  File_manager.set_project_dir fm dir;
  let oc = open_out v in
  output_string oc "Lemma t : True. Proof. exact I. Qed.\n";
  close_out oc;
  wait ();
  let events = File_manager.poll fm [] in
  let saw_build = any_match events (function
    | File_manager.BuildArtifactChanged -> true
    | _ -> false)
  in
  let saw_sources = any_match events (function
    | File_manager.SourcesChanged -> true
    | _ -> false)
  in
  let saw_project = any_match events (function
    | File_manager.ProjectChanged -> true
    | _ -> false)
  in
  check "external .v edit fires BuildArtifactChanged" saw_build;
  check "external .v edit fires SourcesChanged" saw_sources;
  check "external .v edit does NOT fire ProjectChanged"
    (not saw_project);
  File_manager.close fm;
  rm_rf dir

(* .vo writes must NOT fire SourcesChanged — that's the core fix for
   the "every compile reruns rocq dep" problem. *)
let test_vo_does_not_fire_sources_changed () =
  let dir = mkdtemp "rocqtui_fw_vo_no_sources_" in
  let fm = File_manager.create () in
  File_manager.set_project_dir fm dir;
  let vo = Filename.concat dir "foo.vo" in
  (* Create then rewrite — cover both DirEntryAdded and DirEntryModified. *)
  let oc = open_out vo in output_string oc "v0"; close_out oc;
  let oc = open_out vo in output_string oc "v1"; close_out oc;
  wait ();
  let events = File_manager.poll fm [] in
  let saw_sources = any_match events (function
    | File_manager.SourcesChanged -> true
    | _ -> false)
  in
  check ".vo create / rewrite does NOT fire SourcesChanged"
    (not saw_sources);
  File_manager.close fm;
  rm_rf dir

(* The build by-products [make] sprays around (.glob alongside every
   .vo, .vos/.vok in -native modes) must not trigger ProjectChanged
   — otherwise every compile would rerun [rocq dep]. *)
let test_glob_does_not_fire_project_changed () =
  let dir = mkdtemp "rocqtui_fw_glob_" in
  let fm = File_manager.create () in
  File_manager.set_project_dir fm dir;
  List.iter (fun ext ->
    let p = Filename.concat dir ("foo" ^ ext) in
    let oc = open_out p in
    output_string oc "x";
    close_out oc
  ) [".glob"; ".vos"; ".vok"];
  wait ();
  let events = File_manager.poll fm [] in
  let saw_project = any_match events (function
    | File_manager.ProjectChanged -> true
    | _ -> false)
  in
  check ".glob / .vos / .vok writes do not fire ProjectChanged"
    (not saw_project);
  File_manager.close fm;
  rm_rf dir

(* A burst of .vo writes (parallel make) should collapse to one
   BuildArtifactChanged per poll. *)
let test_build_artifact_coalesced () =
  let dir = mkdtemp "rocqtui_fw_ba_coalesce_" in
  let fm = File_manager.create () in
  File_manager.set_project_dir fm dir;
  for i = 1 to 5 do
    let vo = Filename.concat dir (Printf.sprintf "f%d.vo" i) in
    let oc = open_out vo in
    output_string oc "x";
    close_out oc
  done;
  wait ();
  let events = File_manager.poll fm [] in
  let n_build = List.length (List.filter (function
    | File_manager.BuildArtifactChanged -> true
    | _ -> false) events)
  in
  check "five .vo writes coalesce to a single BuildArtifactChanged"
    (n_build = 1);
  File_manager.close fm;
  rm_rf dir

let () =
  Random.self_init ();
  test_dir_watch_create ();
  test_dir_watch_delete ();
  test_dir_watch_subdir_create ();
  test_dir_watch_modify ();
  test_file_watch_close_write ();
  test_file_watch_atomic_rename ();
  test_project_file_content_change ();
  test_project_file_atomic_rename ();
  test_build_artifact_create ();
  test_build_artifact_rewrite ();
  test_build_artifact_v_modified ();
  test_vo_does_not_fire_sources_changed ();
  test_glob_does_not_fire_project_changed ();
  test_build_artifact_coalesced ()
