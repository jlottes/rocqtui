(* End-to-end test for Alt+. interrupt recovery.

   Fixture: an infinite Ltac tactic in the middle of a multi-theorem
   file. The user verifies the whole buffer, the [loop] tactic hangs
   coqtop, the user interrupts, then edits the proof body and asks
   to verify again. Without the fix path in [Session.interrupt] +
   [advance_rewinding_op]'s defensive [edit_at] retry, the recovery
   path can leave rocqtui's [t.tip] out of sync with coqtop's
   [VCS.cur_tip] — the next [Add] surfaces "Stm.add called for a
   different state … than the tip: …".

   This is a smoke test: the precise race condition (Sys.Break
   landing where [catch_break=false], poisoning [Control.interrupt])
   isn't always triggerable externally. But the recovery flow as a
   whole should be robust under the fix, and a "different state"
   message in the post-interrupt state is a hard signal of regression. *)

let sample =
  String.concat "\n" [
    "Ltac loop := idtac; loop.";
    "";
    "Theorem hangs : True.";
    "Proof.";
    "loop.";
    "Qed.";
    "";
    "Theorem after : True.";
    "Proof.";
    "exact I.";
    "Qed.";
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
        "name", `String "rocqtui-e2e-interrupt-recovery";
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

(* Wait until either the session is idle, the verified_end has been
   stable for [stable_for], or we hit [timeout]. The stability
   check is how we detect "execution is hung on the current
   sentence" — verified_end stops advancing while is_busy stays
   true. *)
let wait_for_hang_or_idle r ~timeout ~stable_for =
  let deadline = Unix.gettimeofday () +. timeout in
  let last_ve = ref (-1) in
  let last_change = ref (Unix.gettimeofday ()) in
  let rec loop () =
    let st = read_state r in
    let ve = verified_end_of st in
    let now = Unix.gettimeofday () in
    if ve <> !last_ve then begin
      last_ve := ve;
      last_change := now
    end;
    if not (busy_of st) then st
    else if now > deadline then st
    else if !last_ve >= 0 && now -. !last_change > stable_for then st
    else begin
      Unix.sleepf 0.05;
      loop ()
    end
  in
  loop ()

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

(* True if any message in [msgs] looks like coqtop's tip-mismatch
   complaint. The exact text is a patched assertion in stm.ml. *)
let has_tip_mismatch_msg msgs =
  let needle = "different state" in
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

    (* Step 1: ask for verification through end-of-buffer. coqtop
       will verify the Ltac def, the theorem statement, [Proof.],
       and then hang on [loop.]. *)
    let buf_len = String.length sample in
    let _ = rcall_tool r "go_to_offset"
      ~args:(`Assoc ["offset", `Int buf_len]) in

    (* Step 2: wait until verified_end is stable (== loop has
       started executing) or we've exhausted the budget. *)
    let pre_int = wait_for_hang_or_idle r ~timeout:5.0 ~stable_for:0.4 in
    Printf.printf "  pre-interrupt: busy=%b verified_end=%d\n"
      (busy_of pre_int) (verified_end_of pre_int);

    (* Step 3: send interrupt. This calls Session.interrupt: SIGINT
       + Status drain. *)
    let _ = rcall_tool r "interrupt" in

    (* Step 4: wait for the session to settle. *)
    let post_int = wait_idle r ~timeout:5.0 in
    let post_msgs = messages_of post_int in
    Printf.printf "  post-interrupt: busy=%b verified_end=%d msgs=%d\n"
      (busy_of post_int) (verified_end_of post_int) (List.length post_msgs);
    if busy_of post_int then
      E2e_harness.fail
        "session never settled within 5s after interrupt";
    if has_tip_mismatch_msg post_msgs then
      E2e_harness.fail
        "tip-mismatch message appeared in post-interrupt state \
         (Session.interrupt drain or rewind-retry failed to keep \
         rocqtui's t.tip aligned with coqtop's VCS.cur_tip)";

    (* Step 5: edit the proof body so [loop.] no longer hangs, then
       ask to verify again. If t.tip and cur_tip are still aligned,
       the next [Add] proceeds normally; if not, coqtop rejects the
       Add with the "different state" message. *)
    (* Find the proof-body occurrence of [loop.] (the literal also
       appears in the Ltac def's RHS — match the one bracketed by
       newlines so we hit the call site, not the definition). *)
    let needle = "\nloop.\n" in
    let n_start = Str.search_forward (Str.regexp_string needle) sample 0 in
    let loop_start = n_start + 1 in
    let loop_end = loop_start + String.length "loop." in
    let replacement = "exact I." in
    let replace_resp = rcall_tool r "replace_range"
      ~args:(`Assoc [
        "start", `Int loop_start;
        "end", `Int loop_end;
        "text", `String replacement;
      ]) in
    (match Yojson.Safe.Util.member "result" replace_resp
           |> Yojson.Safe.Util.member "isError" with
     | `Bool true ->
       E2e_harness.fail
         "replace_range was rejected — edit landed inside the \
          verified region (test bug or unexpected verified_end)"
     | _ -> ());
    let new_len = buf_len - String.length "loop." + String.length replacement in
    let _ = rcall_tool r "go_to_offset"
      ~args:(`Assoc ["offset", `Int new_len]) in
    let post_verify = wait_idle r ~timeout:10.0 in
    let final_msgs = messages_of post_verify in
    Printf.printf "  post-verify: busy=%b verified_end=%d msgs=%d\n"
      (busy_of post_verify) (verified_end_of post_verify)
      (List.length final_msgs);
    if busy_of post_verify then
      E2e_harness.fail
        "session never settled within 10s after re-verify";
    if has_tip_mismatch_msg final_msgs then
      E2e_harness.fail
        "tip-mismatch message appeared in post-recovery verify — \
         rocqtui's t.tip drifted from coqtop's VCS.cur_tip across \
         the interrupt + rewind";

    print_endline "OK: interrupt + edit + re-verify keeps t.tip aligned with coqtop";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
