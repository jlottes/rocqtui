(* XCompose input method.
   Parses ~/.XCompose, builds a trie, and provides key-by-key matching. *)

type result =
  | Pending
  | Composed of string
  | NoMatch

(* Trie node: children keyed by curses key code, optional output at this node *)
type trie_node = {
  mutable children : (int * trie_node) list;
  mutable output : string option;
}

type t = {
  root : trie_node;
  mutable cursor : trie_node;
  mutable is_active : bool;
  mutable pressed : int list;  (* keys pressed so far, in order *)
}

let new_node () = { children = []; output = None }

let find_child node key =
  List.assoc_opt key node.children

let add_child node key child =
  node.children <- (key, child) :: node.children

(* Map X keysym names to curses key codes *)
let keysym_to_code name =
  match name with
  (* Letters *)
  | s when String.length s = 1 -> Some (Char.code s.[0])
  (* Special keys *)
  | "space" -> Some (Char.code ' ')
  | "exclam" -> Some (Char.code '!')
  | "at" -> Some (Char.code '@')
  | "numbersign" -> Some (Char.code '#')
  | "dollar" -> Some (Char.code '$')
  | "percent" -> Some (Char.code '%')
  | "asciicircum" -> Some (Char.code '^')
  | "ampersand" -> Some (Char.code '&')
  | "asterisk" -> Some (Char.code '*')
  | "parenleft" -> Some (Char.code '(')
  | "parenright" -> Some (Char.code ')')
  | "minus" -> Some (Char.code '-')
  | "underscore" -> Some (Char.code '_')
  | "equal" -> Some (Char.code '=')
  | "plus" -> Some (Char.code '+')
  | "bracketleft" -> Some (Char.code '[')
  | "bracketright" -> Some (Char.code ']')
  | "braceleft" -> Some (Char.code '{')
  | "braceright" -> Some (Char.code '}')
  | "backslash" -> Some (Char.code '\\')
  | "bar" -> Some (Char.code '|')
  | "semicolon" -> Some (Char.code ';')
  | "colon" -> Some (Char.code ':')
  | "apostrophe" -> Some (Char.code '\'')
  | "quotedbl" -> Some (Char.code '"')
  | "comma" -> Some (Char.code ',')
  | "period" -> Some (Char.code '.')
  | "less" -> Some (Char.code '<')
  | "greater" -> Some (Char.code '>')
  | "slash" -> Some (Char.code '/')
  | "question" -> Some (Char.code '?')
  | "grave" -> Some (Char.code '`')
  | "asciitilde" -> Some (Char.code '~')
  | "Return" -> Some 10
  | "Tab" -> Some 9
  | "BackSpace" -> Some 127
  (* Multi_key within a sequence — we use Escape (27) *)
  | "Multi_key" -> Some 27
  (* Digits *)
  | "0" -> Some (Char.code '0')
  | "1" -> Some (Char.code '1')
  | "2" -> Some (Char.code '2')
  | "3" -> Some (Char.code '3')
  | "4" -> Some (Char.code '4')
  | "5" -> Some (Char.code '5')
  | "6" -> Some (Char.code '6')
  | "7" -> Some (Char.code '7')
  | "8" -> Some (Char.code '8')
  | "9" -> Some (Char.code '9')
  | _ -> None  (* unknown keysym *)

(* Parse one line of XCompose format:
   <Multi_key> <a> <e> : "æ" U00E6
   Returns Some (key_codes, output_string) or None *)
