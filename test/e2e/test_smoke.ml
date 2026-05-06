(* Smoke test: launch headless rocqtui on a sample .v file via the
   bridge, advance the verified region into a proof, and check that
   the response carries goals containing the expected hypothesis. *)

let sample = "\
Lemma plus_zero : forall n : nat, n + 0 = n.
Proof.
  intros n.
  induction n.
"

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;
    (* Drive the verified boundary past [induction n.]. Sentences must
       cover the full text from the start of the buffer (verified
       boundary = 0) up to whatever we want verified — whitespace is
       normalized for the match. *)
    let r = E2e_harness.call_tool s "proof_forward"
      ~args:(`Assoc [
        "sentences", `String
          "Lemma plus_zero : forall n : nat, n + 0 = n. \
           Proof. intros n. induction n.";
      ]) in
    let result = E2e_harness.result_of r in
    let body = E2e_harness.structured_response result in
    let goals = match Yojson.Safe.Util.member "goals" body with
      | `String g -> g
      | _ ->
        E2e_harness.dump_logs s;
        E2e_harness.fail
          (Printf.sprintf "no goals string in response: %s"
            (Yojson.Safe.to_string body))
    in
    (* After [induction n.] we expect two subgoals: the base case
       [0 + 0 = 0] and the inductive step with [IHn] in context. *)
    E2e_harness.assert_contains ~haystack:goals ~needle:"IHn";
    E2e_harness.assert_contains ~haystack:goals ~needle:"S n";
    print_endline "OK: proof_forward returns goals after [induction n.]";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
