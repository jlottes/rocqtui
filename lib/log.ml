let start = Unix.gettimeofday ()

let resolve_path () =
  match Sys.getenv_opt "ROCQTUI_LOG" with
  | None | Some ("" | "0" | "false" | "no") -> None
  | Some ("1" | "true" | "yes") -> Some "/tmp/rocqtui.log"
  | Some path -> Some path

let oc : out_channel option Lazy.t = lazy (
  match resolve_path () with
  | None -> None
  | Some path ->
    (try
       let oc = open_out path in
       let tm = Unix.localtime start in
       Printf.fprintf oc
         "=== rocqtui log start pid=%d %04d-%02d-%02d %02d:%02d:%02d ===\n%!"
         (Unix.getpid ())
         (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
         tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec;
       Some oc
     with Sys_error _ -> None))

let enabled () = Lazy.force oc <> None

let emit s =
  match Lazy.force oc with
  | None -> ()
  | Some oc ->
    Printf.fprintf oc "T+%8.3f %s\n%!" (Unix.gettimeofday () -. start) s

let logf fmt =
  match Lazy.force oc with
  | Some _ -> Printf.ksprintf emit fmt
  | None -> Printf.ifprintf () fmt
