(* End-to-end tests for undo/redo region-invariant enforcement.

   Two properties are exercised:

   - Undo/redo go through Region_buffer like every other edit; they
     are rejected when they would alter the verified region. There is
     no escape hatch.

   - When a successful undo destroys the bytes the error region was
     anchored to, the error region is cleared. (The bug that motivated
     this test: an Applied undo silently clobbered the bytes underneath
     the error highlight, leaving the highlight pointing at unrelated
     text.)

   The bridge doesn't re-export undo/redo (no use case for it), so
   these tests bypass the bridge and talk directly to rocqtui's MCP
   socket. The harness still spawns the bridge, but we ignore it. *)

(* --- Direct connection to the rocqtui MCP server --- *)

type rconn = {
  fd : Unix.file_descr;
  ic : in_channel;
  mutable next_id : int;
}

let rconnect path =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX path);
  let ic = Unix.in_channel_of_descr fd in
  { fd; ic; next_id = 1 }

let rsend r json =
  let s = Yojson.Safe.to_string json ^ "\n" in
  let _ = Unix.write_substring r.fd s 0 (String.length s) in
  ()

let rrecv r =
  Yojson.Safe.from_string (input_line r.ic)

let rcall r ?(params=`Null) method_ =
  let id = r.next_id in
  r.next_id <- id + 1;
  rsend r (`Assoc [
    "jsonrpc", `String "2.0";
    "id", `Int id;
    "method", `String method_;
    "params", params;
  ]);
  (* Skip notifications, return the matching response. *)
  let rec wait () =
    let resp = rrecv r in
    match Yojson.Safe.Util.member "id" resp with
    | `Int rid when rid = id -> resp
    | _ -> wait ()
  in
  wait ()

let rinitialize r =
  let _ = rcall r "initialize"
    ~params:(`Assoc [
      "protocolVersion", `String "2024-11-05";
      "capabilities", `Assoc [];
      "clientInfo", `Assoc [
        "name", `String "rocqtui-e2e-undo-redo";
        "version", `String "0.0";
      ];
    ]) in
  rsend r (`Assoc [
    "jsonrpc", `String "2.0";
    "method", `String "notifications/initialized";
    "params", `Assoc [];
  ])

let rcall_tool r ?(args=`Assoc []) name =
  rcall r "tools/call"
    ~params:(`Assoc ["name", `String name; "arguments", args])

let rresult resp =
  match Yojson.Safe.Util.member "result" resp with
  | `Null ->
    failwith
      (Printf.sprintf "no result in response: %s"
        (Yojson.Safe.to_string resp))
  | r -> r

let read_buffer r =
  let resp = rcall r "resources/read"
    ~params:(`Assoc ["uri", `String "rocqtui://buffer"]) in
  let open Yojson.Safe.Util in
  resp |> member "result" |> member "contents" |> index 0
       |> member "text" |> to_string

let read_error r =
  let resp = rcall r "resources/read"
    ~params:(`Assoc ["uri", `String "rocqtui://error"]) in
  let open Yojson.Safe.Util in
  let text = resp |> member "result" |> member "contents" |> index 0
                  |> member "text" |> to_string in
  Yojson.Safe.from_string text

(* For a tools/call response, the rocqtui MCP server returns
   {"result":{"content":[...], "isError":?, "rejection_reason":?}}.
   Helpers to pull out the bits we assert against. *)

let tool_is_error resp =
  match Yojson.Safe.Util.member "isError" (rresult resp) with
  | `Bool true -> true | _ -> false

let tool_rejection_reason resp =
  match Yojson.Safe.Util.member "rejection_reason" (rresult resp) with
  | `String s -> Some s | _ -> None

let assert_rejected ~reason resp =
  if not (tool_is_error resp) then
    E2e_harness.fail
      (Printf.sprintf "expected isError:true, got: %s"
        (Yojson.Safe.to_string resp));
  match tool_rejection_reason resp with
  | Some r when r = reason -> ()
  | _ ->
    E2e_harness.fail
      (Printf.sprintf "expected rejection_reason %S, got: %s"
        reason (Yojson.Safe.to_string resp))

let assert_applied resp =
  if tool_is_error resp then
    E2e_harness.fail
      (Printf.sprintf "expected Applied, got: %s"
        (Yojson.Safe.to_string resp))

(* Ask the server for its is_busy flag and spin-wait for it to clear.
   verify_to/proof_forward are async on the rocqtui side: we set the
   target via go_to_offset, then the server churns until the verified
   region catches up (or fails). *)
