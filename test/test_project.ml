let () =
  let (dir, args) = Rocqtui_lib.Project.find_args (Some "/home/jlottes/rocq/affine/scratch_test.v") in
  Printf.printf "Project dir: %s\n" (match dir with Some d -> d | None -> "<none>");
  Printf.printf "Args: [%s]\n" (String.concat "; " (List.map (Printf.sprintf "%S") args))
