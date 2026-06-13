(* E2e test for verification timeouts (docs/TIMEOUT_PLAN.md).

   A diverging tactic must not leave a success-shaped response: the
   verifying tools wait up to [timeout] seconds, then auto-interrupt
   and report timed_out + a non-null error. proof_insert must keep its
   invariant — the hung insertion is deleted, leaving the buffer
   byte-identical. *)

(* [do 1000000000 idtac.] burns CPU for hours at constant memory and
   dies cleanly on SIGINT — unlike the recursive-Ltac fixture in
   test_interrupt_recovery.ml, which stack-overflows after ~2s and
   would race the timeout under test. *)
let hang = "do 1000000000 idtac."

let sample =
  String.concat "\n" [
    "Theorem hangs : True.";
    "Proof.";
    hang;
    "Qed.";
    "";
  ]

let body_of r =
  let result = E2e_harness.result_of r in
  E2e_harness.structured_response result

let read_resource s uri =
  let r = E2e_harness.request s "resources/read"
    ~params:(`Assoc ["uri", `String uri]) in
  let open Yojson.Safe.Util in
  r |> member "result" |> member "contents" |> index 0 |> member "text"
    |> to_string

let check_timing ~expect_timed_out body what =
  (match Yojson.Safe.Util.member "timed_out" body with
   | `Bool b when b = expect_timed_out -> ()
   | j -> E2e_harness.fail (Printf.sprintf
       "%s: timed_out = %s, expected %b" what
       (Yojson.Safe.to_string j) expect_timed_out));
  (match Yojson.Safe.Util.member "elapsed_seconds" body with
   | `Float f ->
     if expect_timed_out && f < 1.9 then
       E2e_harness.fail (Printf.sprintf
         "%s: elapsed_seconds = %.1f, expected >= the 2s timeout" what f)
   | j -> E2e_harness.fail (Printf.sprintf
       "%s: elapsed_seconds = %s, expected a float" what
       (Yojson.Safe.to_string j)))

let assert_error_nonnull body what =
  match Yojson.Safe.Util.member "error" body with
  | `String _ -> ()
  | j -> E2e_harness.fail (Printf.sprintf
      "%s: error = %s, expected a timeout message" what
      (Yojson.Safe.to_string j))

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;

    (* Verify up to [Proof.] — finishes fast, timing fields present. *)
    let r = E2e_harness.call_tool s "proof_forward"
      ~args:(`Assoc [
        "sentences", `String "Theorem hangs : True. Proof.";
      ]) in
    check_timing ~expect_timed_out:false (body_of r) "fast proof_forward";

    let buf_before = read_resource s "rocqtui://buffer" in

    (* proof_insert of a diverging tactic: times out, interrupts, and
       deletes the insertion — buffer must come back byte-identical. *)
    let r = E2e_harness.call_tool s "proof_insert"
      ~args:(`Assoc [
        "text", `String hang;
        "timeout", `Int 2;
      ]) in
    let body = body_of r in
    check_timing ~expect_timed_out:true body "hung proof_insert";
    assert_error_nonnull body "hung proof_insert";
    (match Yojson.Safe.Util.member "verified_text" body with
     | `String "" -> ()
     | j -> E2e_harness.fail (Printf.sprintf
         "hung proof_insert: verified_text = %s, expected empty"
         (Yojson.Safe.to_string j)));
    let buf_after = read_resource s "rocqtui://buffer" in
    if buf_after <> buf_before then
      E2e_harness.fail (Printf.sprintf
        "proof_insert invariant broken: buffer changed after hung \
         insert.\nBefore: %S\nAfter:  %S" buf_before buf_after);

    (* proof_forward into the buffer's own hanging sentence: times out
       and reports it; existing text is kept. *)
    let r = E2e_harness.call_tool s "proof_forward"
      ~args:(`Assoc [
        "sentences", `String hang;
        "timeout", `Int 2;
      ]) in
    let body = body_of r in
    check_timing ~expect_timed_out:true body "hung proof_forward";
    assert_error_nonnull body "hung proof_forward";
    (match Yojson.Safe.Util.member "last_sentence" body with
     | `String "Proof." -> ()
     | j -> E2e_harness.fail (Printf.sprintf
         "hung proof_forward: last_sentence = %s, expected \"Proof.\""
         (Yojson.Safe.to_string j)));

    (* The session must be usable after the auto-interrupts. *)
    let r = E2e_harness.call_tool s "query"
      ~args:(`Assoc ["command", `String "Check I."]) in
    let qmsg = match Yojson.Safe.Util.member "messages" (body_of r) with
      | `String m -> m | _ -> "" in
    E2e_harness.assert_contains ~haystack:qmsg ~needle:"True";

    print_endline "OK: verification timeouts auto-interrupt, report \
                   timed_out, and preserve the proof_insert invariant";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
