open Rocqtui_lib

let assert_eq msg a b =
  if a <> b then begin
    Printf.printf "FAIL: %s\n  expected: %s\n  got:      %s\n" msg b a;
    exit 1
  end else
    Printf.printf "OK: %s\n" msg

let () =
  (* Test parse_locate *)
  (match Locate.parse_locate "Constant Corelib.Init.Nat.add" with
   | Some (kind, modpath, name) ->
     assert_eq "locate kind" kind "Constant";
     assert_eq "locate module" modpath "Corelib.Init.Nat";
     assert_eq "locate name" name "add"
   | None -> Printf.printf "FAIL: parse_locate returned None\n"; exit 1);

  (match Locate.parse_locate "Inductive Corelib.Init.Datatypes.nat" with
   | Some (kind, modpath, name) ->
     assert_eq "locate ind kind" kind "Inductive";
     assert_eq "locate ind module" modpath "Corelib.Init.Datatypes";
     assert_eq "locate ind name" name "nat"
   | None -> Printf.printf "FAIL: parse_locate ind returned None\n"; exit 1);

  (* Test parse_locate_library *)
  let lib_msg = "Corelib.Init.Nat has been loaded from file\n\
                 /opt/rocq/lib/coq/theories/Init/Nat.vo" in
  (match Locate.parse_locate_library lib_msg with
   | Some vo ->
     assert_eq "locate lib path" vo
       "/opt/rocq/lib/coq/theories/Init/Nat.vo"
   | None -> Printf.printf "FAIL: parse_locate_library returned None\n"; exit 1);

  (* Test vo_to_v, vo_to_glob *)
  assert_eq "vo_to_v" (Locate.vo_to_v "/foo/bar.vo") "/foo/bar.v";
  assert_eq "vo_to_glob" (Locate.vo_to_glob "/foo/bar.vo") "/foo/bar.glob";

  (* Test parse_require_line *)
  (match Locate.parse_require_line "Require Import Foo Bar." with
   | Some (None, modules) ->
     let names = List.map (fun (n, _, _) -> n) modules in
     assert_eq "require modules" (String.concat "," names) "Foo,Bar"
   | _ -> Printf.printf "FAIL: parse_require_line 1\n"; exit 1);

  (match Locate.parse_require_line "From MyLib Require Import Foo Bar." with
   | Some (Some prefix, modules) ->
     assert_eq "from prefix" prefix "MyLib";
     let names = List.map (fun (n, _, _) -> n) modules in
     assert_eq "from modules" (String.concat "," names) "MyLib.Foo,MyLib.Bar"
   | _ -> Printf.printf "FAIL: parse_require_line 2\n"; exit 1);

  (match Locate.parse_require_line "Lemma foo : True." with
   | None -> Printf.printf "OK: non-require returns None\n"
   | Some _ -> Printf.printf "FAIL: non-require matched\n"; exit 1);

  (* Test module_at_col *)
  (match Locate.parse_require_line "Require Import Foo Bar." with
   | Some (_, modules) ->
     (match Locate.module_at_col modules 16 with
      | Some m -> assert_eq "col on Foo" m "Foo"
      | None -> Printf.printf "FAIL: module_at_col Foo\n"; exit 1);
     (match Locate.module_at_col modules 20 with
      | Some m -> assert_eq "col on Bar" m "Bar"
      | None -> Printf.printf "FAIL: module_at_col Bar\n"; exit 1)
   | _ -> Printf.printf "FAIL: parse for col test\n"; exit 1);

  (* Test glob parser against a real .glob file if available.
     Set ROCQTUI_TEST_GLOB to a .glob path (with .v alongside) and
     ROCQTUI_TEST_GLOB_DEF to the name of a definition in that file. *)
  let glob_path = try Sys.getenv "ROCQTUI_TEST_GLOB" with Not_found -> "" in
  let glob_def = try Sys.getenv "ROCQTUI_TEST_GLOB_DEF" with Not_found -> "" in
  if glob_path <> "" && glob_def <> "" && Sys.file_exists glob_path then begin
    let entries = Glob.parse glob_path in
    Printf.printf "Parsed %d glob entries\n" (List.length entries);
    (match Glob.find_definition entries glob_def with
     | Some e ->
       Printf.printf "OK: found %s at %d:%d (kind=%s)\n"
         glob_def e.bp e.ep e.kind
     | None -> Printf.printf "FAIL: %s not found in glob\n" glob_def; exit 1);
    let v_path = Filename.chop_suffix glob_path ".glob" ^ ".v" in
    if Sys.file_exists v_path then begin
      match Glob.find_definition entries glob_def with
      | Some e ->
        (match Glob.byte_offset_to_line v_path e.bp with
         | Some line ->
           Printf.printf "OK: %s is on line %d\n" glob_def (line + 1)
         | None -> Printf.printf "FAIL: byte_offset_to_line\n"; exit 1)
      | None -> ()
    end
  end else
    Printf.printf "SKIP: glob file not configured\n";

  Printf.printf "All tests passed.\n"
