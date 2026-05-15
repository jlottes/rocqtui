(* Diagnostic log file for the AI subsystem. Opt-in via the
   AI_DEBUG_LOG env var:

     AI_DEBUG_LOG=/tmp/rocqtui-ai.log dune exec bin/main.exe -- ...

   When unset, [log] is a zero-cost no-op (Printf.ifprintf consumes
   format args without producing output). *)

let oc =
  match Sys.getenv_opt "AI_DEBUG_LOG" with
  | None -> None
  | Some path ->
    try
      let ch = open_out_gen [Open_wronly; Open_creat; Open_append] 0o644 path in
      Printf.fprintf ch "--- session started %.3f ---\n%!"
        (Unix.gettimeofday ());
      Some ch
    with _ -> None

let enabled = oc <> None

let log fmt =
  match oc with
  | None -> Printf.ifprintf stderr fmt
  | Some ch ->
    let t = Unix.gettimeofday () in
    Printf.fprintf ch "%.3f " t;
    Printf.kfprintf (fun ch -> output_char ch '\n'; flush ch) ch fmt
