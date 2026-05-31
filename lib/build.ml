(* Async build subprocess management.
   Spawns make, reads output non-blocking, reports to a callback. *)

type t = {
  pid : int;
  fd : Unix.file_descr;            (* stdout+stderr of subprocess *)
  mutable output : string list;    (* accumulated output lines, newest first *)
  mutable buf : string;            (* partial line buffer *)
  mutable finished : bool;
  mutable exit_code : int option;
  mutable finished_at : float option;
  description : string;            (* e.g. "make theory/groups.vo" *)
  project_dir : string;            (* CWD of the build subprocess *)
}

let active : t option ref = ref None

(* Incremented each time [start] succeeds. Lets viewers (e.g. the
   messages-pane Build sub-tab) notice "this is a different build"
   and drop state — selection, scroll — tied to the previous run. *)
let gen = ref 0
let generation () = !gen

(* Braille spinner frames for the status-bar build indicator. *)
let spinner_chars = [|
  "\xe2\xa0\x8b"; (* ⠋ *) "\xe2\xa0\x99"; (* ⠙ *)
  "\xe2\xa0\xb9"; (* ⠹ *) "\xe2\xa0\xb8"; (* ⠸ *)
  "\xe2\xa0\xbc"; (* ⠼ *) "\xe2\xa0\xb4"; (* ⠴ *)
  "\xe2\xa0\xa6"; (* ⠦ *) "\xe2\xa0\xa7"; (* ⠧ *)
|]
let spinner_frame = ref 0
let last_spinner_advance = ref 0.0
let spinner_interval = 0.08

(* How long to keep showing the ✓/✗ result after a build finishes. *)
let finished_indicator_lifetime = 4.0

let is_running () = match !active with
  | Some b -> not b.finished
  | None -> false

let description () = match !active with
  | Some b -> Some b.description
  | None -> None

let project_dir () = match !active with
  | Some b -> Some b.project_dir
  | None -> None

(* Start a build. Returns false if one is already running. *)
let start ~project_dir ~cmd ~args ~desc =
  if is_running () then false
  else begin
    (* Clear previous build *)
    active := None;
    (* Create pipe for stdout+stderr *)
    let (read_fd, write_fd) = Unix.pipe ~cloexec:true () in
    let pid = Unix.create_process cmd
      (Array.of_list (cmd :: args))
      Unix.stdin write_fd write_fd in
    Unix.close write_fd;
    Unix.set_nonblock read_fd;
    incr gen;
    active := Some {
      pid; fd = read_fd;
      output = []; buf = "";
      finished = false; exit_code = None;
      finished_at = None;
      description = desc;
      project_dir;
    };
    true
  end

(* Get the fd to watch in select, or None *)
let watch_fd () = match !active with
  | Some b when not b.finished -> Some b.fd
  | _ -> None

(* Read available data. Returns new lines added (for triggering re-render). *)
let poll () = match !active with
  | None -> false
  | Some b when b.finished -> false
  | Some b ->
    let chunk = Bytes.create 4096 in
    let changed = ref false in
    let keep_reading = ref true in
    while !keep_reading do
      (try
         let n = Unix.read b.fd chunk 0 4096 in
         if n = 0 then begin
           (* EOF — process done *)
           keep_reading := false;
           (* Flush remaining buffer *)
           if b.buf <> "" then begin
             b.output <- b.buf :: b.output;
             b.buf <- "";
             changed := true
           end;
           (* Reap child *)
           let (_, status) = Unix.waitpid [Unix.WNOHANG] b.pid in
           b.exit_code <- (match status with
             | Unix.WEXITED c -> Some c
             | Unix.WSIGNALED _ -> Some (-1)
             | Unix.WSTOPPED _ -> Some (-2));
           b.finished <- true;
           b.finished_at <- Some (Unix.gettimeofday ());
           (try Unix.close b.fd with _ -> ());
           (* Add exit status line *)
           let exit_msg = match b.exit_code with
             | Some 0 -> "=== Build finished successfully ==="
             | Some c -> Printf.sprintf "=== Build failed (exit %d) ===" c
             | None -> "=== Build finished ==="
           in
           b.output <- exit_msg :: b.output;
           changed := true
         end else begin
           let data = b.buf ^ Bytes.sub_string chunk 0 n in
           let lines = String.split_on_char '\n' data in
           let rec process = function
             | [] -> b.buf <- ""
             | [last] -> b.buf <- last  (* incomplete line *)
             | line :: rest ->
               b.output <- line :: b.output;
               changed := true;
               process rest
           in
           process lines
         end
       with
       | Unix.Unix_error (Unix.EAGAIN, _, _) -> keep_reading := false
       | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) -> keep_reading := false
       | Unix.Unix_error (Unix.EINTR, _, _) -> ()  (* retry *)
       | _ -> keep_reading := false)
    done;
    !changed

(* Get output lines in order (oldest first). *)
let output () = match !active with
  | None -> []
  | Some b -> List.rev b.output

