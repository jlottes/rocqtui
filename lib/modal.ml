(* Modal manager: replaces scattered boolean refs with a variant stack. *)

(* Both rename and save-as anchor path resolution at the session
   project ([Editor_context.t.project]). They do not carry the project
   in their state — the handler re-reads it at commit time, so a
   project that was newly created by the startup prompt becomes
   available immediately. *)
type rename_state = {
  old_path : string;          (* absolute path of file being renamed *)
  extension : string;         (* always ".v" for now; locked suffix *)
  field : Text_field.t;       (* editable portion; never includes [extension] *)
}

type save_as_state = {
  tab_id : int;               (* tab whose buffer will be saved *)
  extension : string;         (* locked suffix (".v") *)
  field : Text_field.t;       (* editable portion; starts empty *)
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
    (* No payload: the search state lives on Tab.t (per-tab persistence).
       Dispatched via Editor.Modals.handle_search_prompt. *)
  | RenamePrompt of rename_state
  | SaveAsPrompt of save_as_state

and prompt_result =
  | Handled    (* prompt consumed the event, dismiss *)
  | Dismissed  (* event didn't match, dismiss and re-process *)
  | Ignored    (* event didn't match, stay in prompt *)

type t = {
  mutable stack : kind list;
}

let create () = { stack = [] }

let top t = match t.stack with
  | k :: _ -> Some k
  | [] -> None

let is_active t = t.stack <> []

let push t kind =
  t.stack <- kind :: t.stack

let pop t =
  match t.stack with
  | _ :: rest -> t.stack <- rest
  | [] -> ()

let same_kind a b =
  match a, b with
  | Help _, Help _ -> true
  | QueryMenu, QueryMenu -> true
  | OptionsMenu, OptionsMenu -> true
  | ThemeMenu, ThemeMenu -> true
  | BuildMenu, BuildMenu -> true
  | FilePicker _, FilePicker _ -> true
  | Prompt _, Prompt _ -> true
  | SearchPrompt, SearchPrompt -> true
  | RenamePrompt _, RenamePrompt _ -> true
  | SaveAsPrompt _, SaveAsPrompt _ -> true
  | _ -> false

let toggle t kind =
  match t.stack with
  | k :: rest when same_kind k kind ->
    t.stack <- rest
  | _ ->
    t.stack <- kind :: t.stack

let is_open t kind =
  List.exists (same_kind kind) t.stack

let clear t =
  t.stack <- []

(* Dismiss the current modal on Escape. Returns true if something was dismissed. *)
let dismiss t =
  match t.stack with
  | [] -> false
  | _ :: rest -> t.stack <- rest; true

let get_file_picker t =
  match t.stack with
  | FilePicker fp :: _ -> Some fp
  | _ -> None
