open Rocqtui_lib

let load text =
  let buf = Buffer.create () in
  Buffer.Unsafe.set_text buf text;
  buf

let load_at text ~line ~col =
  let buf = load text in
  Buffer.move_to buf line col;
  buf

let p line col = Search.{ line; col }

let pass = ref 0
let fail = ref 0

let ok label =
  incr pass;
  Printf.printf "OK   %s\n" label

let bad label msg =
  incr fail;
  Printf.printf "FAIL %s: %s\n" label msg

let check_eq label ~expected ~got show =
  if expected = got then ok label
  else bad label (Printf.sprintf "got %s expected %s" (show got) (show expected))

let show_int n = string_of_int n
let show_pos (p : Search.pos) = Printf.sprintf "(%d,%d)" p.line p.col
let show_match (m : Search.match_) =
  Printf.sprintf "[%s..%s]" (show_pos m.start_) (show_pos m.end_)
let show_matches ms =
  "[" ^ String.concat ", " (Array.to_list (Array.map show_match ms)) ^ "]"

(* ------------------------------------------------------------------ *)

let test_empty_query () =
  let buf = load "hello world" in
  let s = Search.create buf in
  let s = Search.update_query s buf "" in
  check_eq "empty query: no matches" ~expected:0
    ~got:(Array.length s.matches) show_int;
  check_eq "empty query: current = -1" ~expected:(-1)
    ~got:s.current show_int

let test_basic_literal () =
  let buf = load "foo bar foo baz foo" in
  let s = Search.create buf in
  let s = Search.update_query s buf "foo" in
  check_eq "literal: 3 matches" ~expected:3
    ~got:(Array.length s.matches) show_int;
  check_eq "literal: first match position" ~expected:(p 0 0)
    ~got:s.matches.(0).start_ show_pos;
  check_eq "literal: third match end" ~expected:(p 0 19)
    ~got:s.matches.(2).end_ show_pos

let test_no_match () =
  let buf = load "hello world" in
  let s = Search.create buf in
  let s = Search.update_query s buf "xyz" in
  check_eq "no match: empty array" ~expected:0
    ~got:(Array.length s.matches) show_int;
  check_eq "no match: current = -1" ~expected:(-1) ~got:s.current show_int

let test_smart_case_insensitive () =
  let buf = load "Foo FOO foo" in
  let s = Search.create buf in
  let s = Search.update_query s buf "foo" in
  check_eq "smart-case: lowercase query matches all 3" ~expected:3
    ~got:(Array.length s.matches) show_int

let test_smart_case_sensitive () =
  let buf = load "Foo FOO foo" in
  let s = Search.create buf in
  let s = Search.update_query s buf "Foo" in
  check_eq "smart-case: uppercase query matches only Foo" ~expected:1
    ~got:(Array.length s.matches) show_int;
  check_eq "smart-case: uppercase finds 'Foo' at col 0"
    ~expected:(p 0 0) ~got:s.matches.(0).start_ show_pos

let test_forced_sensitive () =
  let buf = load "Foo FOO foo" in
  let s = Search.create buf in
  let s = Search.set_flags s buf { Search.case = Sensitive; regex = false } in
  let s = Search.update_query s buf "foo" in
  check_eq "sensitive: lowercase matches only 'foo'" ~expected:1
    ~got:(Array.length s.matches) show_int;
  check_eq "sensitive: matches at col 8"
    ~expected:(p 0 8) ~got:s.matches.(0).start_ show_pos

let test_regex_basic () =
  let buf = load "foo123 bar45 baz9" in
  let s = Search.create buf in
  let s = Search.set_flags s buf { Search.case = Smart; regex = true } in
  let s = Search.update_query s buf "[a-z]+\\d+" in
  check_eq "regex: 3 matches" ~expected:3
    ~got:(Array.length s.matches) show_int

let test_regex_invalid () =
  let buf = load "hello" in
  let s = Search.create buf in
  let s = Search.set_flags s buf { Search.case = Smart; regex = true } in
  let s = Search.update_query s buf "[unclosed" in
  check_eq "invalid regex: 0 matches (silent)" ~expected:0
    ~got:(Array.length s.matches) show_int

