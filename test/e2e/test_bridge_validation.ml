(* End-to-end test for bridge-level argument validation.

   Distinct from test_error_recovery (which covers Rocq-level errors
   raised by the proof checker). Here we exercise the bridge's
   argument-shape checks: text that doesn't match the buffer, etc.
   The bridge should surface these as MCP tool errors (isError:true
   with a descriptive message), not crash. *)

let sample = "\
Lemma triv : True.
Proof.
  trivial.
Qed.
"

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;

    (* verify_to with a [before_text] that doesn't appear in the buffer.
       The bridge should reject with "No match found", not crash. *)
    let r = E2e_harness.call_tool s "verify_to"
      ~args:(`Assoc [
        "before_text", `String "definitely_not_present_anywhere";
      ]) in
    let result = E2e_harness.result_of r in
    let is_error = match Yojson.Safe.Util.member "isError" result with
      | `Bool true -> true | _ -> false in
    if not is_error then
      E2e_harness.fail
        (Printf.sprintf "expected isError:true, got: %s"
          (Yojson.Safe.to_string result));
    let err_text = match E2e_harness.extract_content_text result with
      | Some t -> t | None -> "" in
    E2e_harness.assert_contains ~haystack:err_text ~needle:"No match";
    Printf.printf "  verify_to with bad before_text: %s\n"
      (String.trim err_text);

    (* proof_forward with text that doesn't match what's after the
       verified boundary. Same rejection shape. *)
    let r = E2e_harness.call_tool s "proof_forward"
      ~args:(`Assoc [
        "sentences", `String "Definition wrong : nat := 0.";
      ]) in
    let result = E2e_harness.result_of r in
    let is_error = match Yojson.Safe.Util.member "isError" result with
      | `Bool true -> true | _ -> false in
    if not is_error then
      E2e_harness.fail
        (Printf.sprintf "expected isError:true on mismatch, got: %s"
          (Yojson.Safe.to_string result));
    let err_text = match E2e_harness.extract_content_text result with
      | Some t -> t | None -> "" in
    E2e_harness.assert_contains ~haystack:err_text
      ~needle:"does not match";
    Printf.printf "  proof_forward with mismatch: %s\n"
      (String.trim (String.sub err_text 0 (min 80 (String.length err_text))));

    (* The session must still be healthy after rejected calls. *)
    let qr = E2e_harness.call_tool s "query"
      ~args:(`Assoc ["command", `String "Check 0."]) in
    let qbody = E2e_harness.structured_response (E2e_harness.result_of qr) in
    let qmsg = match Yojson.Safe.Util.member "messages" qbody with
      | `String s -> s | _ -> "" in
    E2e_harness.assert_contains ~haystack:qmsg ~needle:"nat";

    print_endline "OK: bridge surfaces argument-validation failures \
                   without poisoning the session";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
