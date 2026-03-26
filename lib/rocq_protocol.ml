module Rocqide = Spawn.Sync ()

type t = {
  process : Rocqide.process;
  xml_printer : Xml_printer.t;
  xml_parser : Xml_parser.t;
  in_fd : Unix.file_descr;
  mutable pending_feedback : Feedback.feedback list;
}

let spawn ?(prog="coqidetop") ?(args=[]) () =
  let all_args = Array.of_list ("--xml_format=Ppcmds" :: args) in
  let process, cin, cout = Rocqide.spawn prog all_args in
  let xml_parser = Xml_parser.make (Xml_parser.SChannel cin) in
  Xml_parser.check_eof xml_parser false;
  let xml_printer = Xml_printer.make (Xml_printer.TChannel cout) in
  let in_fd = Unix.descr_of_in_channel cin in
  { process; xml_printer; xml_parser; in_fd; pending_feedback = [] }

let eval_call t call =
  let xml_query = Xmlprotocol.of_call call in
  Xml_printer.print t.xml_printer xml_query;
  let rec loop () =
    let xml = Xml_parser.parse t.xml_parser in
    match Xmlprotocol.msg_kind xml with
    | Xmlprotocol.Feedback ->
      let fb = Xmlprotocol.to_feedback xml in
      t.pending_feedback <- fb :: t.pending_feedback;
      loop ()
    | Xmlprotocol.LtacDebugInfo ->
      loop ()
    | Xmlprotocol.Other ->
      Xmlprotocol.to_answer call xml
  in
  loop ()

let init t filename =
  match eval_call t (Xmlprotocol.init filename) with
  | Interface.Good id -> id
  | Interface.Fail (_, _, msg) ->
    failwith ("rocq init failed: " ^ Pp.string_of_ppcmds msg)

let add t ~state_id ~edit_id ~verbose ~bp ~line ~bol phrase =
  let call = Xmlprotocol.add
    ((((phrase, edit_id), (state_id, verbose)), bp), (line, bol)) in
  eval_call t call

let edit_at t state_id =
  eval_call t (Xmlprotocol.edit_at state_id)

let goals t =
  eval_call t (Xmlprotocol.goals ())

let query t ~state_id phrase =
  let call = Xmlprotocol.query (0, (phrase, state_id)) in
  ignore (eval_call t call)

let set_options t opts =
  match eval_call t (Xmlprotocol.set_options opts) with
  | Interface.Good () -> true
  | Interface.Fail _ -> false

let quit t =
  ignore (eval_call t (Xmlprotocol.quit ()));
  Rocqide.kill t.process

let input_fd t = t.in_fd

let has_data t =
  let ready, _, _ = Unix.select [t.in_fd] [] [] 0.0 in
  ready <> []

let pid t = Rocqide.unixpid t.process

let drain_feedback t =
  let fb = List.rev t.pending_feedback in
  t.pending_feedback <- [];
  fb

let poll_feedback t =
  while has_data t do
    let xml = Xml_parser.parse t.xml_parser in
    match Xmlprotocol.msg_kind xml with
    | Xmlprotocol.Feedback ->
      let fb = Xmlprotocol.to_feedback xml in
      t.pending_feedback <- fb :: t.pending_feedback
    | Xmlprotocol.LtacDebugInfo -> ()
    | Xmlprotocol.Other -> ()
  done
