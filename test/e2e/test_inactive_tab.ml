(* Regression test: mutating bridge tools must act on the addressed
   tab, not the active one. Backward verify_to / proof_rewind on a
   non-active tab used to silently no-op — the inner go_to_offset and
   delete_range calls dropped the [tab] argument and landed on the
   active tab — returning success-shaped responses with stale
   proof_status (mcp-feedback 2026-06-12). *)

let sample = "\
Definition a1 : nat := 1.
Definition a2 : nat := 2.
"

let body_of r =
  let result = E2e_harness.result_of r in
  E2e_harness.structured_response result

let read_resource s uri =
  let r = E2e_harness.request s "resources/read"
    ~params:(`Assoc ["uri", `String uri]) in
  let open Yojson.Safe.Util in
  r |> member "result" |> member "contents" |> index 0 |> member "text"
    |> to_string

let last_sentence body =
  match Yojson.Safe.Util.member "last_sentence" body with
  | `String s -> Some s
  | _ -> None

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;

    (* Verify both sentences in sample.v (tab 0, currently active). *)
    let _ = E2e_harness.call_tool s "proof_forward"
      ~args:(`Assoc [
        "tab", `Int 0;
        "sentences", `String
          "Definition a1 : nat := 1. Definition a2 : nat := 2.";
      ]) in

    (* Open a second file; it becomes the active tab, leaving tab 0
       inactive with its boundary at EOF. *)
    let other_path = Filename.concat s.tmpdir "other.v" in
    let oc = open_out other_path in
    output_string oc "Definition b1 : nat := 1.\n";
    close_out oc;
    let r = E2e_harness.call_tool s "open_file"
      ~args:(`Assoc ["filename", `String other_path]) in
    let other_tab = match Yojson.Safe.Util.member "tab" (body_of r) with
      | `Int n -> n
      | _ -> E2e_harness.fail "open_file response missing tab id"
    in

    (* Retract the inactive tab's boundary to just before a2. *)
    let r = E2e_harness.call_tool s "verify_to"
      ~args:(`Assoc [
        "tab", `Int 0;
        "before_text", `String "Definition a2";
      ]) in
    (match last_sentence (body_of r) with
     | Some "Definition a1 : nat := 1." -> ()
     | ls -> E2e_harness.fail (Printf.sprintf
         "backward verify_to on inactive tab did not retract: \
          last_sentence = %s"
         (match ls with Some s -> Printf.sprintf "%S" s | None -> "null")));

    (* The active tab must be untouched: nothing verified there. *)
    let other_status = Yojson.Safe.from_string (read_resource s
      (Printf.sprintf "rocqtui://proof_status?tab=%d" other_tab)) in
    (match last_sentence other_status with
     | None -> ()
     | Some ls -> E2e_harness.fail (Printf.sprintf
         "active tab boundary moved by call addressed to tab 0: \
          last_sentence = %S" ls));

    (* proof_rewind with delete:false on the inactive tab: boundary
       retracts past a1, text stays in the buffer. *)
    let r = E2e_harness.call_tool s "proof_rewind"
      ~args:(`Assoc [
        "tab", `Int 0;
        "sentences", `String "Definition a1 : nat := 1.";
        "delete", `Bool false;
      ]) in
    let body = body_of r in
    (match last_sentence body with
     | None -> ()
     | Some ls -> E2e_harness.fail (Printf.sprintf
         "proof_rewind on inactive tab did not retract: \
          last_sentence = %S" ls));
    (match Yojson.Safe.Util.member "rewound_text" body with
     | `String t ->
       E2e_harness.assert_contains ~haystack:t ~needle:"Definition a1"
     | j -> E2e_harness.fail (Printf.sprintf "rewound_text: %s"
         (Yojson.Safe.to_string j)));
    let buf0 = read_resource s "rocqtui://buffer?tab=0" in
    E2e_harness.assert_contains ~haystack:buf0 ~needle:"Definition a1";
    E2e_harness.assert_contains ~haystack:buf0 ~needle:"Definition a2";

    print_endline "OK: backward verify_to / proof_rewind act on the \
                   addressed (inactive) tab; active tab untouched";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
