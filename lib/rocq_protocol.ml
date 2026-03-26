module RocqAsync = Spawn.Async(Main_loop)

(* Existential wrapper for pending call + continuation *)
type pending =
  | Pending : 'a Xmlprotocol.call * ('a Interface.value -> unit) -> pending

type t = {
  process : RocqAsync.process;
  out_chan : out_channel;
  xml_printer : Xml_printer.t;
  mutable pending_feedback : Feedback.feedback list;
  mutable waiting_for : pending option;
  mutable fragment : string;
  mutable lexerror : int option;
}

let handle_feedback t xml =
  let fb = Xmlprotocol.to_feedback xml in
  t.pending_feedback <- fb :: t.pending_feedback

let handle_final_answer t xml =
  match t.waiting_for with
  | None -> ()  (* unexpected response, ignore *)
  | Some (Pending (call, k)) ->
    t.waiting_for <- None;
    let answer = Xmlprotocol.to_answer call xml in
    k answer

let handle_input t ~read_all =
  let s = read_all () in
  if String.length s = 0 then false  (* EOF / empty *)
  else begin
    let s = t.fragment ^ s in
    t.fragment <- s;
    let lex = Lexing.from_string s in
    let p = Xml_parser.make (Xml_parser.SLexbuf lex) in
    Xml_parser.check_eof p false;
    let rec loop () =
      let xml = Xml_parser.parse ~canonicalize:false p in
      let l_end = Lexing.lexeme_end lex in
      t.fragment <- String.sub s l_end (String.length s - l_end);
      t.lexerror <- None;
      match Xmlprotocol.msg_kind xml with
      | Xmlprotocol.Feedback ->
        handle_feedback t xml;
        loop ()
      | Xmlprotocol.LtacDebugInfo ->
        loop ()
      | Xmlprotocol.Other ->
        handle_final_answer t xml;
        (* If there's still a pending call (shouldn't happen normally),
           keep parsing *)
        if t.waiting_for <> None then loop ()
    in
    (try loop ()
     with Xml_parser.Error _ as e ->
       let l_end = Lexing.lexeme_end lex in
       if t.lexerror = Some l_end then raise e;
       t.lexerror <- Some l_end);
    true
  end

let spawn ?(prog="coqidetop") ?(args=[]) () =
  let all_args = Array.of_list ("--xml_format=Ppcmds" :: args) in
  let t_ref = ref None in
  let process, cout = RocqAsync.spawn prog all_args
    (fun conds ~read_all ->
       match !t_ref with
       | None -> true  (* not initialized yet *)
       | Some t ->
         try
           let _ = conds in  (* ignore conditions for now *)
           handle_input t ~read_all
         with e ->
           ignore e; false)
  in
  let xml_printer = Xml_printer.make (Xml_printer.TChannel cout) in
  let t = {
    process; out_chan = cout; xml_printer;
    pending_feedback = []; waiting_for = None;
    fragment = ""; lexerror = None;
  } in
  t_ref := Some t;
  t

(* Send a call asynchronously with a continuation *)
let send_call t call k =
  assert (t.waiting_for = None);
  t.waiting_for <- Some (Pending (call, k));
  Xml_printer.print t.xml_printer (Xmlprotocol.of_call call)

(* Send a call and block until the response arrives.
   Uses select_with_watches to keep processing other watches. *)
let eval_call t call =
  let result = ref None in
  send_call t call (fun v -> result := Some v);
  while !result = None do
    ignore (Main_loop.select_with_watches [] 0.1)
  done;
  match !result with
  | Some v -> v
  | None -> assert false

let is_busy t = t.waiting_for <> None

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
  (try ignore (eval_call t (Xmlprotocol.quit ())) with _ -> ());
  RocqAsync.kill t.process

let pid t = RocqAsync.unixpid t.process

let drain_feedback t =
  let fb = List.rev t.pending_feedback in
  t.pending_feedback <- [];
  fb

(* Poll: just run select_with_watches with zero timeout to dispatch
   any pending watch callbacks. This processes both feedback and
   pending call responses. *)
let poll t =
  ignore t;
  ignore (Main_loop.select_with_watches [] 0.0)
