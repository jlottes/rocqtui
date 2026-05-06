(* End-to-end test for open_file bridge tool.

   Opens a second .v file and checks that [rocqtui://tabs] reflects
   it. Confirms that subsequent operations can target the new tab via
   the [tab] argument and that per-tab session state is independent. *)

let body_of r =
  let result = E2e_harness.result_of r in
  E2e_harness.structured_response result

let read_resource s uri =
  let r = E2e_harness.request s "resources/read"
    ~params:(`Assoc ["uri", `String uri]) in
  let open Yojson.Safe.Util in
  r |> member "result" |> member "contents" |> index 0 |> member "text"
    |> to_string

let () =
  let s = E2e_harness.start ~rocq_source:"" () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;

    (* Write a second .v file in the same temp dir and open it. *)
    let other_path = Filename.concat s.tmpdir "other.v" in
    let oc = open_out other_path in
    output_string oc "Definition forty_two : nat := 42.\n";
    close_out oc;

    let r = E2e_harness.call_tool s "open_file"
      ~args:(`Assoc ["filename", `String other_path]) in
    let other_tab_id =
      match Yojson.Safe.Util.member "tab" (body_of r) with
      | `Int n -> n
      | _ -> E2e_harness.fail
               (Printf.sprintf "open_file response missing tab id: %s"
                  (Yojson.Safe.to_string (body_of r)))
    in
    Printf.printf "  other.v tab id: %d\n" other_tab_id;

    (* The tabs resource should now list both files. The MCP server
       returns a bare JSON array, not wrapped in {tabs: [...]}. *)
    let tabs_text = read_resource s "rocqtui://tabs" in
    E2e_harness.assert_contains ~haystack:tabs_text ~needle:"sample.v";
    E2e_harness.assert_contains ~haystack:tabs_text ~needle:"other.v";

    (* Verify a sentence in the new tab and confirm via query. *)
    let _ = E2e_harness.call_tool s "proof_forward"
      ~args:(`Assoc [
        "tab", `Int other_tab_id;
        "sentences", `String "Definition forty_two : nat := 42.";
      ]) in
    let qr = E2e_harness.call_tool s "query"
      ~args:(`Assoc [
        "tab", `Int other_tab_id;
        "command", `String "Check forty_two.";
      ]) in
    let qmsg = match Yojson.Safe.Util.member "messages" (body_of qr) with
      | `String s -> s | _ -> "" in
    E2e_harness.assert_contains ~haystack:qmsg ~needle:"forty_two";
    E2e_harness.assert_contains ~haystack:qmsg ~needle:"nat";
    Printf.printf "  query in other tab: %s\n" (String.trim qmsg);

    (* The original (sample.v) tab is id 0 — open_file made the new
       tab active, so we must pass [tab:0] explicitly to query the
       original. forty_two should NOT be in scope there. *)
    let qr2 = E2e_harness.call_tool s "query"
      ~args:(`Assoc [
        "tab", `Int 0;
        "command", `String "Check forty_two.";
      ]) in
    let q2msg = match Yojson.Safe.Util.member "messages" (body_of qr2) with
      | `String s -> s | _ -> "" in
    if try ignore (Str.search_forward
                     (Str.regexp_string ": nat") q2msg 0); true
       with Not_found -> false
    then
      E2e_harness.fail
        (Printf.sprintf "session leaked: forty_two visible in tab 0: %S"
          q2msg);
    (* Expect either an "Unknown reference" / "not found" error message
       or no message at all; we only assert the query did NOT type-check. *)
    Printf.printf "  default tab Check forty_two: %s\n" (String.trim q2msg);

    print_endline "OK: open_file adds a tab; per-tab session state is \
                   independent";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
