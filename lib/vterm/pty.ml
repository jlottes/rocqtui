(* PTY management: spawn, buffered non-blocking writes, read, resize. *)

type t = {
  fd : Unix.file_descr;
  pid : int;
  mutable write_buf : Buffer.t;
  mutable closed : bool;
}

external pty_open_raw : string -> string array -> string array
  -> int -> int -> int * int
  = "caml_pty_open"

external pty_set_size_raw : int -> int -> int -> unit
  = "caml_pty_set_size"

let spawn ~cmd ~args ~env ~w ~h =
  let env_strings = List.map (fun (k, v) -> k ^ "=" ^ v) env in
  let fd_int, pid = pty_open_raw cmd
    (Array.of_list args)
    (Array.of_list env_strings)
    w h
  in
  let fd = (Obj.magic fd_int : Unix.file_descr) in
  { fd; pid; write_buf = Buffer.create 0; closed = false }

let fd t = t.fd
let pid t = t.pid

let set_size t ~w ~h =
  if not t.closed then
    pty_set_size_raw (Obj.magic t.fd : int) w h

let has_buffered t = Buffer.length t.write_buf > 0

let write t s =
  if t.closed then ()
  else if Buffer.length t.write_buf > 0 then
    (* Already have buffered data, just append *)
    Buffer.add_string t.write_buf s
  else begin
    (* Try to write directly first *)
    let len = String.length s in
    let written =
      try
        let n = Unix.single_write_substring t.fd s 0 len in
        n
      with
      | Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> 0
      | Unix.Unix_error (EINTR, _, _) -> 0
    in
    if written < len then begin
      Buffer.add_substring t.write_buf s written (len - written)
    end
  end

let flush_write t =
  if t.closed || Buffer.length t.write_buf = 0 then ()
  else begin
    let s = Buffer.contents t.write_buf in
    let len = String.length s in
    let written =
      try Unix.single_write_substring t.fd s 0 len
      with
      | Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> 0
      | Unix.Unix_error (EINTR, _, _) -> 0
    in
    if written >= len then
      Buffer.clear t.write_buf
    else begin
      let remaining = len - written in
      Buffer.clear t.write_buf;
      Buffer.add_substring t.write_buf s written remaining
    end
  end

let read t buf ofs len =
  if t.closed then 0
  else
    try Unix.read t.fd buf ofs len
    with
    | Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> 0
    | Unix.Unix_error (EINTR, _, _) -> 0

let close t =
  if not t.closed then begin
    t.closed <- true;
    (try Unix.close t.fd with Unix.Unix_error _ -> ());
    (* Send SIGHUP to the process group *)
    (try Unix.kill (- t.pid) Sys.sighup with Unix.Unix_error _ -> ());
    (* Reap *)
    (try ignore (Unix.waitpid [WNOHANG] t.pid) with Unix.Unix_error _ -> ())
  end
