(* End-to-end test for Add-Fail recovery.

   Fixture: a duplicate [Universes u.] inside a Section. Stepping
   forward verifies the first [Universes u.] (Add returns Good with a
   fresh sid), then attempting to Add the next sentence triggers
   async Error feedback on the duplicate ("Universe u already exists")
   and the Add itself returns Fail with safe_id pointing at the
   pre-duplicate state. coqtop's [VCS.cur_tip] stays at the failing
   sid; only an [edit_at] moves it back.

   Before the fix, [dispatch_idle_work]'s [needs_rewind] handler did
   a local sentence drop without issuing [edit_at]. t.tip and
   cur_tip drifted out of sync; the next user step hit
   "Stm.add called for a different state ... than the tip: ...". *)

let sample =
  String.concat "\n" [
    "Section S.";
    "Universes u.";
    "Universes u.";
    "Definition x : Type@{u} := nat.";
    "End S.";
    "";
  ]

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
        "name", `String "rocqtui-e2e-add-fail-recovery";
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

let verified_end_of state =
  match Yojson.Safe.Util.member "verified_end" state with
  | `Int n -> n | _ -> 0

let messages_of state =
  match Yojson.Safe.Util.member "messages" state with
  | `List ms -> List.filter_map (function `String s -> Some s | _ -> None) ms
  | _ -> []

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

let msgs_contain msgs needle =
  let needle_n = String.length needle in
  let contains s =
    let n = String.length s in
    let rec find i =
      if i + needle_n > n then false
      else if String.sub s i needle_n = needle then true
      else find (i + 1)
    in
    find 0
  in
  List.exists contains msgs

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    let r = rconnect s.E2e_harness.socket_path in
    rinitialize r;

    (* Step 1: ask to verify the whole buffer. The duplicate
       [Universes u.] will fail and recovery should land cleanly. *)
    let buf_len = String.length sample in
    let _ = rcall_tool r "go_to_offset"
      ~args:(`Assoc ["offset", `Int buf_len]) in
    let post_fail = wait_idle r ~timeout:10.0 in
    let post_fail_msgs = messages_of post_fail in
    Printf.printf "  post-fail: busy=%b verified_end=%d msgs=%d\n"
      (busy_of post_fail) (verified_end_of post_fail)
      (List.length post_fail_msgs);
    if busy_of post_fail then
      E2e_harness.fail
        "session never settled within 10s after initial verify";
    if not (msgs_contain post_fail_msgs "already exists") then
      E2e_harness.fail
        "expected 'Universe u already exists' in messages but didn't see it \
         — fixture isn't tripping the Add Fail path";
    if msgs_contain post_fail_msgs "different state" then
      E2e_harness.fail
        "tip-mismatch message appeared after Add Fail — \
         dispatch_idle_work's needs_rewind didn't issue edit_at";

    (* Step 2: edit out the duplicate and re-verify. If t.tip and
       cur_tip stayed in sync across the recovery, this proceeds; if
       not, the next Add hits "different state". *)
    let needle = "Universes u.\nUniverses u.\n" in
    let n_start = Str.search_forward (Str.regexp_string needle) sample 0 in
    let dup_start = n_start + String.length "Universes u.\n" in
    let dup_end = n_start + String.length needle in
    let _ = rcall_tool r "replace_range"
      ~args:(`Assoc [
        "start", `Int dup_start;
        "end", `Int dup_end;
        "text", `String "";
      ]) in
    let new_len = buf_len - (dup_end - dup_start) in
    let _ = rcall_tool r "go_to_offset"
      ~args:(`Assoc ["offset", `Int new_len]) in
    let post_fix = wait_idle r ~timeout:10.0 in
    let final_msgs = messages_of post_fix in
    Printf.printf "  post-fix:  busy=%b verified_end=%d msgs=%d\n"
      (busy_of post_fix) (verified_end_of post_fix)
      (List.length final_msgs);
    if busy_of post_fix then
      E2e_harness.fail
        "session never settled within 10s after re-verify";
    if msgs_contain final_msgs "different state" then
      E2e_harness.fail
        "tip-mismatch message appeared in post-recovery verify — \
         t.tip drifted from coqtop's VCS.cur_tip across the Add Fail";
    (* Without the fix, verified_end would stall at the
       pre-duplicate sentence because every Add gets rejected.
       With the fix, the rest of the buffer verifies — allow a few
       trailing bytes (whitespace / final newline) of slack. *)
    if verified_end_of post_fix < new_len - 2 then
      E2e_harness.fail
        (Printf.sprintf "post-fix verified_end=%d, buffer length %d \
                         (rest of buffer didn't verify cleanly)"
           (verified_end_of post_fix) new_len);

    print_endline "OK: Add Fail recovery keeps t.tip aligned with coqtop";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
