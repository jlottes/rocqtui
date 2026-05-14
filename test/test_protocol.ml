(* Smoke test for Rocq protocol communication.
   Run: dune exec test/test_protocol.exe *)

open Rocqtui_lib

(* Tiny synchronous wrapper for tests: submit, then spin on the
   handle. The protocol layer's pull-style API doesn't expose a
   blocking wait for non-init calls, so the test provides its own. *)
let block_for h =
  while !h = None do
    ignore (Main_loop.select_with_watches [] 0.05)
  done;
  Option.get !h

let () =
  Printf.printf "Spawning coqidetop...\n%!";
  let rocq = Rocq_protocol.spawn () in
  Printf.printf "PID: %d\n%!" (Rocq_protocol.pid rocq);

  Printf.printf "Sending Init...\n%!";
  let init_id = Rocq_protocol.init rocq None in
  Printf.printf "Initial state id: %s\n%!" (Stateid.to_string init_id);

  Printf.printf "Adding 'Check nat.'...\n%!";
  let add_call = Xmlprotocol.add
    ((((("Check nat."), -1), (init_id, true)), 0), (1, 0)) in
  let result = block_for (Rocq_protocol.submit rocq add_call) in
  (match result with
   | Interface.Good (new_id, _) ->
     Printf.printf "Good: new state id = %s\n%!" (Stateid.to_string new_id);
     let fb = Rocq_protocol.drain_feedback rocq in
     Printf.printf "Feedback messages: %d\n%!" (List.length fb);

     (* Get goals (should be None since Check doesn't create a goal) *)
     Printf.printf "Fetching goals...\n%!";
     (match block_for (Rocq_protocol.submit rocq (Xmlprotocol.goals ())) with
      | Interface.Good None -> Printf.printf "No goals (expected).\n%!"
      | Interface.Good (Some _) -> Printf.printf "Got goals (unexpected).\n%!"
      | Interface.Fail (_, _, msg) ->
        Printf.printf "Goals failed: %s\n%!" (Pp.string_of_ppcmds msg))
   | Interface.Fail (_, _, msg) ->
     Printf.printf "Fail: %s\n%!" (Pp.string_of_ppcmds msg));

  Printf.printf "Quitting...\n%!";
  Rocq_protocol.quit rocq;
  Printf.printf "Done!\n"
