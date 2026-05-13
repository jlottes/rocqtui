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

let () =
  Random.self_init ();
  test_dir_watch_create ();
  test_dir_watch_delete ();
  test_dir_watch_subdir_create ();
  test_file_watch_close_write ();
  test_project_file_content_change ();
  test_project_file_atomic_rename ()
