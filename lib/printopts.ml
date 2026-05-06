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
  { key = 'm'; label = "Match";
    opt_names = [["Printing"; "Matching"]]; enabled = true };
  { key = 's'; label = "Synth";
    opt_names = [["Printing"; "Synth"]]; enabled = true };
  { key = 'g'; label = "GoalNames";
    opt_names = [["Printing"; "Goal"; "Names"]]; enabled = false };
  { key = 'j'; label = "Projections";
    opt_names = [["Printing"; "Projections"]]; enabled = false };
  { key = 'o'; label = "Compact";
    opt_names = [["Printing"; "Compact"; "Contexts"]]; enabled = false };
  { key = 'd'; label = "EvarLine";
    opt_names = [["Printing"; "Dependent"; "Evars"; "Line"]]; enabled = true };
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

let sentence_for name b =
  Printf.sprintf "%s %s." (if b then "Set" else "Unset")
    (String.concat " " name)

let to_vernac_sentences ?(override=[]) () =
  let from_entries = List.concat_map (fun e ->
    List.map (fun name ->
      let value = match List.assoc_opt name override with
        | Some (Interface.BoolValue b) -> b
        | _ -> e.enabled
      in
      sentence_for name value
    ) e.opt_names
  ) entries in
  let known name =
    List.exists (fun e -> List.mem name e.opt_names) entries
  in
  let from_override = List.filter_map (fun (name, value) ->
    if known name then None
    else match value with
      | Interface.BoolValue b -> Some (sentence_for name b)
      | _ -> None
  ) override in
  from_entries @ from_override

let to_set_options_with override =
  let tbl = Hashtbl.create 16 in
  List.iter (fun e ->
    List.iter (fun name ->
      Hashtbl.replace tbl name (Interface.BoolValue e.enabled)
    ) e.opt_names
  ) entries;
  List.iter (fun (name, value) -> Hashtbl.replace tbl name value) override;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
