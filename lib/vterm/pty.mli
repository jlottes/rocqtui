(** PTY management: spawn, buffered non-blocking writes, read, resize. *)

type t

val spawn : cmd:string -> args:string list -> env:(string * string) list
  -> w:int -> h:int -> t
(** Spawn a child process attached to a new PTY. The PTY master fd
    is set to non-blocking. [env] entries are appended to the
    inherited environment (as overrides). *)

val fd : t -> Unix.file_descr
(** The PTY master file descriptor for use with [Unix.select]. *)

val pid : t -> int
(** The child process PID. *)

val set_size : t -> w:int -> h:int -> unit
(** Update the PTY window size (sends TIOCSWINSZ). *)

val has_buffered : t -> bool
(** True if there is buffered write data waiting to be flushed. *)

val write : t -> string -> unit
(** Write data to the PTY. Non-blocking: if the fd would block,
    the data is buffered internally. *)

val flush_write : t -> unit
(** Attempt to flush buffered write data. Call when the PTY fd
    becomes writable (from select). *)

val read : t -> bytes -> int -> int -> int
(** Non-blocking read from the PTY. Returns 0 if no data available. *)

val close : t -> unit
(** Close the PTY and send SIGHUP to the child process group. *)