let test_literal_metachars () =
  (* In literal mode, regex metacharacters should be escaped. *)
  let buf = load "a.b a.b axb" in
  let s = Search.create buf in
  let s = Search.update_query s buf "a.b" in
  (* Literal "a.b" matches twice, NOT axb. *)
  check_eq "literal: '.' is literal, not any-char" ~expected:2
    ~got:(Array.length s.matches) show_int

let test_multiline_positions () =
  let buf = load "alpha\nbeta\ngamma alpha" in
  let s = Search.create buf in
  let s = Search.update_query s buf "alpha" in
  check_eq "multiline: 2 matches" ~expected:2
    ~got:(Array.length s.matches) show_int;
  check_eq "multiline: first at (0,0)" ~expected:(p 0 0)
    ~got:s.matches.(0).start_ show_pos;
  check_eq "multiline: second at (2,6)" ~expected:(p 2 6)
    ~got:s.matches.(1).start_ show_pos;
  check_eq "multiline: second end at (2,11)" ~expected:(p 2 11)
    ~got:s.matches.(1).end_ show_pos

let test_initial_current_after_cursor () =
  let buf = load_at "foo bar foo baz" ~line:0 ~col:5 in
  let s = Search.create buf in
  let s = Search.update_query s buf "foo" in
  (* Cursor at col 5 (in "bar"). Next match start is the second "foo" at col 8. *)
  check_eq "initial current: at-or-after saved cursor"
    ~expected:1 ~got:s.current show_int

let test_initial_current_wraps () =
  (* Cursor past last match → wrap to first. *)
  let buf = load_at "foo bar baz" ~line:0 ~col:10 in
  let s = Search.create buf in
  let s = Search.update_query s buf "foo" in
  check_eq "initial current: wraps to first" ~expected:0 ~got:s.current show_int

let test_next_prev_wrap () =
  let buf = load "a a a" in
  let s = Search.create buf in
  let s = Search.update_query s buf "a" in
  check_eq "next/prev: 3 matches" ~expected:3
    ~got:(Array.length s.matches) show_int;
  let s = Search.next s in
  check_eq "next: 0 -> 1" ~expected:1 ~got:s.current show_int;
  let s = Search.next s in
  check_eq "next: 1 -> 2" ~expected:2 ~got:s.current show_int;
  let s = Search.next s in
  check_eq "next: 2 -> 0 (wrap)" ~expected:0 ~got:s.current show_int;
  let s = Search.prev s in
  check_eq "prev: 0 -> 2 (wrap)" ~expected:2 ~got:s.current show_int

let test_next_prev_empty () =
  let buf = load "abc" in
  let s = Search.create buf in
  let s = Search.update_query s buf "xyz" in
  let s' = Search.next s in
  check_eq "next on empty: no change" ~expected:(-1) ~got:s'.current show_int;
  let s' = Search.prev s in
  check_eq "prev on empty: no change" ~expected:(-1) ~got:s'.current show_int

let test_update_after_edit_preserves_current () =
  (* Find three "foo"s, navigate to the second, then "edit" the buffer
     by setting new text that still contains the "foo" at the same line/col.
     update_after_edit should keep current pointing at it. *)
  let buf = load "foo a foo b foo c" in
  let s = Search.create buf in
  let s = Search.update_query s buf "foo" in
  let s = Search.next s in  (* current = 1 *)
  let prev_pos = (Option.get (Search.current_match s)).start_ in
  (* Edit: append text. The match at (0,6) still exists. *)
  Buffer.Unsafe.set_text buf "foo a foo b foo c extra";
  let s = Search.update_after_edit s buf in
  check_eq "after edit: still 3 matches" ~expected:3
    ~got:(Array.length s.matches) show_int;
  check_eq "after edit: current preserved at original position"
    ~expected:prev_pos
    ~got:(Option.get (Search.current_match s)).start_ show_pos

let test_update_after_edit_match_removed () =
  (* If the current match goes away, snap to the first at-or-after the
     anchor. We delete the second "foo" by replacing the text. *)
  let buf = load "foo a foo b foo c" in
  let s = Search.create buf in
  let s = Search.update_query s buf "foo" in
  let s = Search.next s in  (* current = 1 (the middle foo at col 6) *)
  Buffer.Unsafe.set_text buf "foo a XXX b foo c";
  let s = Search.update_after_edit s buf in
  check_eq "after edit: 2 matches remain" ~expected:2
    ~got:(Array.length s.matches) show_int;
  (* Anchor was (0,6); first match at-or-after is now the third foo at (0,12). *)
  check_eq "after edit: snaps to next at-or-after anchor"
    ~expected:(p 0 12)
    ~got:(Option.get (Search.current_match s)).start_ show_pos

