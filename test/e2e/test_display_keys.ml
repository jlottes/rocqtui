(* Parametric test that exercises every key in mcp_server's
   display_option_keys table. For each key:

     1. Send query with display:{<key>: not_default}.
     2. Use "Test Printing X." as the query phrase to read back the
        live option value.
     3. Assert the response says "Printing X is <on|off>" matching
        the override.

   Catches typos in the JSON-key → Rocq-option-name mapping (the
   most likely failure mode), and confirms each Set Printing X.
   sentence the Add+EditAt dance issues is well-formed. *)

(* (json_key, vernac_name, default_enabled) — vernac_name is what
   appears after [Test ] / [Set ] / [Unset ]. The default flag is
   the value an out-of-the-box Rocq session has. We override to the
   opposite and assert the override took effect. *)
let cases = [
  "implicit",         "Printing Implicit",                false;
  "coercions",        "Printing Coercions",               false;
  "notations",        "Printing Notations",               true;
  "all",              "Printing All",                     false;
  "existential",      "Printing Existential Instances",   false;
  "universes",        "Printing Universes",               false;
  "parens",           "Printing Parentheses",             false;
  "unfocused",        "Printing Unfocused",               false;
  "records",          "Printing Records",                 true;
  "matching",         "Printing Matching",                true;
  "synth",            "Printing Synth",                   true;
  "goal_names",       "Printing Goal Names",              false;
  "projections",      "Printing Projections",             false;
  "compact_contexts", "Printing Compact Contexts",        false;
  "evar_line",        "Printing Dependent Evars Line",    true;
]

let messages_of r =
  let result = E2e_harness.result_of r in
  let body = E2e_harness.structured_response result in
  match Yojson.Safe.Util.member "messages" body with
  | `String s -> s
  | _ ->
    E2e_harness.fail
      (Printf.sprintf "no messages string in: %s"
        (Yojson.Safe.to_string body))

let check_case s (key, vernac_name, default) =
  let override = not default in
  let cmd = Printf.sprintf "Test %s." vernac_name in
  let r = E2e_harness.call_tool s "query"
    ~args:(`Assoc [
      "command", `String cmd;
      "display", `Assoc [key, `Bool override];
    ]) in
  let msg = messages_of r in
  let expected_state = if override then "is on" else "is off" in
  let expected = Printf.sprintf "%s %s" vernac_name expected_state in
  if not (try
            let n = String.length expected in
            let h = String.length msg in
            let i = ref 0 in
            let found = ref false in
            while not !found && !i + n <= h do
              if String.sub msg !i n = expected then found := true;
              incr i
            done;
            !found
          with _ -> false)
  then
    E2e_harness.fail
      (Printf.sprintf "%s with display:{%s:%b}: expected %S, got %S"
        cmd key override expected (String.trim msg))
  else
    Printf.printf "  OK %-32s -> %s\n%!" key (String.trim msg)

let () =
  (* Empty file is fine — we Add transient sentences on top of
     Stateid.initial. *)
  let s = E2e_harness.start ~rocq_source:"" () in
  let cleanup () = E2e_harness.stop s in
  try
    E2e_harness.initialize s;
    List.iter (check_case s) cases;
    Printf.printf "OK: all %d display keys round-trip through Set/Test\n"
      (List.length cases);
    cleanup ();
    exit 0
  with e ->
    let bt = Printexc.get_backtrace () in
    Printf.eprintf "FAIL: %s\n%s\n" (Printexc.to_string e) bt;
    E2e_harness.dump_logs s;
    cleanup ();
    exit 1
