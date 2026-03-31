(** Modal manager: variant stack replacing scattered boolean refs. *)

type kind =
  | Help of { mutable scroll : int }
  | QueryMenu
  | OptionsMenu
  | ThemeMenu
  | BuildMenu
  | FilePicker

type t

val create : unit -> t
val top : t -> kind option
val is_active : t -> bool
val push : t -> kind -> unit
val pop : t -> unit
val toggle : t -> kind -> unit
val is_open : t -> kind -> bool
val clear : t -> unit

(** Dismiss top modal. Returns true if something was dismissed. *)
val dismiss : t -> bool
