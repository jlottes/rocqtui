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

  (* Oversized-response guard: a single huge protocol message must fail
     the in-flight call cleanly (session reset) rather than wedging the
     parser. Use a small per-session cap (read at spawn) and provoke a
     response far larger than it. *)
  Printf.printf "\n=== oversized-response guard ===\n%!";
  Unix.putenv "ROCQTUI_MAX_XML_BYTES" "4000";
  let rocq2 = Rocq_protocol.spawn () in
  let init2 = Rocq_protocol.init rocq2 None in
  (* Disable Rocq's term elision so the big tuple prints in full
     (otherwise it collapses to "..." and stays tiny). Each Set is a
     small response under the cap. *)
  let add sid phrase = Xmlprotocol.add ((((phrase, -1), (sid, true)), 0), (1, 0)) in
  let step sid phrase =
    match block_for (Rocq_protocol.submit rocq2 (add sid phrase)) with
    | Interface.Good (id, _) -> id
    | Interface.Fail (_, _, m) ->
      Printf.printf "FAIL: setup step %S errored: %s\n%!" phrase
        (Pp.string_of_ppcmds m); exit 1
  in
  let s1 = step init2 "Set Printing Depth 1000000." in
  let s2 = step s1 "Set Printing Width 1000000." in
  (* Enter a proof whose conclusion is huge. The [goals] query returns
     the pretty-printed goal as its value — a single message whose XML
     is well past 4 KB, while init and the small steps stay under it. *)
  let concl = String.concat " /\\ " (List.init 2000 (fun _ -> "True")) in
  let _ = step s2 ("Goal " ^ concl ^ ".") in
  (match block_for (Rocq_protocol.submit rocq2 (Xmlprotocol.goals ())) with
   | Interface.Fail (_, _, msg) ->
     let s = Pp.string_of_ppcmds msg in
     Printf.printf "Got Fail (expected): %s\n%!" s;
     let contains sub =
       let n = String.length sub and m = String.length s in
       let rec go i = i + n <= m && (String.sub s i n = sub || go (i+1)) in
       go 0
     in
     if not (contains "exceeded" || contains "session reset") then begin
       Printf.printf "FAIL: reset message not recognized\n%!"; exit 1
     end
   | Interface.Good _ ->
     Printf.printf "FAIL: oversized response did not trigger reset\n%!";
     exit 1);
  Rocq_protocol.quit rocq2;
  Printf.printf "Done!\n"
