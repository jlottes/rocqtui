(* Async subprocess runner for [rocq dep]. Mirrors lib/build.ml's
   select-loop pattern: spawn, set the stdout fd non-blocking, add it
   to the main loop's [select], drain on read-ready, parse on EOF.

   Only one subprocess can be in flight at a time; [refresh] kills and
   restarts an in-flight one so the latest request wins. *)

type inflight = {
  pid : int;
  fd : Unix.file_descr;       (* stdout of the subprocess *)
  buf : Stdlib.Buffer.t;      (* accumulates stdout for the parser *)
  project_file : string;      (* tagged onto each inflight so we can
                                 detect a stale finish for a since-
                                 retargeted project *)
}

type t = {
  mutable inflight : inflight option;
  mutable graph : Dep_graph.t option;
  mutable last_project_file : string option;
}

let create () =
  { inflight = None; graph = None; last_project_file = None }

let graph t = t.graph
let running t = t.inflight <> None

(* Best-effort: signal, then reap. Children of [rocq dep] are
   typically short-lived so SIGTERM is usually enough. *)
let stop_inflight t =
  match t.inflight with
  | None -> ()
  | Some i ->
    (try Unix.kill i.pid Sys.sigterm with _ -> ());
    (try ignore (Unix.waitpid [] i.pid) with _ -> ());
    (try Unix.close i.fd with _ -> ());
    t.inflight <- None

(* Spawn `rocq dep -f <basename>` with the project dir as CWD so the
   emitted paths are project-relative — matching File_listing's
   [rel_path] convention. *)
let spawn ~project_file =
  let project_dir = Filename.dirname project_file in
  let base = Filename.basename project_file in
  let (read_fd, write_fd) = Unix.pipe ~cloexec:true () in
  let devnull = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  match Unix.fork () with
  | 0 ->
    (* Child: chdir, redirect stdout to the pipe, stderr to /dev/null,
       exec rocq. The cloexec flags on read_fd / write_fd were set
       above; we have to dup2 stdout to the write end before exec, and
       the dup'd fd inherits cloexec=false. *)
    (try Unix.chdir project_dir with _ -> ());
    Unix.dup2 write_fd Unix.stdout;
    Unix.dup2 devnull Unix.stderr;
    Unix.close write_fd;
    Unix.close read_fd;
    Unix.close devnull;
    (try
       Unix.execvp "rocq" [| "rocq"; "dep"; "-f"; base |]
     with _ -> exit 127)
  | pid ->
    Unix.close write_fd;
    Unix.close devnull;
    Unix.set_nonblock read_fd;
    Some { pid; fd = read_fd; buf = Stdlib.Buffer.create 4096;
           project_file }

let refresh t ~project_file =
  stop_inflight t;
  t.last_project_file <- Some project_file;
  match
    try spawn ~project_file with _ -> None
  with
  | Some i -> t.inflight <- Some i
  | None -> ()

(* Re-run for whatever project_file was last passed to [refresh].
   No-op if [refresh] was never called. Convenient for invalidation
   from ProjectChanged events. *)
let refresh_last t =
  match t.last_project_file with
  | Some pf -> refresh t ~project_file:pf
  | None -> ()

let watch_fd t = match t.inflight with
  | Some i -> Some i.fd
  | None -> None

(* Drain the pipe; on EOF parse the accumulated output and update
   [graph]. Returns [true] if a new graph was installed. *)
let poll t =
  match t.inflight with
  | None -> false
  | Some i ->
    let chunk = Bytes.create 4096 in
    let done_ = ref false in
    let aborted = ref false in
    let keep_reading = ref true in
    while !keep_reading do
      try
        let n = Unix.read i.fd chunk 0 4096 in
        if n = 0 then begin
          done_ := true;
          keep_reading := false
        end
        else
          Stdlib.Buffer.add_subbytes i.buf chunk 0 n
      with
      | Unix.Unix_error (Unix.EAGAIN, _, _)
      | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) ->
        keep_reading := false
      | Unix.Unix_error (Unix.EINTR, _, _) -> ()
      | _ ->
        aborted := true;
        keep_reading := false
    done;
    if !done_ then begin
      (try ignore (Unix.waitpid [] i.pid) with _ -> ());
      (try Unix.close i.fd with _ -> ());
      t.inflight <- None;
      let g = Dep_graph.of_rocq_dep_output
        (Stdlib.Buffer.contents i.buf) in
      t.graph <- Some g;
      true
    end
    else if !aborted then begin
      (try Unix.kill i.pid Sys.sigterm with _ -> ());
      (try ignore (Unix.waitpid [] i.pid) with _ -> ());
      (try Unix.close i.fd with _ -> ());
      t.inflight <- None;
      false
    end
    else false

let close t = stop_inflight t
