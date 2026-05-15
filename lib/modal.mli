(** Modal manager: variant stack replacing scattered boolean refs. *)

type prompt_result =
  | Handled    (** prompt consumed the event, dismiss *)
  | Dismissed  (** event didn't match, dismiss and re-process *)
  | Ignored    (** event didn't match, stay in prompt *)

(** Mutable state of the file-tree rename prompt. *)
type rename_state = {
  old_path : string;        (** absolute path of file being renamed *)
  project_dir : string;
  project_file : string;    (** absolute path to _RocqProject *)
  extension : string;       (** locked suffix (always ".v" for now) *)
  field : Text_field.t;     (** editable portion (never includes [extension]) *)
}

(** Mutable state of the save-as prompt (^S on a tab with no filename
    yet). Path is resolved relative to [project_dir]; locked extension
    is appended on commit. [tab_id] is captured at modal-open time so
    a stray mouse click on the tab bar doesn't redirect the save. *)
type save_as_state = {
  tab_id : int;
  project_dir : string;
  extension : string;       (** locked suffix (always ".v" for now) *)
  field : Text_field.t;     (** editable portion; starts empty *)
}

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
  | RenamePrompt of rename_state
    (** Single-line rename prompt for a file in the file-tree panel.
        Dispatched via [Editor.Modals.handle_rename_prompt]. *)
  | SaveAsPrompt of save_as_state
    (** Save-as prompt that opens when [^S] is pressed on a tab that
        has no filename yet. Dispatched via
        [Editor.Modals.handle_save_as_prompt]. *)

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
