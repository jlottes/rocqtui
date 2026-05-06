(* End-to-end test for [replace_after].

   Covers the motivating use case: after Claude inserts a real proof
   ending in [Qed.], the leftover [Admitted.] placeholder sits at the
   head of the unverified region and needs to be cleaned out. Also
   covers a non-empty replacement and a no-match rejection. *)

let initial_source = "\
Lemma triv : True.
Proof.
Admitted.
"

let body_of r =
  let result = E2e_harness.result_of r in
  E2e_harness.structured_response result

let read_buffer s =
  let r = E2e_harness.request s "resources/read"
    ~params:(`Assoc ["uri", `String "rocqtui://buffer"]) in
  let open Yojson.Safe.Util in
  r |> member "result" |> member "contents" |> index 0 |> member "text"
    |> to_string

let buffer_contains buf needle =
  let h = String.length buf in
  let n = String.length needle in
  if n = 0 then true
  else
    let found = ref false in
    let i = ref 0 in
    while not !found && !i + n <= h do
      if String.sub buf !i n = needle then found := true;
      incr i
    done;
    !found

let () =
  let s = E2e_harness.start ~rocq_source:initial_source () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;

    (* Advance verified boundary to just after [Proof.] — the file
       still has [Admitted.] sitting in the unverified region. *)
    let r = E2e_harness.call_tool s "verify_to"
      ~args:(`Assoc [
        "before_text", `String "Lemma triv : True.\nProof.";
      ]) in
    let _ = body_of r in

    (* Insert a real proof ending in Qed. — leaves [Admitted.] orphaned
       at the head of the unverified region. *)
    let r = E2e_harness.call_tool s "proof_insert"
      ~args:(`Assoc ["text", `String " trivial. Qed."]) in
    let body = body_of r in
    (match Yojson.Safe.Util.member "error" body with
     | `Null -> ()
     | other ->
       E2e_harness.fail
         (Printf.sprintf "proof_insert returned error: %s"
           (Yojson.Safe.to_string other)));
    let buf_before = read_buffer s in
    if not (buffer_contains buf_before "Qed.") then
      E2e_harness.fail
        (Printf.sprintf "Qed. not in buffer after insert: %S" buf_before);
    if not (buffer_contains buf_before "Admitted.") then
      E2e_harness.fail
        (Printf.sprintf "Admitted. unexpectedly gone before cleanup: %S"
          buf_before);

    (* The cleanup case: replace [Admitted.] with empty. *)
    let r = E2e_harness.call_tool s "replace_after"
      ~args:(`Assoc [
        "match", `String "Admitted.";
        "replacement", `String "";
      ]) in
    let body = body_of r in
    let replaced = match Yojson.Safe.Util.member "replaced_text" body with
      | `String s -> s
      | _ -> E2e_harness.fail "missing replaced_text" in
    if String.trim replaced <> "Admitted." then
      E2e_harness.fail
        (Printf.sprintf "expected replaced_text 'Admitted.', got %S" replaced);

    let buf_after = read_buffer s in
    if buffer_contains buf_after "Admitted." then
      E2e_harness.fail
        (Printf.sprintf "Admitted. still in buffer after cleanup: %S"
          buf_after);
    if not (buffer_contains buf_after "Qed.") then
      E2e_harness.fail
        (Printf.sprintf "Qed. lost during cleanup: %S" buf_after);
    Printf.printf "  buffer after Admitted. cleanup: %S\n"
      (String.trim buf_after);

    (* Non-empty replacement: rewind the verified boundary back to just
       after [Proof.] (without deleting) so that [trivial. Qed.] sits
       in the unverified region, then swap [trivial.] for [exact I.]. *)
    let r = E2e_harness.call_tool s "verify_to"
      ~args:(`Assoc [
        "before_text", `String "Lemma triv : True.\nProof.";
      ]) in
    let _ = body_of r in
    let r = E2e_harness.call_tool s "replace_after"
      ~args:(`Assoc [
        "match", `String "trivial.";
        "replacement", `String "exact I.";
      ]) in
    let body = body_of r in
    (match Yojson.Safe.Util.member "replaced_text" body with
     | `String s when String.trim s = "trivial." -> ()
     | other ->
       E2e_harness.fail
         (Printf.sprintf "expected 'trivial.', got %s"
           (Yojson.Safe.to_string other)));
    let buf_after_swap = read_buffer s in
    if buffer_contains buf_after_swap "trivial." then
      E2e_harness.fail
        (Printf.sprintf "old text 'trivial.' leaked: %S" buf_after_swap);
    if not (buffer_contains buf_after_swap "exact I.") then
      E2e_harness.fail
        (Printf.sprintf "replacement 'exact I.' missing: %S"
          buf_after_swap);
    (* And the swapped text should still verify. *)
    let r = E2e_harness.call_tool s "proof_forward"
      ~args:(`Assoc ["sentences", `String "exact I. Qed."]) in
    let body = body_of r in
    (match Yojson.Safe.Util.member "error" body with
     | `Null -> ()
     | other ->
       E2e_harness.fail
         (Printf.sprintf "swapped proof failed to verify: %s"
           (Yojson.Safe.to_string other)));
    Printf.printf "  buffer after swap: %S\n" (String.trim buf_after_swap);

    (* No-match case: pattern doesn't match the head. *)
    let r = E2e_harness.call_tool s "replace_after"
      ~args:(`Assoc [
        "match", `String "definitely_not_at_boundary.";
        "replacement", `String "";
      ]) in
    let result = E2e_harness.result_of r in
    let is_error = match Yojson.Safe.Util.member "isError" result with
      | `Bool true -> true | _ -> false in
    if not is_error then
      E2e_harness.fail
        (Printf.sprintf "expected isError:true on no-match, got: %s"
          (Yojson.Safe.to_string result));
    let err_text = match E2e_harness.extract_content_text result with
      | Some t -> t | None -> "" in
    E2e_harness.assert_contains ~haystack:err_text ~needle:"does not match";

    print_endline "OK: replace_after handles cleanup, swap, and no-match";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
