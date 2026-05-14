(* End-to-end test for mid-file verification errors that produce
   un-undoable rocq states.

   The fixture: a Section binding [X] via Universes/Context, then
   three lemmas that re-bind [X] in their parameter list. Rocq
   accepts the [Add] for each lemma statement (so we get a state_id
   back), then sends an Error feedback ("X is already used"). The
   subsequent [Proof.] / [reflexivity.] / [Qed.] are added but
   produce no feedback — they sit Processing forever.

   When verification reaches end-of-section we end up with a stack
   like [P;P;P;E;P;P;P;E;P;P;P;E;V;V;V] (most-recent first). The
   error-recovery rewind tries [edit_at target] where target is the
   state of the sentence just below the topmost Error. Rocq returns
   [Fail (safe_id=Stateid.dummy, msg="X is already used.")] — it
   can't determine a safe state. The Fail handler used to leave
   [t.sentences] untouched (only adjusting [target_end]), so
   [has_error] stayed true and the next [poll] iteration tried the
   exact same rewind. Result: an infinite loop that piles up "Undo
   failed" messages and eventually kills the rocqtop subprocess.

   This test asserts the session settles in a bounded number of
   poll cycles and the "Undo failed" message count stays small. *)

let sample = "\
Section S.
  Universes u.
  Context (X : Type@{u}).

  Lemma L1 (X : Type) : forall x : X, x = x.
  Proof. reflexivity. Qed.

  Lemma L2 (X : Type) : forall x : X, x = x.
  Proof. reflexivity. Qed.

  Lemma L3 (X : Type) : forall x : X, x = x.
  Proof. reflexivity. Qed.
End S.
"

(* Direct rocqtui MCP socket connection (same pattern as
   test_undo_redo). *)

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

let rrecv r = Yojson.Safe.from_string (input_line r.ic)

let rcall r ?(params=`Null) method_ =
  let id = r.next_id in
  r.next_id <- id + 1;
  rsend r (`Assoc [
    "jsonrpc", `String "2.0";
    "id", `Int id;
    "method", `String method_;
    "params", params;
  ]);
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
        "name", `String "rocqtui-e2e-mid-file-error";
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

let read_state r =
  let resp = rcall r "resources/read"
    ~params:(`Assoc ["uri", `String "rocqtui://state"]) in
  let open Yojson.Safe.Util in
  let text = resp |> member "result" |> member "contents" |> index 0
                  |> member "text" |> to_string in
  Yojson.Safe.from_string text

let busy_of state =
  match Yojson.Safe.Util.member "is_busy" state with
  | `Bool b -> b | _ -> false

let wait_idle r ~timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    let st = read_state r in
    if not (busy_of st) then st
    else if Unix.gettimeofday () > deadline then st  (* return last state *)
    else begin
      Unix.sleepf 0.05;
      loop ()
    end
  in
  loop ()

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    let r = rconnect s.E2e_harness.socket_path in
    rinitialize r;

    let buf_len = String.length sample in
    let _ = rcall_tool r "go_to_offset"
      ~args:(`Assoc ["offset", `Int buf_len]) in

    (* Generous timeout — without the fix the cascade loops forever.
       With the fix, settling is essentially instant. *)
    let final = wait_idle r ~timeout:10.0 in
    let still_busy = busy_of final in
    if still_busy then
      E2e_harness.fail
        "session never settled within 10s — infinite cascade loop \
         (rewind keeps Failing on the same target_id)";

    let open Yojson.Safe.Util in
    let messages = final |> member "messages" |> to_list in
    let n_undo_failed = List.fold_left (fun acc m ->
      match m with
      | `String s ->
        let needle = "Undo failed" in
        let n = String.length needle in
        let h = String.length s in
        let rec contains i =
          if i + n > h then false
          else if String.sub s i n = needle then true
          else contains (i + 1)
        in
        if contains 0 then acc + 1 else acc
      | _ -> acc) 0 messages
    in
    if n_undo_failed > 1 then
      E2e_harness.fail
        (Printf.sprintf
          "expected at most 1 'Undo failed' message after settling, \
           got %d (cascade looped before terminating)"
          n_undo_failed);

    let sentences = final |> member "sentences" |> to_list in
    let buckets = List.fold_left (fun (e, p, v) sent ->
      match member "status" sent with
      | `String st when String.length st >= 6 && String.sub st 0 6 = "error:" ->
        (e + 1, p, v)
      | `String "processing" -> (e, p + 1, v)
      | `String "verified" -> (e, p, v + 1)
      | _ -> (e, p, v)) (0, 0, 0) sentences
    in
    let (n_error, n_processing, n_verified) = buckets in
    Printf.printf "  settled: sentences=%d (V=%d P=%d E=%d) undo_failed_msgs=%d\n"
      (List.length sentences) n_verified n_processing n_error n_undo_failed;

    print_endline "OK: un-undoable mid-file error breaks the cascade \
                   loop after one Fail";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
