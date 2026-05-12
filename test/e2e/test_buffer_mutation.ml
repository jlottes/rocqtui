(* End-to-end test for the buffer-mutating bridge tools.

   - proof_insert appends sentences at the verified boundary, drives
     verification through them, and reports what verified.
   - proof_rewind with delete:true rewinds the verified region AND
     removes the rewound text from the buffer.

   Both go through Region_buffer (the edit gateway), so they exercise
   that path too. *)

let initial_source = ""

let body_of r =
  let result = E2e_harness.result_of r in
  E2e_harness.structured_response result

(* Read the bridge's [rocqtui://buffer] resource, which returns the
   raw buffer text in the resource's [text] field. *)
let read_buffer s =
  let r = E2e_harness.request s "resources/read"
    ~params:(`Assoc ["uri", `String "rocqtui://buffer"]) in
  let open Yojson.Safe.Util in
  r |> member "result" |> member "contents" |> index 0 |> member "text"
    |> to_string

let () =
  let s = E2e_harness.start ~rocq_source:initial_source () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;

    let starting_buf = read_buffer s in
    if String.trim starting_buf <> "" then
      E2e_harness.fail
        (Printf.sprintf "starting buffer not empty: %S" starting_buf);

    (* Insert a small lemma and verify it. *)
    let lemma = "Lemma plus_oneone : 1 + 1 = 2. \
                 Proof. reflexivity. Qed." in
    let r = E2e_harness.call_tool s "proof_insert"
      ~args:(`Assoc ["text", `String lemma]) in
    let body = body_of r in
    (match Yojson.Safe.Util.member "error" body with
     | `Null -> ()
     | other ->
       E2e_harness.fail
         (Printf.sprintf "proof_insert returned error: %s"
           (Yojson.Safe.to_string other)));
    let verified_text =
      match Yojson.Safe.Util.member "verified_text" body with
      | `String s -> s
      | _ -> E2e_harness.fail "missing verified_text"
    in
    E2e_harness.assert_contains ~haystack:verified_text ~needle:"plus_oneone";
    E2e_harness.assert_contains ~haystack:verified_text ~needle:"reflexivity";
    Printf.printf "  proof_insert verified: %S\n"
      (String.trim verified_text);

    (* The buffer should now hold the inserted text. *)
    let after_insert_buf = read_buffer s in
    E2e_harness.assert_contains ~haystack:after_insert_buf
      ~needle:"plus_oneone";
    E2e_harness.assert_contains ~haystack:after_insert_buf
      ~needle:"reflexivity";

    (* The lemma is now in scope — confirm via a query. *)
    let qr = E2e_harness.call_tool s "query"
      ~args:(`Assoc ["command", `String "Check plus_oneone."]) in
    let qmsg = match Yojson.Safe.Util.member "messages" (body_of qr) with
      | `String s -> s | _ -> "" in
    E2e_harness.assert_contains ~haystack:qmsg ~needle:"plus_oneone";

    (* Rewind the proof body but keep the lemma statement, deleting the
       rewound text. Pattern matches the tail of the verified region. *)
    let _ = E2e_harness.call_tool s "proof_rewind"
      ~args:(`Assoc [
        "sentences", `String "Proof. reflexivity. Qed.";
        "delete", `Bool true;
      ]) in

    let after_rewind_buf = read_buffer s in
    (* Strict check: rewind+delete must consume the whitespace that
       separated the rewound sentences from the kept ones. Otherwise
       repeated insert/rewind cycles leak whitespace into the buffer.
       Buffer.text always ends in "\n", so include that in the
       expected value. *)
    if after_rewind_buf <> "Lemma plus_oneone : 1 + 1 = 2.\n" then
      E2e_harness.fail
        (Printf.sprintf "rewind+delete left stray content: %S"
           after_rewind_buf);
    Printf.printf "  buffer after rewind+delete: %S\n" after_rewind_buf;

    (* Rewind further — remove the lemma statement too — and confirm
       the buffer is back to its starting (empty) state, exactly. *)
    let _ = E2e_harness.call_tool s "proof_rewind"
      ~args:(`Assoc [
        "sentences", `String "Lemma plus_oneone : 1 + 1 = 2.";
        "delete", `Bool true;
      ]) in
    let final_buf = read_buffer s in
    if final_buf <> starting_buf then
      E2e_harness.fail
        (Printf.sprintf "buffer not back to start after full rewind: \
                         %S (expected %S)" final_buf starting_buf);

    (* Exercise the leak path directly: insert text whose leading
       whitespace is supplied by the caller (not auto-prepended), then
       rewind. Without the walkback in proof_rewind, the leading
       whitespace would be left behind and accumulate across cycles. *)
    let _ = E2e_harness.call_tool s "proof_insert"
      ~args:(`Assoc ["text", `String "Definition anchor := 0."]) in
    let expected = "Definition anchor := 0.\n" in
    for i = 1 to 3 do
      let body = Printf.sprintf "Definition leak_%d := %d." i i in
      let _ = E2e_harness.call_tool s "proof_insert"
        ~args:(`Assoc ["text", `String ("\n\n" ^ body)]) in
      let _ = E2e_harness.call_tool s "proof_rewind"
        ~args:(`Assoc [
          "sentences", `String body;
          "delete", `Bool true;
        ]) in
      let buf = read_buffer s in
      if buf <> expected then
        E2e_harness.fail
          (Printf.sprintf "whitespace leak after cycle %d: %S \
                           (expected %S)" i buf expected)
    done;

    print_endline "OK: proof_insert + proof_rewind delete:true keep \
                   buffer and verified region in sync";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
