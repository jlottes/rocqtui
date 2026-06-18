(* Unit tests for Msg_pane: tab list, MRU history, pop_active. *)

open Rocqtui_lib

let pass msg = Printf.printf "OK: %s\n" msg
let fail msg = Printf.printf "FAIL: %s\n" msg; exit 1

let assert_eq_kind msg got expected =
  if Msg_pane.kind_eq got expected then pass msg
  else begin
    let to_s = function
      | Msg_pane.Rocq -> "Rocq"
      | Msg_pane.Info -> "Info"
      | Msg_pane.Build -> "Build"
      | Msg_pane.Errors -> "Errors"
      | Msg_pane.Search -> "Search"
      | Msg_pane.Terminal _ -> "Terminal _"
    in
    Printf.printf "  expected: %s\n  got:      %s\n" (to_s expected) (to_s got);
    fail msg
  end

let assert_eq_int msg got expected =
  if got = expected then pass msg
  else begin
    Printf.printf "  expected: %d\n  got:      %d\n" expected got;
    fail msg
  end

let assert_eq_kinds msg got expected =
  let len_eq = List.length got = List.length expected in
  let all_eq = len_eq &&
    List.for_all2 Msg_pane.kind_eq got expected in
  if all_eq then pass msg
  else begin
    let to_s = function
      | Msg_pane.Rocq -> "R" | Msg_pane.Info -> "I" | Msg_pane.Build -> "B"
      | Msg_pane.Errors -> "E" | Msg_pane.Search -> "S"
      | Msg_pane.Terminal _ -> "T"
    in
    Printf.printf "  expected: [%s]\n  got:      [%s]\n"
      (String.concat ";" (List.map to_s expected))
      (String.concat ";" (List.map to_s got));
    fail msg
  end

let reset () =
  let s = Msg_pane.state () in
  s.tabs <- [];
  s.active <- 0;
  s.history <- [];
  ignore (Msg_pane.ensure Msg_pane.Rocq)

let () =
  (* ensure is idempotent *)
  reset ();
  ignore (Msg_pane.ensure Msg_pane.Build);
  ignore (Msg_pane.ensure Msg_pane.Build);
  assert_eq_int "ensure idempotent: tab count" 2
    (List.length (Msg_pane.state ()).tabs);

  (* activate dedups history; push prev kind *)
  reset ();
  ignore (Msg_pane.ensure Msg_pane.Build);
  ignore (Msg_pane.ensure Msg_pane.Errors);
  Msg_pane.activate Msg_pane.Build;
  Msg_pane.activate Msg_pane.Rocq;
  Msg_pane.activate Msg_pane.Build;
  Msg_pane.activate Msg_pane.Rocq;
  (* Active = Rocq; history should be [Build] (one entry, dedup'd) *)
  assert_eq_kind "active after cycling" (Msg_pane.active_kind ()) Msg_pane.Rocq;
  assert_eq_kinds "history dedup" (Msg_pane.state ()).history [Msg_pane.Build];

  (* pop_active when history has multiple entries *)
  reset ();
  ignore (Msg_pane.ensure Msg_pane.Build);
  ignore (Msg_pane.ensure Msg_pane.Errors);
  Msg_pane.activate Msg_pane.Build;
  Msg_pane.activate Msg_pane.Errors;
  (* Active = Errors; history = [Build, Rocq] (most recent first) *)
  assert_eq_kinds "history before pop"
    (Msg_pane.state ()).history [Msg_pane.Build; Msg_pane.Rocq];
  Msg_pane.pop_active ();
  assert_eq_kind "pop -> MRU build" (Msg_pane.active_kind ()) Msg_pane.Build;
  assert_eq_kinds "history after one pop"
    (Msg_pane.state ()).history [Msg_pane.Rocq];

  (* pop_active falls back to Rocq when history exhausted *)
  reset ();
  Msg_pane.pop_active ();
  assert_eq_kind "pop on empty history -> Rocq"
    (Msg_pane.active_kind ()) Msg_pane.Rocq;

  (* remove drops kind from history *)
  reset ();
  ignore (Msg_pane.ensure Msg_pane.Errors);
  Msg_pane.activate Msg_pane.Errors;  (* history: [Rocq] *)
  Msg_pane.activate Msg_pane.Rocq;    (* history: [Errors] *)
  Msg_pane.remove Msg_pane.Errors;
  assert_eq_kinds "remove drops from history"
    (Msg_pane.state ()).history [];

  (* remove of active kind triggers pop_active *)
  reset ();
  ignore (Msg_pane.ensure Msg_pane.Build);
  ignore (Msg_pane.ensure Msg_pane.Errors);
  Msg_pane.activate Msg_pane.Errors;  (* history: [Rocq] *)
  Msg_pane.remove Msg_pane.Errors;
  assert_eq_kind "remove active -> pop"
    (Msg_pane.active_kind ()) Msg_pane.Rocq;

  (* pop_active is a no-op when tabs is empty — the module no longer
     auto-creates a Rocq fallback. Callers must [ensure] before
     reading the active tab. *)
  reset ();
  let s = Msg_pane.state () in
  s.tabs <- [];
  s.history <- [];
  Msg_pane.pop_active ();
  assert_eq_int "pop with no tabs leaves tabs empty"
    0 (List.length (Msg_pane.state ()).tabs);

  (* activate_next / activate_prev cycle through tabs, wrapping. *)
  reset ();
  ignore (Msg_pane.ensure Msg_pane.Build);
  ignore (Msg_pane.ensure Msg_pane.Errors);
  (* tabs: [Rocq; Build; Errors], active = 0 (Rocq) *)
  Msg_pane.activate_next ();
  assert_eq_kind "next from Rocq -> Build"
    (Msg_pane.active_kind ()) Msg_pane.Build;
  Msg_pane.activate_next ();
  assert_eq_kind "next from Build -> Errors"
    (Msg_pane.active_kind ()) Msg_pane.Errors;
  Msg_pane.activate_next ();
  assert_eq_kind "next from Errors wraps to Rocq"
    (Msg_pane.active_kind ()) Msg_pane.Rocq;
  Msg_pane.activate_prev ();
  assert_eq_kind "prev from Rocq wraps to Errors"
    (Msg_pane.active_kind ()) Msg_pane.Errors;

  Printf.printf "All msg_pane tests passed.\n"