let wait_idle r ~timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    let resp = rcall_tool r "is_busy" in
    let busy = match Yojson.Safe.Util.member "content"
                       (rresult resp) with
      | `List ((`Assoc c) :: _) ->
        (match List.assoc_opt "text" c with
         | Some (`String "true") -> true
         | _ -> false)
      | _ -> false
    in
    if not busy then ()
    else if Unix.gettimeofday () > deadline then
      failwith "wait_idle timed out"
    else begin
      Unix.sleepf 0.02;
      loop ()
    end
  in
  loop ()

(* Drive the verified boundary to a given byte offset, waiting for
   verification to complete (succeed or fail). *)
let verify_to_offset r off =
  let _ = rcall_tool r "go_to_offset"
    ~args:(`Assoc ["offset", `Int off]) in
  wait_idle r ~timeout:10.0

(* --- Subtest 1: undo through verified region is rejected.

   Reproduces the original "escape hatch": before the fix,
   Region_buffer.try_undo bypassed the invariant check entirely, so an
   undo that would erase verified bytes would silently apply. *)

let test_undo_into_verified s =
  let r = rconnect s.E2e_harness.socket_path in
  rinitialize r;
  let proof = "Lemma t : True. Proof. trivial. Qed." in
  let _ = rcall_tool r "insert_text"
    ~args:(`Assoc ["offset", `Int 0; "text", `String proof]) in
  verify_to_offset r (String.length proof);
  let buf_before = read_buffer r in
  E2e_harness.assert_contains ~haystack:buf_before ~needle:"trivial";
  (* Undo would have to delete bytes inside the verified region. *)
  let resp = rcall_tool r "undo" in
  assert_rejected ~reason:"in_verified_region" resp;
  let buf_after = read_buffer r in
  if buf_after <> buf_before then
    E2e_harness.fail
      (Printf.sprintf "buffer mutated by rejected undo: \
                       before=%S after=%S" buf_before buf_after);
  Printf.printf "  undo into verified region: rejected\n";
  Unix.close r.fd

(* --- Subtest 2: redo through verified region is rejected.

   verify_to/proof_forward only call go_to_offset — they don't push to
   the buffer's undo stack — so the redo stack survives advancing the
   verified region. *)

let test_redo_into_verified s =
  let r = rconnect s.E2e_harness.socket_path in
  rinitialize r;
  let buf_initial = read_buffer r in
  let qed_off = try Str.search_forward
      (Str.regexp_string "Qed.") buf_initial 0
    with Not_found -> E2e_harness.fail "Qed. not in initial buffer" in
  let qed_end = qed_off + 4 in
  (* Delete "Qed." — Applied (verified_end is 0). *)
  let resp = rcall_tool r "delete_range"
    ~args:(`Assoc ["start", `Int qed_off; "end", `Int qed_end]) in
  assert_applied resp;
  (* Undo. Buffer restored, redo stack now carries the post-delete
     snapshot. *)
  let resp = rcall_tool r "undo" in
  assert_applied resp;
  let buf_post_undo = read_buffer r in
  if buf_post_undo <> buf_initial then
    E2e_harness.fail
      (Printf.sprintf "buffer not restored after undo: \
                       expected=%S got=%S" buf_initial buf_post_undo);
  (* Verify the entire content. *)
  verify_to_offset r (String.length buf_post_undo);
  (* Redo would re-delete "Qed.", which is now inside verified. *)
  let resp = rcall_tool r "redo" in
  assert_rejected ~reason:"in_verified_region" resp;
  let buf_after = read_buffer r in
  if buf_after <> buf_post_undo then
    E2e_harness.fail
      (Printf.sprintf "buffer mutated by rejected redo: \
                       before=%S after=%S" buf_post_undo buf_after);
  Printf.printf "  redo into verified region: rejected\n";
  Unix.close r.fd

(* --- Subtest 3: an Applied undo clears the error region.

   Reproduces the bug the user reported. Pre-fix, Region_buffer.try_undo
   applies the text mutation but no caller clears the session's stale
   err_range — so the highlight survives even though the bytes it
   pointed at are gone. *)

let test_undo_clears_error s =
  let r = rconnect s.E2e_harness.socket_path in
  rinitialize r;
  (* Verify "Lemma t : True. Proof." so the verified region is
     non-trivial and there's a fresh-proof context for the bad
     tactic to land in. *)
  let pre_buf = read_buffer r in
  let proof_end = try
      let off = Str.search_forward (Str.regexp_string "Proof.") pre_buf 0 in
      off + String.length "Proof."
    with Not_found -> E2e_harness.fail "Proof. not in initial buffer" in
  verify_to_offset r proof_end;
  (* Append a sentence that will fail verification. *)
  let pre_buf = read_buffer r in
  let resp = rcall_tool r "insert_text"
    ~args:(`Assoc [
      "offset", `Int (String.length pre_buf);
      "text", `String " badtactic.";
    ]) in
  assert_applied resp;
  (* Drive verification past the broken sentence. *)
  let after_buf = read_buffer r in
  verify_to_offset r (String.length after_buf);
  (* The err_range should now be set on " badtactic." *)
  let err_before = read_error r in
  (match err_before with
   | `Null ->
     E2e_harness.fail "expected error region to be set after \
                       failed verification"
   | _ -> ());
  (* Undo the insertion. The deleted bytes are after verified_end, so
     check passes — Applied. Pre-fix, the error region survives. *)
  let resp = rcall_tool r "undo" in
  assert_applied resp;
  let err_after = read_error r in
  if err_after <> `Null then
    E2e_harness.fail
      (Printf.sprintf "error region survived undo (regression): %s"
        (Yojson.Safe.to_string err_after));
  let buf_after = read_buffer r in
  if buf_after <> pre_buf then
    E2e_harness.fail
      (Printf.sprintf "buffer not restored after undo: \
                       expected=%S got=%S" pre_buf buf_after);
  Printf.printf "  undo cleared error region\n";
  Unix.close r.fd

(* --- Subtest 4: an edit AT or AFTER err_end does not clear the error.

   Per docs/REGION_INVARIANTS.md, the error region should only be
   cleared when its bytes change or its offsets shift. An insertion at
   exactly err_end appends after the error region — bytes inside are
   untouched and at the same offsets — so the highlight commitment is
   still valid and must survive. This locks in the precision of the
   centralized clearing logic. *)

let test_edit_after_error_preserves_it s =
  let r = rconnect s.E2e_harness.socket_path in
  rinitialize r;
  let pre_buf = read_buffer r in
  let proof_end = try
      let off = Str.search_forward (Str.regexp_string "Proof.") pre_buf 0 in
      off + String.length "Proof."
    with Not_found -> E2e_harness.fail "Proof. not in initial buffer" in
  verify_to_offset r proof_end;
  let pre_buf = read_buffer r in
  let _ = rcall_tool r "insert_text"
    ~args:(`Assoc [
      "offset", `Int (String.length pre_buf);
      "text", `String " badtactic.";
    ]) in
  let after_buf = read_buffer r in
  verify_to_offset r (String.length after_buf);
  let err_set = read_error r in
  let err_end = match err_set with
    | `Assoc fields ->
      (match List.assoc_opt "end" fields with
       | Some (`Int n) -> n
       | _ -> E2e_harness.fail "no end field in error")
    | _ -> E2e_harness.fail "expected error region to be set" in
  (* Edit at err_end exactly — appends a space after the error region.
     The byte at err_end is whitespace-friendly, so the boundary check
     (which only matters at vend, not err_end) doesn't reject it. *)
  let resp = rcall_tool r "insert_text"
    ~args:(`Assoc [
      "offset", `Int err_end;
      "text", `String " ";
    ]) in
  assert_applied resp;
  let err_after = read_error r in
  (match err_after with
   | `Null ->
     E2e_harness.fail
       "error region was cleared by an edit at err_end (over-clear)"
   | `Assoc fields ->
     (* Verify the range is unchanged. *)
     let new_end = match List.assoc_opt "end" fields with
       | Some (`Int n) -> n | _ -> -1 in
     if new_end <> err_end then
       E2e_harness.fail
         (Printf.sprintf "err_end shifted: was %d, now %d" err_end new_end)
   | _ -> E2e_harness.fail "unexpected error JSON shape");
  Printf.printf "  edit at err_end preserved error region\n";
  Unix.close r.fd

(* --- Test driver. Each subtest gets a fresh rocqtui process so they
   don't interfere via shared state. --- *)

let run_subtest name initial_source f =
  let s = E2e_harness.start ~rocq_source:initial_source () in
  let cleanup () = E2e_harness.stop s in
  try
    f s;
    cleanup ()
  with e ->
    Printf.eprintf "FAIL %s: %s\n%s\n" name
      (Printexc.to_string e) (Printexc.get_backtrace ());
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1

let () =
  Printexc.record_backtrace true;
  run_subtest "undo into verified region" ""
    test_undo_into_verified;
  run_subtest "redo into verified region"
    "Lemma t : True. Proof. trivial. Qed.\n"
    test_redo_into_verified;
  run_subtest "Applied undo clears error region"
    "Lemma t : True. Proof.\n"
    test_undo_clears_error;
  run_subtest "edit at err_end preserves error region"
    "Lemma t : True. Proof.\n"
    test_edit_after_error_preserves_it;
  print_endline "OK: undo/redo enforce invariants and clear error region"