let parse_line line =
  let line = String.trim line in
  if line = "" || line.[0] = '#' then None
  else if String.length line >= 7 && String.sub line 0 7 = "include" then None
  else
    (* Find the colon separator *)
    match String.index_opt line ':' with
    | None -> None
    | Some colon_pos ->
      let key_part = String.trim (String.sub line 0 colon_pos) in
      let result_part = String.trim (String.sub line (colon_pos + 1)
        (String.length line - colon_pos - 1)) in
      (* Parse keys: extract <name> tokens, skip the first <Multi_key> *)
      let keys = ref [] in
      let i = ref 0 in
      let kp = key_part in
      let len = String.length kp in
      let first = ref true in
      (try while !i < len do
         if kp.[!i] = '<' then begin
           let j = ref (!i + 1) in
           while !j < len && kp.[!j] <> '>' do incr j done;
           if !j < len then begin
             let name = String.sub kp (!i + 1) (!j - !i - 1) in
             if !first && name = "Multi_key" then
               first := false  (* skip leading Multi_key *)
             else begin
               match keysym_to_code name with
               | Some code -> keys := code :: !keys
               | None -> raise Exit  (* unknown keysym, skip line *)
             end;
             i := !j + 1
           end else
             i := len
         end else
           incr i
       done with Exit -> keys := []);
      if !keys = [] then None
      else begin
        (* Parse result: extract text between quotes *)
        let output = match String.index_opt result_part '"' with
          | None -> None
          | Some q1 ->
            let q2 = try String.index_from result_part (q1 + 1) '"'
                     with Not_found -> String.length result_part - 1 in
            Some (String.sub result_part (q1 + 1) (q2 - q1 - 1))
        in
        match output with
        | None -> None
        | Some text -> Some (List.rev !keys, text)
      end

(* Insert a sequence into the trie *)
let trie_insert root keys text =
  let node = ref root in
  List.iter (fun key ->
    match find_child !node key with
    | Some child -> node := child
    | None ->
      let child = new_node () in
      add_child !node key child;
      node := child
  ) keys;
  !node.output <- Some text

(* Resolve the %L include path *)
let locale_compose_path () =
  let locale = try Sys.getenv "LANG" with Not_found -> "en_US.UTF-8" in
  (* Try various encodings of the locale name *)
  let base = match String.index_opt locale '.' with
    | Some i -> String.sub locale 0 i
    | None -> locale
  in
  let candidates = [
    Printf.sprintf "/usr/share/X11/locale/%s/Compose" locale;
    Printf.sprintf "/usr/share/X11/locale/%s.UTF-8/Compose" base;
    Printf.sprintf "/usr/share/X11/locale/%s.utf8/Compose" base;
    "/usr/share/X11/locale/en_US.UTF-8/Compose";
  ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> "/usr/share/X11/locale/en_US.UTF-8/Compose"

(* Load a compose file, inserting entries into the trie *)
let load_file root path =
  if Sys.file_exists path then
    In_channel.with_open_text path (fun ic ->
      try while true do
        let line = input_line ic in
        match parse_line line with
        | Some (keys, text) -> trie_insert root keys text
        | None -> ()
      done with End_of_file -> ())

let load () =
  let root = new_node () in
  (* Load system compose file first *)
  let sys_path = locale_compose_path () in
  load_file root sys_path;
  (* Load user file (overrides system) *)
  let home = try Sys.getenv "HOME" with Not_found -> "." in
  let user_path = Filename.concat home ".XCompose" in
  load_file root user_path;
  { root; cursor = root; is_active = false; pressed = [] }

let start t =
  t.cursor <- t.root;
  t.is_active <- true;
  t.pressed <- []

let feed t key =
  t.pressed <- t.pressed @ [key];
  match find_child t.cursor key with
  | Some child ->
    t.cursor <- child;
    (match child.output with
     | Some text ->
       if child.children = [] then begin
         (* Exact match, no longer sequences possible *)
         t.is_active <- false;
         Composed text
       end else
         (* Has output but also has children — wait for more keys.
            If the next key doesn't match a child, we'll output this. *)
         Pending
     | None ->
       Pending)
  | None ->
    (* Key doesn't match any child — output current node if it has one *)
    t.is_active <- false;
    match t.cursor.output with
    | Some text -> Composed text
    | None -> NoMatch

let active t = t.is_active

let keys_so_far t = t.pressed

(* Collect all completions reachable from a node, with remaining key paths *)
let completions t =
  let result = ref [] in
  let rec walk node path =
    (match node.output with
     | Some text -> result := (List.rev path, text) :: !result
     | None -> ());
    List.iter (fun (key, child) ->
      walk child (key :: path)
    ) node.children
  in
  walk t.cursor [];
  List.rev !result
