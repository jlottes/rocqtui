(* Parser for Rocq .glob files.
   These contain byte offsets for definitions alongside .vo files. *)

type entry = {
  kind : string;   (* "def", "prf", "ind", "constr", "class", "ax", etc. *)
  name : string;
  bp : int;        (* byte offset of start in .v source *)
  ep : int;        (* byte offset of end in .v source *)
}

let definition_kinds =
  ["def"; "prf"; "ind"; "constr"; "rec"; "class"; "ax"; "thm";
   "sec"; "syndef"; "not"; "abbrev"]

let parse path =
  let entries = ref [] in
  (try
    In_channel.with_open_text path (fun ic ->
      try while true do
        let line = input_line ic in
        if String.length line > 0 then begin
          (* Find the kind — it's the first word *)
          let space = try String.index line ' ' with Not_found -> -1 in
          if space > 0 then begin
            let kind = String.sub line 0 space in
            if List.mem kind definition_kinds then begin
              (* Format: kind start:end section name *)
              let rest = String.sub line (space + 1)
                           (String.length line - space - 1) in
              let colon = try String.index rest ':' with Not_found -> -1 in
              if colon > 0 then begin
                let bp_str = String.sub rest 0 colon in
                let after_colon = String.sub rest (colon + 1)
                                    (String.length rest - colon - 1) in
                let space2 = try String.index after_colon ' '
                             with Not_found -> -1 in
                if space2 > 0 then begin
                  let ep_str = String.sub after_colon 0 space2 in
                  (* Rest is "section name" — name is the last word *)
                  let rest2 = String.sub after_colon (space2 + 1)
                                (String.length after_colon - space2 - 1) in
                  let name = match String.rindex_opt rest2 ' ' with
                    | Some i -> String.sub rest2 (i + 1)
                                  (String.length rest2 - i - 1)
                    | None -> rest2
                  in
                  match int_of_string_opt bp_str, int_of_string_opt ep_str with
                  | Some bp, Some ep ->
                    entries := { kind; name; bp; ep } :: !entries
                  | _ -> ()
                end
              end
            end
          end
        end
      done with End_of_file -> ())
   with _ -> ());
  List.rev !entries

let find_definition entries name =
  List.find_opt (fun e -> e.name = name) entries

(* Convert a byte offset to a 0-based line number by reading the source file *)
let byte_offset_to_line source_path bp =
  try
    In_channel.with_open_text source_path (fun ic ->
      let line = ref 0 in
      let pos = ref 0 in
      (try while !pos < bp do
         let c = input_char ic in
         if c = '\n' then incr line;
         incr pos
       done with End_of_file -> ());
      Some !line)
  with _ -> None
