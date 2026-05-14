module RocqAsync = Spawn.Async(Main_loop)

(* Existential wrapper for a queued call + its result delivery. *)
type pending =
  | Pending : 'a Xmlprotocol.call * ('a Interface.value -> unit) -> pending

type 'a handle = 'a Interface.value option ref

type t = {
  process : RocqAsync.process;
  out_chan : out_channel;
  xml_printer : Xml_printer.t;
  mutable pending_feedback : Feedback.feedback list;
  mutable queue : pending list;       (* head is in flight if head_dispatched *)
  mutable head_dispatched : bool;     (* head of queue has been written *)
  mutable fragment : string;
  mutable lexerror : int option;
}

let handle_feedback t xml =
  let fb = Xmlprotocol.to_feedback xml in
  t.pending_feedback <- fb :: t.pending_feedback

let dispatch_head t =
  match t.queue with
  | [] -> t.head_dispatched <- false
  | Pending (call, _) :: _ ->
    Xml_printer.print t.xml_printer (Xmlprotocol.of_call call);
    t.head_dispatched <- true

(* Add a pending entry to the back. Dispatch immediately if nothing is
   currently in flight. *)
let enqueue t pending =
  t.queue <- t.queue @ [pending];
  if not t.head_dispatched then dispatch_head t

let handle_final_answer t xml =
  match t.queue with
  | [] -> ()  (* unexpected response, ignore *)
  | Pending (call, k) :: rest ->
    t.queue <- rest;
    t.head_dispatched <- false;
    let answer = Xmlprotocol.to_answer call xml in
    k answer;
    (* k may have enqueued new items. If it did and the queue was
       previously empty (rest = []), enqueue already dispatched the
       new head. Otherwise (head not dispatched but queue non-empty),
       dispatch now. *)
    if not t.head_dispatched then dispatch_head t

let [@warning "-32"] handle_input t ~read_all =
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
        (* If more calls are queued (or were enqueued in the
           continuation just run), there may be more responses. *)
        if t.queue <> [] then loop ()
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
       | None -> true
       | Some t ->
         try
           let _ = conds in
           handle_input t ~read_all
         with e ->
           ignore e; false)
  in
  let xml_printer = Xml_printer.make (Xml_printer.TChannel cout) in
  let t = {
    process; out_chan = cout; xml_printer;
    pending_feedback = []; queue = []; head_dispatched = false;
    fragment = ""; lexerror = None;
  } in
  t_ref := Some t;
  t

(* Pull-style: enqueue and return a handle whose ref fills when the
   response arrives. *)
let submit t call =
  let h = ref None in
  enqueue t (Pending (call, fun v -> h := Some v));
  h

let poll_response h = !h

(* Push-style: enqueue with a continuation. Always safe — multiple
   sends are queued FIFO. *)
let send_call t call k =
  enqueue t (Pending (call, k))

(* Interrupt callback — set by the application to handle ^C during blocking calls *)
let interrupt_hook : (t -> unit) option ref = ref None

let set_interrupt_hook f = interrupt_hook := Some f

(* Send a call and block until the response arrives.
   Uses select_with_watches to keep processing other watches. *)
let eval_call t call =
  let result = ref None in
  send_call t call (fun v -> result := Some v);
  while !result = None do
    (* Include stdin so we don't block when user presses keys *)
    let ready = Main_loop.select_with_watches [Unix.stdin] 0.1 in
    (* If stdin is ready, check for ^C via the hook *)
    if List.mem Unix.stdin ready then
      (match !interrupt_hook with Some f -> f t | None -> ())
  done;
  match !result with
  | Some v -> v
  | None -> assert false

let is_busy t = t.queue <> []

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
