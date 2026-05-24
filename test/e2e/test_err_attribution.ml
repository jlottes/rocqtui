(* Regression: when verifying many sentences, an error mid-buffer
   used to be misattributed to a later sentence whose Add Failed as
   a cascade.

   Fixture: a Section that binds [X] via [Context], then a [Lemma]
   re-binding [X] in its parameters. Rocq accepts the Add for the
   Lemma (returns Good) but later sends an async Error feedback
   ("X is already used"). The subsequent [End S.] Add then Fails
   with its own complaint about [X]. The pre-fix behavior had the
   [End S.] Fail overwrite err_range and append a duplicate message,
   so the visible error highlight landed on [End S.] instead of the
   actual root cause [Lemma]. *)

let sample = "\
Section S.
  Universes u.
  Context (X : Type@{u}).
  Lemma L1 (X : Type) : forall x : X, x = x.
  Proof. reflexivity. Qed.
End S.
"

let needle = "Lemma L1 (X : Type) : forall x : X, x = x."

let needle_range () =
  let nlen = String.length needle in
  let rec find i =
    if i + nlen > String.length sample then None
    else if String.sub sample i nlen = needle then Some (i, i + nlen)
    else find (i + 1)
  in
  find 0

let proof_offset () =
  let n = "Proof." in
  let nl = String.length n in
  let rec find i =
    if i + nl > String.length sample then None
    else if String.sub sample i nl = n then Some i
    else find (i + 1)
  in
  find 0

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
        "name", `String "rocqtui-e2e-err-attribution";
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
    else if Unix.gettimeofday () > deadline then st
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

    let final = wait_idle r ~timeout:10.0 in
    let open Yojson.Safe.Util in
    let err = final |> member "error" in
    let (lemma_s, lemma_e) = match needle_range () with
      | Some r -> r
      | None -> E2e_harness.fail "needle lookup failed"
    in
    let proof_at = match proof_offset () with
      | Some p -> p
      | None -> E2e_harness.fail "Proof. offset lookup failed"
    in
    (match err with
     | `Assoc fields ->
       let s_off = List.assoc "start" fields |> to_int in
       let e_off = List.assoc "end" fields |> to_int in
       (* err_range should cover the Lemma sentence (root cause), not
          the later End-Section that Failed as a cascade. Allow
          leading whitespace per rocqtui's convention. Must not run
          into Proof. (which is the next sentence). *)
       if not (s_off <= lemma_s && e_off >= lemma_e && e_off <= proof_at) then
         E2e_harness.fail
           (Printf.sprintf
             "err_range=(%d,%d) does not cover the Lemma at (%d,%d); \
              expected end <= Proof. offset %d"
             s_off e_off lemma_s lemma_e proof_at)
     | _ -> E2e_harness.fail "state.error was null — no error reported");

    Printf.printf "  err_range covers root-cause Lemma: %s\n"
      (Yojson.Safe.to_string err);
    print_endline "OK: mid-buffer error attributed to actual bad sentence, \
                   not to the cascading End-Section";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
