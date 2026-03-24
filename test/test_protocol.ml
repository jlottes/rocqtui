(* Smoke test for Rocq protocol communication.
   Run: dune exec test/test_protocol.exe *)

let () =
  Printf.printf "Spawning coqidetop...\n%!";
  let rocq = Rocqtui_lib.Rocq_protocol.spawn () in
  Printf.printf "PID: %d\n%!" (Rocqtui_lib.Rocq_protocol.pid rocq);

  Printf.printf "Sending Init...\n%!";
  let init_id = Rocqtui_lib.Rocq_protocol.init rocq None in
  Printf.printf "Initial state id: %s\n%!" (Stateid.to_string init_id);

  Printf.printf "Adding 'Check nat.'...\n%!";
  let result = Rocqtui_lib.Rocq_protocol.add rocq
    ~state_id:init_id ~edit_id:(-1) ~verbose:true
    ~bp:0 ~line:1 ~bol:0
    "Check nat." in
  (match result with
   | Interface.Good (new_id, _) ->
     Printf.printf "Good: new state id = %s\n%!" (Stateid.to_string new_id);
     (* Check feedback *)
     let fb = Rocqtui_lib.Rocq_protocol.drain_feedback rocq in
     Printf.printf "Feedback messages: %d\n%!" (List.length fb);

     (* Get goals (should be None since Check doesn't create a goal) *)
     Printf.printf "Fetching goals...\n%!";
     (match Rocqtui_lib.Rocq_protocol.goals rocq with
      | Interface.Good None -> Printf.printf "No goals (expected).\n%!"
      | Interface.Good (Some _) -> Printf.printf "Got goals (unexpected).\n%!"
      | Interface.Fail (_, _, msg) ->
        Printf.printf "Goals failed: %s\n%!" (Pp.string_of_ppcmds msg))
   | Interface.Fail (_, _, msg) ->
     Printf.printf "Fail: %s\n%!" (Pp.string_of_ppcmds msg));

  Printf.printf "Quitting...\n%!";
  Rocqtui_lib.Rocq_protocol.quit rocq;
  Printf.printf "Done!\n"
