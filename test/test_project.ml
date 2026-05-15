(* Unit tests for the Project module: parsing, membership lookup, and
   the comment/uncomment/insert behaviour of toggle_member.

   Each test uses a fresh tmp dir + _RocqProject. *)

open Rocqtui_lib

let check name cond =
  if cond then Printf.printf "OK: %s\n" name
  else (Printf.printf "FAIL: %s\n" name; exit 1)

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

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let read_all path =
  In_channel.with_open_text path In_channel.input_all

let test_basic_parse () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  write path "# header comment\n\
              -R theories Top\n\
              -arg -w\n\
              -arg \"-foo -bar\"\n\
              -nois\n\
              \n\
              theories/Foo.v\n\
              # theories/Bar.v\n\
              theories/Baz.v\n";
  let p = Project.read path in
  check "basic_parse: project_dir" (p.project_dir = dir);
  check "basic_parse: one load_path"
    (List.length p.load_paths = 1);
  let lp = List.hd p.load_paths in
  check "basic_parse: load_path implicit (-R)" lp.implicit;
  check "basic_parse: load_path logical_prefix"
    (lp.logical_prefix = "Top");
  check "basic_parse: load_path physical_dir resolved"
    (lp.physical_dir = Filename.concat dir "theories");
  check "basic_parse: listed_files skips commented"
    (List.length p.listed_files = 2);
  check "basic_parse: listed_files Foo absolute"
    (List.mem (Filename.concat dir "theories/Foo.v") p.listed_files);
  check "basic_parse: listed_files Baz absolute"
    (List.mem (Filename.concat dir "theories/Baz.v") p.listed_files);
  check "basic_parse: -arg with embedded space splits"
    (List.mem "-foo" p.args && List.mem "-bar" p.args);
  check "basic_parse: -nois bare flag preserved"
    (List.mem "-nois" p.args);
  rm_rf dir

let test_membership () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  write path "-R . Top\n\
              theories/Foo.v\n\
              # theories/Bar.v\n";
  let p = Project.read path in
  check "membership: active" (Project.membership p ~rel:"theories/Foo.v" = `Active);
  check "membership: commented" (Project.membership p ~rel:"theories/Bar.v" = `Commented);
  check "membership: absent" (Project.membership p ~rel:"theories/Baz.v" = `Absent);
  rm_rf dir

let test_toggle_active_to_commented () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  write path "-R . Top\ntheories/Foo.v\n";
  let p = Project.read path in
  let (p', outcome) = Project.toggle_member p ~rel:"theories/Foo.v" in
  check "toggle_active: outcome=Removed" (outcome = `Removed);
  check "toggle_active: membership now Commented"
    (Project.membership p' ~rel:"theories/Foo.v" = `Commented);
  check "toggle_active: file content has commented line"
    (read_all path = "-R . Top\n# theories/Foo.v\n");
  rm_rf dir

let test_toggle_commented_to_active () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  write path "-R . Top\n# theories/Foo.v\n";
  let p = Project.read path in
  let (p', outcome) = Project.toggle_member p ~rel:"theories/Foo.v" in
  check "toggle_commented: outcome=Added" (outcome = `Added);
  check "toggle_commented: membership now Active"
    (Project.membership p' ~rel:"theories/Foo.v" = `Active);
  check "toggle_commented: file content has uncommented line"
    (read_all path = "-R . Top\ntheories/Foo.v\n");
  rm_rf dir

let test_toggle_absent_sorted_insert () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  (* Existing entries are already alphabetical; inserting "Baz.v"
     should land between Apple and Cat. *)
  write path "-R . Top\ntheories/Apple.v\ntheories/Cat.v\n";
  let p = Project.read path in
  let (_, outcome) = Project.toggle_member p ~rel:"theories/Baz.v" in
  check "toggle_absent: outcome=Added" (outcome = `Added);
  check "toggle_absent: inserted between Apple and Cat"
    (read_all path =
     "-R . Top\ntheories/Apple.v\ntheories/Baz.v\ntheories/Cat.v\n");
  rm_rf dir

let test_toggle_absent_append () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  (* "Zap.v" sorts after every existing entry, so it lands at the end. *)
  write path "-R . Top\ntheories/Apple.v\ntheories/Cat.v\n";
  let p = Project.read path in
  let (_, outcome) = Project.toggle_member p ~rel:"theories/Zap.v" in
  check "toggle_absent_append: outcome=Added" (outcome = `Added);
  check "toggle_absent_append: appended after last v line"
    (read_all path =
     "-R . Top\ntheories/Apple.v\ntheories/Cat.v\ntheories/Zap.v\n");
  rm_rf dir

let test_toggle_absent_no_v_lines () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  write path "-R . Top\n";
  let p = Project.read path in
  let (_, _) = Project.toggle_member p ~rel:"theories/Foo.v" in
  check "toggle_absent_no_v: appended at end of file"
    (read_all path = "-R . Top\ntheories/Foo.v\n");
  rm_rf dir

let test_toggle_preserves_unchanged_lines () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  let original =
    "# header comment\n\
     -R theories Top\n\
     -arg -w\n\
     \n\
     theories/Foo.v\n\
     theories/Bar.v\n" in
  write path original;
  let p = Project.read path in
  let (_, _) = Project.toggle_member p ~rel:"theories/Foo.v" in
  check "toggle_preserves: other lines round-trip verbatim"
    (read_all path =
     "# header comment\n\
      -R theories Top\n\
      -arg -w\n\
      \n\
      # theories/Foo.v\n\
      theories/Bar.v\n");
  rm_rf dir

let test_rename_active () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  write path "-R . Top\ntheories/Foo.v\ntheories/Bar.v\n";
  let p = Project.read path in
  let (_, outcome) = Project.rename_member p
    ~old_rel:"theories/Foo.v" ~new_rel:"theories/Renamed.v" in
  check "rename_active: outcome=Renamed" (outcome = `Renamed);
  check "rename_active: file content updated"
    (read_all path =
     "-R . Top\ntheories/Renamed.v\ntheories/Bar.v\n");
  rm_rf dir

let test_rename_commented () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  write path "-R . Top\n# theories/Foo.v\n";
  let p = Project.read path in
  let (_, outcome) = Project.rename_member p
    ~old_rel:"theories/Foo.v" ~new_rel:"lib/Bar.v" in
  check "rename_commented: outcome=Renamed" (outcome = `Renamed);
  check "rename_commented: comment preserved"
    (read_all path = "-R . Top\n# lib/Bar.v\n");
  rm_rf dir

let test_rename_not_listed () =
  let dir = mkdtemp "rocqtui_proj_" in
  let path = Filename.concat dir "_RocqProject" in
  let original = "-R . Top\ntheories/Foo.v\n" in
  write path original;
  let p = Project.read path in
  let (_, outcome) = Project.rename_member p
    ~old_rel:"theories/Missing.v" ~new_rel:"theories/Other.v" in
  check "rename_not_listed: outcome=NotListed" (outcome = `NotListed);
  check "rename_not_listed: file untouched"
    (read_all path = original);
  rm_rf dir

let () =
  test_basic_parse ();
  test_membership ();
  test_toggle_active_to_commented ();
  test_toggle_commented_to_active ();
  test_toggle_absent_sorted_insert ();
  test_toggle_absent_append ();
  test_toggle_absent_no_v_lines ();
  test_toggle_preserves_unchanged_lines ();
  test_rename_active ();
  test_rename_commented ();
  test_rename_not_listed ();
  print_endline "All tests passed."
