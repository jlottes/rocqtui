open Rocqtui_lib

let split_path f =
  let rec aux acc f =
    let base = Filename.basename f in
    let dir = Filename.dirname f in
    if dir = f || base = "" then base :: acc
    else aux (base :: acc) dir
  in
  aux [] f

let name_of_parts parts n =
  let len = List.length parts in
  let start = max 0 (len - n) in
  let selected = List.filteri (fun i _ -> i >= start) parts in
  String.concat "/" selected

let assert_eq msg a b =
  if a <> b then begin
    Printf.printf "FAIL: %s\n  expected: %s\n  got:      %s\n" msg b a;
    exit 1
  end else
    Printf.printf "OK: %s\n" msg

let () =
  (* Test split_path *)
  let s = split_path "/test/project/interfaces/notation.v" in
  assert_eq "split components"
    (String.concat "|" s)
    "/|test|project|interfaces|notation.v";

  (* Test name_of_parts *)
  assert_eq "name depth 1" (name_of_parts s 1) "notation.v";
  assert_eq "name depth 2" (name_of_parts s 2) "interfaces/notation.v";
  assert_eq "name depth 3" (name_of_parts s 3) "project/interfaces/notation.v";

  let s2 = split_path "/test/project/interfaces/subset/notation.v" in
  assert_eq "name2 depth 1" (name_of_parts s2 1) "notation.v";
  assert_eq "name2 depth 2" (name_of_parts s2 2) "subset/notation.v";

  (* Test display_names via Tab API *)
  let p1 = "/test/project/interfaces/notation.v" in
  let p2 = "/test/project/interfaces/subset/notation.v" in
  let p3 = "/test/project/theory/groups.v" in

  (* Create buffers with filenames set *)
  let make_tab_with_name path =
    let buf = Buffer.create () in
    Buffer.set_filename buf path;
    (* Use create_blank and swap in our buf — but Tab.t.buf is immutable.
       Instead, create_from_file works if file exists. Create temp files. *)
    ignore buf;
    Tab.create_from_file path
  in
  let t1 = make_tab_with_name p1 in
  let t2 = make_tab_with_name p2 in
  let t3 = make_tab_with_name p3 in

  let mgr = Tab.create_manager t1 in
  Tab.add_tab mgr t2;
  Tab.add_tab mgr t3;

  let names = Tab.display_names mgr in
  let name_of t = match List.assoc_opt t.Tab.id names with
    | Some n -> n | None -> "???"
  in
  Printf.printf "t1 display: %s\n" (name_of t1);
  Printf.printf "t2 display: %s\n" (name_of t2);
  Printf.printf "t3 display: %s\n" (name_of t3);

  (* t1 and t2 share basename "notation.v" — should be disambiguated *)
  assert_eq "t1 disambiguated" (name_of t1) "interfaces/notation.v";
  assert_eq "t2 disambiguated" (name_of t2) "subset/notation.v";
  (* t3 is unique — should be just basename *)
  assert_eq "t3 unique" (name_of t3) "groups.v";

  (* Test project_relative_path *)
  let rel = Tab.project_relative_path (Some p1) in
  Printf.printf "project_relative(%s) = %s\n" p1 rel;

  Printf.printf "All tests passed.\n"
