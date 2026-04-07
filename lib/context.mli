(** Sentence-aligned context extraction for MCP responses. *)

(** Check if text at [start] begins with a proof-introducing command
    (Lemma, Theorem, etc.). *)
val is_proof_command : string -> int -> bool

(** Find the byte offset where the proof-introducing sentence starts,
    scanning backward from [boundary]. Returns None if not found. *)
val find_proof_start : string -> boundary:int -> int option

(** Extract complete sentences before [boundary].
    [min_bytes]: minimum context size (default 500).
    [has_goals]: if true, extend back to include the Lemma/Theorem
    sentence even if that's beyond [min_bytes]. *)
val before :
  string -> boundary:int -> ?min_bytes:int -> ?has_goals:bool -> unit -> string

(** Extract complete sentences after [boundary].
    [max_bytes]: maximum context size (default 200). *)
val after :
  string -> boundary:int -> ?max_bytes:int -> unit -> string

(** Get the text of the last verified sentence before [boundary].
    Returns None if no sentences precede the boundary. *)
val last_sentence : string -> boundary:int -> string option
