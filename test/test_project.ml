(* Debug script: resolve _RocqProject for a given .v file.
   Usage: dune exec test/test_project.exe -- <path-to-file.v> *)
let () =
  let path =
    if Array.length Sys.argv > 1 then Some Sys.argv.(1)
    else None
  in
  let (dir, args) = Rocqtui_lib.Project.find_args path in
  Printf.printf "Project dir: %s\n" (match dir with Some d -> d | None -> "<none>");
  Printf.printf "Args: [%s]\n" (String.concat "; " (List.map (Printf.sprintf "%S") args))