let test_toggle_case () =
  let buf = load "Foo foo FOO" in
  let s = Search.create buf in
  let s = Search.update_query s buf "foo" in
  check_eq "smart-case toggle: starts insensitive (3 matches)"
    ~expected:3 ~got:(Array.length s.matches) show_int;
  let s = Search.toggle_case s buf in
  check_eq "after toggle: sensitive (1 match — only lowercase)"
    ~expected:1 ~got:(Array.length s.matches) show_int;
  let s = Search.toggle_case s buf in
  check_eq "after toggle back: smart again (3 matches)"
    ~expected:3 ~got:(Array.length s.matches) show_int

let test_buffer_revision () =
  let buf = Buffer.create () in
  let r0 = Buffer.revision buf in
  Buffer.Unsafe.set_text buf "hello";
  let r1 = Buffer.revision buf in
  check_eq "buffer revision: bumps on set_text" ~expected:true
    ~got:(r1 > r0) string_of_bool;
  Buffer.move_to buf 0 3;  (* cursor move, no content change *)
  check_eq "buffer revision: stable across cursor moves"
    ~expected:r1 ~got:(Buffer.revision buf) string_of_int;
  Buffer.Unsafe.insert_char buf 'x';
  check_eq "buffer revision: bumps on insert_char" ~expected:true
    ~got:(Buffer.revision buf > r1) string_of_bool

let test_tab_search_lazy_refresh () =
  let tab = Tab.create_blank () in
  Buffer.Unsafe.set_text tab.buf "foo bar foo";
  let s = Search.create tab.buf in
  let s = Search.update_query s tab.buf "foo" in
  Tab.set_search tab (Some s);
  let got1 = Option.get (Tab.search_state tab) in
  check_eq "tab search: 2 matches initially"
    ~expected:2 ~got:(Array.length got1.matches) show_int;
  Buffer.Unsafe.set_text tab.buf "foo bar foo foo";
  let got2 = Option.get (Tab.search_state tab) in
  check_eq "tab search: refreshes after edit (3 matches)"
    ~expected:3 ~got:(Array.length got2.matches) show_int;
  (* Reading again with no buffer change must not re-run. *)
  let r_before = Buffer.revision tab.buf in
  let _ = Tab.search_state tab in
  check_eq "tab search: read without edit doesn't bump revision"
    ~expected:r_before ~got:(Buffer.revision tab.buf) string_of_int

let test_tab_search_set_and_clear () =
  let tab = Tab.create_blank () in
  check_eq "tab search: initially None"
    ~expected:true ~got:(Tab.search_state tab = None) string_of_bool;
  let s = Search.create tab.buf in
  Tab.set_search tab (Some s);
  check_eq "tab search: present after set"
    ~expected:true ~got:(Tab.search_state tab <> None) string_of_bool;
  Tab.set_search tab None;
  check_eq "tab search: cleared after set None"
    ~expected:true ~got:(Tab.search_state tab = None) string_of_bool

let test_substitute_literal () =
  let sub = Search.substitute
    ~query:"foo" ~flags:Search.empty_flags
    ~replacement:"bar" ~matched:"foo" in
  check_eq "substitute literal: returns replacement verbatim"
    ~expected:"bar" ~got:sub (fun s -> s);
  (* `$` has no special meaning in literal mode. *)
  let sub = Search.substitute
    ~query:"x" ~flags:Search.empty_flags
    ~replacement:"$1 dollar" ~matched:"x" in
  check_eq "substitute literal: $1 is literal"
    ~expected:"$1 dollar" ~got:sub (fun s -> s)

let test_substitute_regex () =
  let flags = { Search.case = Smart; regex = true } in
  let sub = Search.substitute
    ~query:"(\\w+)@(\\w+)" ~flags
    ~replacement:"$2/$1" ~matched:"alice@example" in
  check_eq "substitute regex: $1/$2 expands"
    ~expected:"example/alice" ~got:sub (fun s -> s);
  let sub = Search.substitute
    ~query:"\\d+" ~flags
    ~replacement:"<$&>" ~matched:"42" in
  check_eq "substitute regex: $& is whole match"
    ~expected:"<42>" ~got:sub (fun s -> s);
  let sub = Search.substitute
    ~query:"x" ~flags
    ~replacement:"$$" ~matched:"x" in
  check_eq "substitute regex: $$ is literal $"
    ~expected:"$" ~got:sub (fun s -> s)

