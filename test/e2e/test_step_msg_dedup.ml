(* End-to-end test that stepping past a single failing sentence
   produces exactly one user-visible message.

   Background: when a [Lemma] statement Adds successfully but rocq
   then sends an Error feedback (e.g. a universe-binding conflict),
   we end up with [has_error = true] in the session. The next poll:

     1. Rewinds back to the verified prefix (Op_rewinding succeeds).
     2. Notices [goals_dirty] and runs Op_refreshing_goals at the
        new tip.

   When rocq's universe state is corrupted by the prior elaboration,
   the [Goals] call in step 2 also Fails with the same wording.
   Pre-fix, the Op_refreshing_goals Fail handler appended that to
   [t.msgs] — so the user saw "X is already used." twice for one
   step. The fix: silently drop [goals_cache] without echoing the
   message; the actual error from the Add is already in [t.msgs]. *)

let sample = "\
Section S.
  Universes u.
  Context (X : Type@{u}).

  Lemma L1 (X : Type) : forall x : X, x = x.
End S.
"

(* Direct rocqtui MCP socket connection. *)

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
        "name", `String "rocqtui-e2e-step-msg-dedup";
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
    else begin Unix.sleepf 0.05; loop () end
  in
  loop ()

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    let r = rconnect s.E2e_harness.socket_path in
    rinitialize r;

    (* Step past the three Verified sentences (Section, Universes,
       Context). After each, drain to idle so the next step starts
       from a clean point. *)
    for _ = 1 to 3 do
      let _ = rcall_tool r "step_forward" ~args:(`Assoc []) in
      let _ = wait_idle r ~timeout:5.0 in
      ()
    done;

    (* Now the next step crosses the failing Lemma statement. *)
    let _ = rcall_tool r "step_forward" ~args:(`Assoc []) in
    let st = wait_idle r ~timeout:5.0 in

    let open Yojson.Safe.Util in
    let msgs = st |> member "messages" |> to_list in
    let msg_strings = List.map (function
      | `String s -> s | _ -> "") msgs in

    (* Exactly one user-facing message expected: the rocq error. *)
    Printf.printf "  step past failing lemma: msgs=%d\n" (List.length msgs);
    List.iteri (fun i m -> Printf.printf "    [%d] %s\n" i m) msg_strings;

    let expected_substring = "X is already used" in
    let n_matches = List.fold_left (fun acc m ->
      let n = String.length expected_substring in
      let h = String.length m in
      let rec contains i =
        if i + n > h then false
        else if String.sub m i n = expected_substring then true
        else contains (i + 1)
      in
      if contains 0 then acc + 1 else acc) 0 msg_strings
    in
    if n_matches <> 1 then
      E2e_harness.fail
        (Printf.sprintf
          "expected exactly 1 'X is already used' message, got %d \
           (likely the goals-refresh Fail handler is echoing the \
           rocq error a second time)"
          n_matches);

    print_endline "OK: stepping past one failing lemma yields exactly \
                   one user-facing message";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
