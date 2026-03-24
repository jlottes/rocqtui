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
