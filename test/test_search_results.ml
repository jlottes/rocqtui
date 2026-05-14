open Rocqtui_lib

let check name cond =
  if cond then Printf.printf "OK: %s\n" name
  else (Printf.printf "FAIL: %s\n" name; exit 1)

let mk_match line text col_s col_e =
  { Search_results.ml_line = line;
    ml_col_start = col_s; ml_col_end = col_e;
    ml_line_text = text }

let mk_fm path matches =
  { Search_results.fm_path = path; fm_rel_path = path;
    fm_matches = Array.of_list matches }

let flags = Search.empty_flags

let test_empty () =
  let r = Search_results.empty ~query:"foo" ~flags in
  check "empty: total = 0" (Search_results.total r = 0);
  check "empty: scanning = false" (not (Search_results.scanning r));
  check "empty: files = []" (Search_results.files r = []);
  check "empty: current = None" (Search_results.current r = None);
  check "empty: advance returns None"
    (Search_results.advance r ~forward:true = None)

let test_add_file () =
  let r = Search_results.empty ~query:"foo" ~flags in
  Search_results.add_file r (mk_fm "a.v" [mk_match 1 "foo" 0 3]);
  Search_results.add_file r (mk_fm "b.v" [
    mk_match 2 "foo bar" 0 3;
    mk_match 5 "more foo" 5 8;
  ]);
  check "add_file: total counted" (Search_results.total r = 3);
  check "add_file: files preserved in order"
    (List.map (fun f -> f.Search_results.fm_path)
       (Search_results.files r) = ["a.v"; "b.v"]);
  (* Empty matches array — no-op *)
  Search_results.add_file r (mk_fm "c.v" []);
  check "add_file: empty matches not added"
    (List.length (Search_results.files r) = 2)

let path_of (p, _m) = p
let line_of (_p, (m : Search_results.match_loc)) = m.ml_line

let test_advance_wrap () =
  let r = Search_results.empty ~query:"foo" ~flags in
  Search_results.add_file r (mk_fm "a.v" [
    mk_match 1 "foo" 0 3;
    mk_match 2 "foo" 0 3;
  ]);
  Search_results.add_file r (mk_fm "b.v" [mk_match 5 "foo" 0 3]);
  (* From None, forward → first match (a.v line 1) *)
  let r1 = Search_results.advance r ~forward:true in
  check "advance forward from None: a.v:1"
    (match r1 with
     | Some (p, m) -> p = "a.v" && m.ml_line = 1
     | None -> false);
  (* Step forward: a.v line 2 *)
  let r2 = Search_results.advance r ~forward:true in
  check "advance forward 2nd: a.v:2"
    (match r2 with
     | Some (p, m) -> p = "a.v" && m.ml_line = 2
     | None -> false);
  (* Step forward: cross file to b.v *)
  let r3 = Search_results.advance r ~forward:true in
  check "advance forward 3rd: b.v:5"
    (match r3 with
     | Some (p, m) -> p = "b.v" && m.ml_line = 5
     | None -> false);
  (* Step forward: wrap to a.v line 1 *)
  let r4 = Search_results.advance r ~forward:true in
  check "advance forward wraps: a.v:1"
    (match r4 with
     | Some (p, m) -> p = "a.v" && m.ml_line = 1
     | None -> false);
  (* Step backward from a.v line 1: wrap to b.v line 5 *)
  let r5 = Search_results.advance r ~forward:false in
  check "advance backward wraps: b.v:5"
    (match r5 with
     | Some (p, m) -> p = "b.v" && m.ml_line = 5
     | None -> false);
  ignore (path_of, line_of)

let test_advance_from_None_backward () =
  let r = Search_results.empty ~query:"foo" ~flags in
  Search_results.add_file r (mk_fm "a.v" [
    mk_match 1 "foo" 0 3;
    mk_match 7 "foo" 0 3;
  ]);
  (* From None, backward → last match *)
  let res = Search_results.advance r ~forward:false in
  check "advance backward from None: a.v:7"
    (match res with
     | Some (p, m) -> p = "a.v" && m.ml_line = 7
     | None -> false)

let test_find_match () =
  let r = Search_results.empty ~query:"foo" ~flags in
  Search_results.add_file r (mk_fm "a.v" [
    mk_match 1 "foo" 0 3;
    mk_match 2 "foo" 0 3;
  ]);
  check "find_match: valid index"
    (match Search_results.find_match r "a.v" 1 with
     | Some m -> m.ml_line = 2
     | None -> false);
  check "find_match: out-of-range index"
    (Search_results.find_match r "a.v" 99 = None);
  check "find_match: unknown path"
    (Search_results.find_match r "z.v" 0 = None)

(* of_single_file: derive from Search.state + Buffer *)
let test_of_single_file () =
  let buf = Buffer.create () in
  Buffer.Unsafe.set_text buf "Lemma foo : True.\nProof. apply foo. Qed.\n";
  let s = Search.create buf in
  let s = Search.update_query s buf "foo" in
  let r = Search_results.of_single_file
    ~path:"/abs/a.v" ~rel_path:"a.v" s buf in
  check "of_single_file: total = matches in buf"
    (Search_results.total r = 2);
  check "of_single_file: one file entry"
    (List.length (Search_results.files r) = 1);
  let fm = List.hd (Search_results.files r) in
  check "of_single_file: line text materialized"
    (fm.fm_matches.(0).ml_line_text = "Lemma foo : True.");
  check "of_single_file: 1-based line"
    (fm.fm_matches.(0).ml_line = 1);
  check "of_single_file: col_start matches"
    (fm.fm_matches.(0).ml_col_start = 6);  (* "Lemma " is 6 bytes *)
  (* current should be set if s.current >= 0 *)
  check "of_single_file: current set from state"
    (Search_results.current r = Some ("/abs/a.v", 0))

let () =
  test_empty ();
  test_add_file ();
  test_advance_wrap ();
  test_advance_from_None_backward ();
  test_find_match ();
  test_of_single_file ()
