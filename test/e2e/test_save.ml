(* End-to-end test for the save bridge tool.

   Verifies that buffer mutations don't reach disk until [save] is
   called, and that [save] writes the current buffer to the file on
   disk. *)

let initial_source = ""

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.unsafe_to_string buf

let () =
  let s = E2e_harness.start ~rocq_source:initial_source () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;
    let v_path = Filename.concat s.tmpdir "sample.v" in

    (* Disk should match the initial source. *)
    if read_file v_path <> initial_source then
      E2e_harness.fail "disk file != initial source at start";

    (* Insert a lemma into the buffer (in-memory only). *)
    let lemma = "Lemma triv : True. Proof. trivial. Qed." in
    let _ = E2e_harness.call_tool s "proof_insert"
      ~args:(`Assoc ["text", `String lemma]) in

    (* Disk should still be unchanged — we haven't saved yet. *)
    let on_disk_before = read_file v_path in
    if try ignore (Str.search_forward (Str.regexp_string "Lemma triv")
                     on_disk_before 0); true
       with Not_found -> false
    then
      E2e_harness.fail
        (Printf.sprintf "buffer leaked to disk before save: %S" on_disk_before);

    (* Save and verify the disk now reflects the buffer. *)
    let _ = E2e_harness.call_tool s "save" in
    let on_disk_after = read_file v_path in
    E2e_harness.assert_contains ~haystack:on_disk_after ~needle:"Lemma triv";
    E2e_harness.assert_contains ~haystack:on_disk_after ~needle:"trivial";
    Printf.printf "  on disk after save: %S\n" (String.trim on_disk_after);

    print_endline "OK: save commits the buffer to disk; \
                   pre-save disk content is preserved";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