(* Cancel the running build. *)
let cancel () = match !active with
  | None -> ()
  | Some b when b.finished -> ()
  | Some b ->
    (try Unix.kill b.pid Sys.sigterm with _ -> ());
    (* Give it a moment, then force kill *)
    (try Unix.kill b.pid Sys.sigkill with _ -> ());
    (try
       let (_, _) = Unix.waitpid [] b.pid in ()
     with _ -> ());
    b.finished <- true;
    b.exit_code <- Some (-1);
    b.finished_at <- Some (Unix.gettimeofday ());
    b.output <- "=== Build cancelled ===" :: b.output;
    (try Unix.close b.fd with _ -> ())

(* Clear the build state (after it's finished). *)
let clear () =
  match !active with
  | Some b when b.finished -> active := None
  | _ -> ()

(* Derive the make target (.vo) from a .v file path, relative to project dir. *)
let vo_target ~project_dir v_path =
  let prefix = project_dir ^ "/" in
  let prefix_len = String.length prefix in
  let rel = if String.length v_path > prefix_len
               && String.sub v_path 0 prefix_len = prefix then
    String.sub v_path prefix_len (String.length v_path - prefix_len)
  else v_path in
  if Filename.check_suffix rel ".v" then
    Filename.chop_suffix rel ".v" ^ ".vo"
  else rel ^ "o"

(* Build a specific .v file via make. *)
let build_file ~project_dir v_path =
  let target = vo_target ~project_dir v_path in
  let desc = Printf.sprintf "make %s" target in
  start ~project_dir ~cmd:"make"
    ~args:["-C"; project_dir; target] ~desc

(* Build all via make. *)
let build_all ~project_dir =
  start ~project_dir ~cmd:"make"
    ~args:["-C"; project_dir] ~desc:"make"

(* Run make clean. *)
let build_clean ~project_dir =
  start ~project_dir ~cmd:"make"
    ~args:["-C"; project_dir; "clean"] ~desc:"make clean"

(* Get the project-relative .v path *)
let rel_path ~project_dir path =
  let prefix = project_dir ^ "/" in
  let plen = String.length prefix in
  if String.length path > plen && String.sub path 0 plen = prefix then
    String.sub path plen (String.length path - plen)
  else path

(* Parse `rocq dep` output to get direct .vo dependencies of a .v file.
   Returns project-local .vo targets (relative to project_dir). *)
let get_deps ~project_dir v_path =
  let rel_v = rel_path ~project_dir v_path in
  let target = Filename.chop_suffix rel_v ".v" ^ ".vo" in
  let ic = Unix.open_process_in
    (Printf.sprintf "cd %s && rocq dep -f _RocqProject %s 2>/dev/null"
       (Filename.quote project_dir) (Filename.quote rel_v)) in
  let deps = ref [] in
  (try while true do
     let line = input_line ic in
     if String.length line > String.length target
        && String.sub line 0 (String.length target) = target then begin
       match String.index_opt line ':' with
       | Some colon ->
         let after = String.sub line (colon + 1)
                       (String.length line - colon - 1) in
         List.iter (fun p ->
           let p = String.trim p in
           if p <> "" && Filename.check_suffix p ".vo"
              && String.length p > 0 && p.[0] <> '/' then
             deps := p :: !deps
         ) (String.split_on_char ' ' after)
       | None -> ()
     end
   done with End_of_file -> ());
  ignore (Unix.close_process_in ic);
  List.rev !deps

(* Build dependencies of a .v file (but not the file itself). *)
let build_deps ~project_dir v_path =
  let deps = get_deps ~project_dir v_path in
  if deps = [] then begin
    active := Some {
      pid = 0; fd = Unix.stdin; (* dummy *)
      output = ["No dependencies to build."];
      buf = ""; finished = true; exit_code = Some 0;
      finished_at = Some (Unix.gettimeofday ());
      description = "deps (none)";
      project_dir;
    };
    true
  end else
    let desc = Printf.sprintf "make %d deps" (List.length deps) in
    start ~project_dir ~cmd:"make"
      ~args:(["-C"; project_dir] @ deps) ~desc

(* True while a build is running, or while the post-build ✓/✗ indicator
   is still visible. Main loop uses this to keep requesting renders so the
   spinner animates and the result indicator times out cleanly. *)
let needs_repaint () = match !active with
  | None -> false
  | Some b when not b.finished -> true
  | Some b ->
    (match b.finished_at with
     | Some t -> Unix.gettimeofday () -. t < finished_indicator_lifetime
     | None -> false)

(* Status-bar indicator: spinner + description while running, ✓/✗
   briefly after finish, empty when no build. *)
let status_indicator () = match !active with
  | None -> ""
  | Some b when not b.finished ->
    let now = Unix.gettimeofday () in
    if now -. !last_spinner_advance >= spinner_interval then begin
      spinner_frame := (!spinner_frame + 1) mod Array.length spinner_chars;
      last_spinner_advance := now
    end;
    Printf.sprintf "%s %s" spinner_chars.(!spinner_frame) b.description
  | Some b ->
    (match b.finished_at with
     | Some t when Unix.gettimeofday () -. t < finished_indicator_lifetime ->
       (match b.exit_code with
        | Some 0 -> Printf.sprintf "\xe2\x9c\x93 %s" b.description
        | Some (-1) -> Printf.sprintf "\xe2\x9c\x97 %s (cancelled)" b.description
        | Some c -> Printf.sprintf "\xe2\x9c\x97 %s (exit %d)" b.description c
        | None -> Printf.sprintf "\xe2\x9c\x97 %s" b.description)
     | _ -> "")
