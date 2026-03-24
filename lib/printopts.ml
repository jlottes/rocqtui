type entry = {
  key : char;
  label : string;
  opt_names : string list list;
  mutable enabled : bool;
}

let entries = [
  { key = 'i'; label = "Implicit";
    opt_names = [["Printing"; "Implicit"]]; enabled = false };
  { key = 'c'; label = "Coercions";
    opt_names = [["Printing"; "Coercions"]]; enabled = false };
  { key = 'n'; label = "Notations";
    opt_names = [["Printing"; "Notations"]]; enabled = true };
  { key = 'a'; label = "All";
    opt_names = [["Printing"; "All"]]; enabled = false };
  { key = 'e'; label = "Existential";
    opt_names = [["Printing"; "Existential"; "Instances"]]; enabled = false };
  { key = 'u'; label = "Universes";
    opt_names = [["Printing"; "Universes"]]; enabled = false };
  { key = 'p'; label = "Parens";
    opt_names = [["Printing"; "Parentheses"]]; enabled = false };
  { key = 'f'; label = "Unfocused";
    opt_names = [["Printing"; "Unfocused"]]; enabled = false };
  { key = 'r'; label = "Records";
    opt_names = [["Printing"; "Records"]]; enabled = true };
]

let toggle entry =
  entry.enabled <- not entry.enabled

let to_set_options () =
  let tbl = Hashtbl.create 16 in
  List.iter (fun e ->
    List.iter (fun name ->
      Hashtbl.replace tbl name (Interface.BoolValue e.enabled)
    ) e.opt_names
  ) entries;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
