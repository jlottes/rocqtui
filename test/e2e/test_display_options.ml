(* Display-options end-to-end test.

   Drives a proof to a known goal state, then queries goals twice via
   the bridge:
     - once with no display options (baseline)
     - once with display:{all:true} (Printing All)
   and asserts the rendered text differs. This is exactly the bug that
   went undetected: the bridge advertised a [display] argument on its
   proof tools but never plumbed it through, so the rendering didn't
   actually change. *)

let sample = "\
Definition id_nat (n : nat) : nat := n.

Lemma id_eq : forall n : nat, id_nat n = n.
Proof.
  intros n.
"

let prefix_through_intros =
  "Definition id_nat (n : nat) : nat := n. \
   Lemma id_eq : forall n : nat, id_nat n = n. \
   Proof. intros n."

let goals_after_proof_forward s ~display sentences =
  let args = `Assoc (
    ("sentences", `String sentences) ::
    (match display with
     | None -> []
     | Some d -> [("display", d)])
  ) in
  let r = E2e_harness.call_tool s "proof_forward" ~args in
  let result = E2e_harness.result_of r in
  let body = E2e_harness.structured_response result in
  match Yojson.Safe.Util.member "goals" body with
  | `String g -> g
  | _ ->
    E2e_harness.dump_logs s;
    E2e_harness.fail
      (Printf.sprintf "no goals string: %s" (Yojson.Safe.to_string body))

let proof_rewind s sentences =
  let args = `Assoc [
    "sentences", `String sentences;
    "delete", `Bool false;
  ] in
  let _ = E2e_harness.call_tool s "proof_rewind" ~args in
  ()

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;
    (* Drive past [intros n.] with no display override, capture goals. *)
    let baseline = goals_after_proof_forward s
      ~display:None prefix_through_intros in
    Printf.printf "baseline goals:\n%s\n" baseline;
    (* Rewind to start so we re-verify the same prefix with display
       applied. proof_rewind matches the tail of the verified region. *)
    proof_rewind s prefix_through_intros;
    let with_all = goals_after_proof_forward s
      ~display:(Some (`Assoc ["all", `Bool true]))
      prefix_through_intros in
    Printf.printf "with all=true goals:\n%s\n" with_all;
    E2e_harness.assert_not_equal_strings
      ~a:baseline ~b:with_all
      ~msg:"display:{all:true} should change goal rendering, but it didn't \
            — bridge isn't plumbing per-call display options through";
    print_endline "OK: display:{all:true} alters the rendered goal text";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
