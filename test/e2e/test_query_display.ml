(* Query-with-display end-to-end test.

   [Stm.query] renders against the cached state's snapshot at the
   query's [at:], so SetOptions or inline [Set Printing X.] in the
   query phrase don't affect output. The fix: bake the options into a
   transient state via [Add], query at that state, then [edit_at]
   back. Validates that workaround end-to-end through the bridge. *)

let sample = "\
Definition foo {A : Type} (x : A) : A := x.
"

let messages_of r =
  let result = E2e_harness.result_of r in
  let body = E2e_harness.structured_response result in
  match Yojson.Safe.Util.member "messages" body with
  | `String s -> s
  | _ ->
    E2e_harness.fail
      (Printf.sprintf "no messages string in: %s"
        (Yojson.Safe.to_string body))

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;
    let _ = E2e_harness.call_tool s "proof_forward"
      ~args:(`Assoc [
        "sentences", `String "Definition foo {A : Type} (x : A) : A := x.";
      ]) in
    let baseline =
      let r = E2e_harness.call_tool s "query"
        ~args:(`Assoc ["command", `String "Check (foo 5)."]) in
      messages_of r
    in
    let with_all =
      let r = E2e_harness.call_tool s "query"
        ~args:(`Assoc [
          "command", `String "Check (foo 5).";
          "display", `Assoc ["all", `Bool true];
        ]) in
      messages_of r
    in
    Printf.printf "baseline:\n%s\n\nwith all=true:\n%s\n" baseline with_all;
    E2e_harness.assert_not_equal_strings
      ~a:baseline ~b:with_all
      ~msg:"display:{all:true} should change query output";
    E2e_harness.assert_contains ~haystack:with_all ~needle:"@foo";
    (* Crucial regression check: after the per-call query, the document
       must be back to its original state. Run the same baseline query
       again and assert it matches the original. *)
    let baseline_again =
      let r = E2e_harness.call_tool s "query"
        ~args:(`Assoc ["command", `String "Check (foo 5)."]) in
      messages_of r
    in
    if baseline_again <> baseline then
      E2e_harness.fail
        (Printf.sprintf "transient setup leaked: baseline %S vs after %S"
          baseline baseline_again);
    print_endline "OK: query display:{all:true} forces @-form via Add+EditAt";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