let test_set_replacement_focus () =
  let buf = load "hello" in
  let s = Search.create buf in
  let s = Search.set_replacement s "world" in
  check_eq "set_replacement stores text"
    ~expected:"world" ~got:s.replacement (fun s -> s);
  check_eq "focus defaults to Find"
    ~expected:true ~got:(s.focus = Search.Find) string_of_bool;
  let s = Search.set_focus s Search.Replace in
  check_eq "set_focus to Replace"
    ~expected:true ~got:(s.focus = Search.Replace) string_of_bool

let test_is_case_insensitive () =
  let f = Search.empty_flags in
  check_eq "is_case_insensitive: smart + lowercase => true"
    ~expected:true
    ~got:(Search.is_case_insensitive ~query:"foo" ~flags:f)
    string_of_bool;
  check_eq "is_case_insensitive: smart + uppercase => false"
    ~expected:false
    ~got:(Search.is_case_insensitive ~query:"Foo" ~flags:f)
    string_of_bool;
  let f = { f with Search.case = Sensitive } in
  check_eq "is_case_insensitive: forced sensitive => false"
    ~expected:false
    ~got:(Search.is_case_insensitive ~query:"foo" ~flags:f)
    string_of_bool

(* --- New state model: query_state + buffer_matches --- *)

let q ?(flags=Search.empty_flags) query =
  { Search.query; flags; replacement = ""; focus = Find }

let test_bm_empty_query () =
  let buf = load "hello world" in
  let qs = q "" in
  let bm = Search.recompute_buffer_matches qs buf
    ~anchor:(p 0 0) ~saved_cursor:(p 0 0) in
  check_eq "bm empty query: no matches"
    ~expected:0 ~got:(Array.length bm.matches) show_int;
  check_eq "bm empty query: current = -1"
    ~expected:(-1) ~got:bm.current show_int

let test_bm_anchor_picks_at_or_after () =
  let buf = load "foo bar foo baz foo" in
  let qs = q "foo" in
  let bm = Search.recompute_buffer_matches qs buf
    ~anchor:(p 0 4) ~saved_cursor:(p 0 0) in
  (* anchor (0,4) is after the first match (0,0–0,3). First match at-or-
     after is the second one (0,8). *)
  check_eq "bm anchor: picks first match at-or-after"
    ~expected:1 ~got:bm.current show_int

let test_bm_anchor_wraps () =
  let buf = load "foo bar foo" in
  let qs = q "foo" in
  let bm = Search.recompute_buffer_matches qs buf
    ~anchor:(p 9 99) ~saved_cursor:(p 0 0) in
  check_eq "bm anchor past end: wraps to 0"
    ~expected:0 ~got:bm.current show_int

let test_bm_saved_cursor_preserved () =
  let buf = load "foo" in
  let qs = q "foo" in
  let sc = p 5 2 in
  let bm = Search.recompute_buffer_matches qs buf ~anchor:(p 0 0) ~saved_cursor:sc in
  check_eq "bm: saved_cursor preserved from caller"
    ~expected:sc ~got:bm.saved_cursor show_pos

let test_bm_anchor_of () =
  (* When current is valid, anchor_of returns its start. *)
  let buf = load "foo bar foo" in
  let qs = q "foo" in
  let bm = Search.recompute_buffer_matches qs buf
    ~anchor:(p 0 0) ~saved_cursor:(p 0 0) in
  bm.current <- 1;
  check_eq "anchor_of: previous current's start"
    ~expected:(p 0 8) ~got:(Search.anchor_of bm) show_pos;
  (* When current is -1, anchor_of returns saved_cursor. *)
  bm.current <- -1;
  check_eq "anchor_of: falls back to saved_cursor"
    ~expected:(p 0 0) ~got:(Search.anchor_of bm) show_pos

