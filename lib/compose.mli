(** XCompose input method. *)

type t

(** Load compose sequences from ~/.XCompose (with includes). *)
val load : unit -> t

(** Result of feeding a key to the compose state. *)
type result =
  | Pending    (** More keys needed *)
  | Composed of string  (** Matched — output this string *)
  | NoMatch    (** No sequence matches — abort compose mode *)

(** Start a new compose sequence. *)
val start : t -> unit

(** Feed a curses key code into the compose state.
    Returns [Pending], [Composed text], or [NoMatch]. *)
val feed : t -> int -> result

(** Whether we're currently in a compose sequence. *)
val active : t -> bool

(** Get the keys pressed so far in the current compose sequence. *)
val keys_so_far : t -> int list

(** Get completions reachable from the current cursor node.
    Returns list of (remaining_keys, output_text). *)
val completions : t -> (int list * string) list

(** Reverse lookup: given buffer text [s] and a byte [offset], return
    [Some (matched_byte_len, alternatives)] for the longest compose
    output that starts at that byte position, where [alternatives] is
    the list of key sequences that produce it.  [None] if nothing
    matches. *)
val reverse_lookup : t -> string -> int -> (int * int list list) option

(** Human-readable name for a key code as stored in compose sequences
    (e.g. [27] -> ["ESC"], [Char.code 'a'] -> ["a"]). *)
val key_name : int -> string
