(* Modal manager: replaces scattered boolean refs with a variant stack. *)

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
