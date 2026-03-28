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
                 /home/jlottes/.opam/rocq/lib/coq/theories/Init/Nat.vo" in
  (match Locate.parse_locate_library lib_msg with
   | Some vo ->
     assert_eq "locate lib path" vo
       "/home/jlottes/.opam/rocq/lib/coq/theories/Init/Nat.vo"
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

  (* Test glob parser *)
  let glob_path = "/home/jlottes/rocq/affine/theory/groups.glob" in
  if Sys.file_exists glob_path then begin
    let entries = Glob.parse glob_path in
    Printf.printf "Parsed %d glob entries\n" (List.length entries);
    (match Glob.find_definition entries "alt_Build_Group" with
     | Some e ->
       Printf.printf "OK: found alt_Build_Group at %d:%d (kind=%s)\n"
         e.bp e.ep e.kind
     | None -> Printf.printf "FAIL: alt_Build_Group not found in glob\n"; exit 1);
    (* Test byte_offset_to_line *)
    let v_path = "/home/jlottes/rocq/affine/theory/groups.v" in
    if Sys.file_exists v_path then begin
      match Glob.find_definition entries "alt_Build_Group" with
      | Some e ->
        (match Glob.byte_offset_to_line v_path e.bp with
         | Some line ->
           Printf.printf "OK: alt_Build_Group is on line %d\n" (line + 1)
         | None -> Printf.printf "FAIL: byte_offset_to_line\n"; exit 1)
      | None -> ()
    end
  end else
    Printf.printf "SKIP: glob file not found\n";

  Printf.printf "All tests passed.\n"
