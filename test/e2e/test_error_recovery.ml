(* Error-recovery end-to-end test.

   Covers the failure path of [proof_forward] / [verify_to]: a
   sentence that triggers a Rocq error must surface the failed text
   and error message in the bridge response, leave the verified
   region at the last good sentence, and not poison subsequent
   operations against the same session. *)

let sample = "\
Lemma trivial : True.
Proof.
  apply nonexistent_lemma.
Qed.
"

let body_of r =
  let result = E2e_harness.result_of r in
  E2e_harness.structured_response result

let string_field body key =
  match Yojson.Safe.Util.member key body with
  | `String s -> Some s
  | _ -> None

let messages_of body =
  match Yojson.Safe.Util.member "messages" body with
  | `String s -> s
  | _ -> ""

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;

    (* Drive verification past the bad apply. proof_forward gives us
       the response shape we want to assert against (failed_sentence,
       error). *)
    let r = E2e_harness.call_tool s "proof_forward"
      ~args:(`Assoc [
        "sentences", `String
          "Lemma trivial : True. Proof. apply nonexistent_lemma. Qed.";
      ]) in
    let body = body_of r in

    (* failed_sentence should name the bad apply. *)
    (match string_field body "failed_sentence" with
     | Some fs ->
       E2e_harness.assert_contains ~haystack:fs ~needle:"nonexistent_lemma";
       Printf.printf "  failed_sentence: %s\n" fs
     | None ->
       E2e_harness.fail
         (Printf.sprintf "expected failed_sentence in: %s"
           (Yojson.Safe.to_string body)));

    (* error should mention the unresolved name. Rocq's exact wording
       varies by version, so we only check for the name itself. *)
    (match string_field body "error" with
     | Some err ->
       E2e_harness.assert_contains ~haystack:err ~needle:"nonexistent_lemma";
       Printf.printf "  error: %s\n" (String.trim err)
     | None ->
       E2e_harness.fail
         (Printf.sprintf "expected error in: %s"
           (Yojson.Safe.to_string body)));

    (* verified_text should include "Proof." but stop before "apply". *)
    (match string_field body "verified_text" with
     | Some vt ->
       E2e_harness.assert_contains ~haystack:vt ~needle:"Proof.";
       if String.length vt > 0 &&
          (try ignore (Str.search_forward (Str.regexp_string "apply") vt 0); true
           with Not_found -> false)
       then
         E2e_harness.fail
           (Printf.sprintf "verified_text leaked the failing apply: %S" vt);
       Printf.printf "  verified_text: %S\n" vt
     | None ->
       E2e_harness.fail "expected verified_text");

    (* Subsequent operations must still work. Issue a query at the
       (post-failure) tip — the session should be healthy enough to
       answer. *)
    let qr = E2e_harness.call_tool s "query"
      ~args:(`Assoc ["command", `String "Check True."]) in
    let qbody = body_of qr in
    let msg = messages_of qbody in
    E2e_harness.assert_contains ~haystack:msg ~needle:"Prop";
    Printf.printf "  post-failure query: %s\n" (String.trim msg);

    (* Recovery: rewind the partially-verified region (delete:false
       so we don't touch the buffer), then re-attempt with a corrected
       proof. The buffer keeps its original (broken) text, so we use
       a one-off query to confirm the session is reusable rather than
       editing the buffer. *)
    let _ = E2e_harness.call_tool s "proof_rewind"
      ~args:(`Assoc [
        "sentences", `String "Proof.";
        "delete", `Bool false;
      ]) in

    (* And one more query to confirm the session still answers
       correctly after the rewind. *)
    let qr2 = E2e_harness.call_tool s "query"
      ~args:(`Assoc ["command", `String "Check 0."]) in
    let msg2 = messages_of (body_of qr2) in
    E2e_harness.assert_contains ~haystack:msg2 ~needle:"nat";

    print_endline "OK: failure surfaces failed_sentence + error; \
                   session usable afterwards";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
