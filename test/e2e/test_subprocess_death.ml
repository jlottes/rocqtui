(* End-to-end test for graceful handling of rocqtop subprocess death.

   If rocqtop dies mid-session (OOM, crash, manual kill, runaway loop
   that gets SIGKILLed), the next write to its stdin fails with
   Sys_error "bad fd" / EOF. Pre-fix, that exception propagated up
   through dispatch_head into the main loop and tore down rocqtui.

   Fix: wrap the write in dispatch_head and on failure mark the
   protocol dead, replying [Fail] to every queued caller and to any
   future [submit] without trying to write again.

   This test:
   1. Spawns rocqtui headless on a trivial buffer.
   2. Verifies one sentence so we know rocqtop is alive.
   3. Finds rocqtop's pid via /proc/<rocqtui_pid>/task/.../children.
   4. SIGKILLs it.
   5. Asks rocqtui to verify another sentence and to read state.
   6. Asserts: rocqtui still responds (didn't crash). *)

let sample = "\
Definition a := 0.
Definition b := 1.
Definition c := 2.
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
        "name", `String "rocqtui-e2e-subprocess-death";
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

(* Read rocqtui's child PIDs from /proc. There's exactly one child
   per session — the rocqtop subprocess. *)
let find_rocq_pid rocqtui_pid =
  let path = Printf.sprintf "/proc/%d/task/%d/children" rocqtui_pid rocqtui_pid in
  let ic = open_in path in
  let line = try input_line ic with End_of_file -> "" in
  close_in ic;
  match String.split_on_char ' ' (String.trim line) with
  | pid_str :: _ when pid_str <> "" -> int_of_string pid_str
  | _ -> failwith (Printf.sprintf "no children listed in %s" path)

let () =
  let s = E2e_harness.start ~rocq_source:sample () in
  let cleanup () = E2e_harness.stop s in
  try
    let r = rconnect s.E2e_harness.socket_path in
    rinitialize r;

    (* Verify the first definition so rocqtop is fully started. *)
    let _ = rcall_tool r "go_to_offset"
      ~args:(`Assoc ["offset", `Int (String.length "Definition a := 0.\n")]) in
    let _ = wait_idle r ~timeout:5.0 in

    (* Kill rocqtop directly. *)
    let rocq_pid = find_rocq_pid s.E2e_harness.rocqtui_pid in
    Printf.printf "  rocqtop pid: %d (rocqtui pid: %d)\n"
      rocq_pid s.E2e_harness.rocqtui_pid;
    Unix.kill rocq_pid Sys.sigkill;
    (* Give the kernel a moment to deliver SIGKILL and rocqtui's main
       loop a chance to notice the closed pipe. *)
    Unix.sleepf 0.2;

    (* Drive verification past where we already were. The submit
       should not crash rocqtui — it should either return Fail
       (synthesized "rocq subprocess died") or no-op. *)
    let _ = rcall_tool r "go_to_offset"
      ~args:(`Assoc ["offset", `Int (String.length sample)]) in
    let st = wait_idle r ~timeout:3.0 in

    (* Sanity: rocqtui responded to the state read at all. The point
       of the test is that none of these calls deadlocked or hit a
       Sys_error that took down the whole process. *)
    let open Yojson.Safe.Util in
    Printf.printf "  post-kill: verified_end=%d is_busy=%b\n"
      (st |> member "verified_end" |> to_int) (busy_of st);

    (* And one more round-trip to confirm rocqtui is still alive. *)
    let r2 = rcall_tool r "is_busy" ~args:(`Assoc []) in
    let _ = E2e_harness.result_of r2 in

    print_endline "OK: rocqtui survives rocqtop subprocess death \
                   without crashing";
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
