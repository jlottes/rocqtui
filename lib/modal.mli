(** Modal manager: variant stack replacing scattered boolean refs. *)

type prompt_result =
  | Handled    (** prompt consumed the event, dismiss *)
  | Dismissed  (** event didn't match, dismiss and re-process *)
  | Ignored    (** event didn't match, stay in prompt *)

type kind =
  | Help of { mutable scroll : int }
  | QueryMenu
  | OptionsMenu
  | ThemeMenu
  | BuildMenu
  | FilePicker of File_picker.t
  | Prompt of {
      message : string;
      handler : Input.event -> prompt_result;
    }
  | SearchPrompt
    (** The search prompt — incremental search bar at the bottom of the
        screen. The search state itself lives on [Tab.t]. The
        dispatcher is [Editor.Modals.handle_search_prompt]. *)

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

(** Get the file picker state if it's the active modal. *)
val get_file_picker : t -> File_picker.t option