let test_bm_recompute_preserves_location () =
  (* On match 1 (line 0 col 8). Recompute the same query — the same
     match should still be there, and current should still be on it. *)
  let buf = load "foo bar foo baz foo" in
  let qs = q "foo" in
  let bm = Search.recompute_buffer_matches qs buf
    ~anchor:(p 0 0) ~saved_cursor:(p 0 0) in
  bm.current <- 1;
  let bm2 = Search.recompute_buffer_matches qs buf
    ~anchor:(Search.anchor_of bm) ~saved_cursor:bm.saved_cursor in
  check_eq "recompute preserves location: still on (0,8)"
    ~expected:(p 0 8) ~got:bm2.matches.(bm2.current).start_ show_pos

let test_bm_recompute_match_dropped () =
  (* On match 1. Refine query so match 0 is dropped. The location at
     line 0 col 8 still matches. New current should still point to
     that location (now at index 0). *)
  let buf = load "foo bar fooX baz" in
  let qs = q "foo" in
  let bm = Search.recompute_buffer_matches qs buf
    ~anchor:(p 0 0) ~saved_cursor:(p 0 0) in
  bm.current <- 1;
  (* Refine to "fooX" — only the second match survives. *)
  let qs2 = q "fooX" in
  let bm2 = Search.recompute_buffer_matches qs2 buf
    ~anchor:(Search.anchor_of bm) ~saved_cursor:bm.saved_cursor in
  check_eq "recompute drop earlier: location preserved"
    ~expected:(p 0 8) ~got:bm2.matches.(bm2.current).start_ show_pos;
  check_eq "recompute drop earlier: now index 0"
    ~expected:0 ~got:bm2.current show_int

let test_bm_nav_wrap () =
  let buf = load "foo foo foo" in
  let qs = q "foo" in
  let bm = Search.recompute_buffer_matches qs buf
    ~anchor:(p 0 0) ~saved_cursor:(p 0 0) in
  Search.bm_next bm;
  check_eq "bm_next from 0: → 1" ~expected:1 ~got:bm.current show_int;
  Search.bm_next bm;
  Search.bm_next bm;
  check_eq "bm_next wraps: 2 → 0" ~expected:0 ~got:bm.current show_int;
  Search.bm_prev bm;
  check_eq "bm_prev wraps: 0 → 2" ~expected:2 ~got:bm.current show_int

let test_bm_set_current_clamps () =
  let buf = load "foo foo" in
  let qs = q "foo" in
  let bm = Search.recompute_buffer_matches qs buf
    ~anchor:(p 0 0) ~saved_cursor:(p 0 0) in
  Search.bm_set_current bm 99;
  check_eq "bm_set_current clamps to last"
    ~expected:1 ~got:bm.current show_int;
  Search.bm_set_current bm (-5);
  check_eq "bm_set_current clamps to 0"
    ~expected:0 ~got:bm.current show_int

let test_empty_query_constant () =
  check_eq "empty_query: empty query string"
    ~expected:"" ~got:Search.empty_query.query (fun s -> s);
  check_eq "empty_query: empty replacement"
    ~expected:"" ~got:Search.empty_query.replacement (fun s -> s);
  check_eq "empty_query: focus = Find"
    ~expected:true ~got:(Search.empty_query.focus = Find) string_of_bool

let () =
  test_empty_query ();
  test_basic_literal ();
  test_no_match ();
  test_smart_case_insensitive ();
  test_smart_case_sensitive ();
  test_forced_sensitive ();
  test_regex_basic ();
  test_regex_invalid ();
  test_literal_metachars ();
  test_multiline_positions ();
  test_initial_current_after_cursor ();
  test_initial_current_wraps ();
  test_next_prev_wrap ();
  test_next_prev_empty ();
  test_update_after_edit_preserves_current ();
  test_update_after_edit_match_removed ();
  test_toggle_case ();
  test_buffer_revision ();
  test_tab_search_lazy_refresh ();
  test_tab_search_set_and_clear ();
  test_substitute_literal ();
  test_substitute_regex ();
  test_set_replacement_focus ();
  test_is_case_insensitive ();
  test_bm_empty_query ();
  test_bm_anchor_picks_at_or_after ();
  test_bm_anchor_wraps ();
  test_bm_saved_cursor_preserved ();
  test_bm_anchor_of ();
  test_bm_recompute_preserves_location ();
  test_bm_recompute_match_dropped ();
  test_bm_nav_wrap ();
  test_bm_set_current_clamps ();
  test_empty_query_constant ();
  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1;
  ignore show_matches
