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
  mutable fragment : string;          (* unparsed stream bytes *)
  mutable scan : Xml_framing.t;       (* boundary scanner, in sync with [fragment] *)
  mutable lexerror : int option;
  mutable dead : bool;
  max_fragment : int;                 (* runaway-message cap, bytes *)
}

let handle_feedback t xml =
  let fb = Xmlprotocol.to_feedback xml in
  t.pending_feedback <- fb :: t.pending_feedback

(* Stamp on Fail values we synthesize when the subprocess died. *)
let died_pp = Pp.str "rocq subprocess died"

(* Largest a single un-parsed protocol message may grow before we treat
   it as a runaway (e.g. a notation/printing blowup) and reset. This is
   per incomplete message, not cumulative — a normal stream of many
   small messages never trips it, because each is consumed and the
   fragment trimmed past it. Read once per session in [spawn];
   overridable via ROCQTUI_MAX_XML_BYTES. *)
let default_max_fragment_bytes () =
  let default = 16 * 1024 * 1024 in
  match Sys.getenv_opt "ROCQTUI_MAX_XML_BYTES" with
  | Some s -> (match int_of_string_opt s with Some n when n > 0 -> n | _ -> default)
  | None -> default

(* Mark the protocol as dead and reply Fail to every queued caller.
   Idempotent — multiple write failures land here harmlessly. *)
let mark_dead t =
  if not t.dead then begin
    t.dead <- true;
    let pending = t.queue in
    t.queue <- [];
    t.head_dispatched <- false;
    List.iter (fun (Pending (_, k)) ->
      k (Interface.Fail (Stateid.dummy, None, died_pp))) pending
  end

let dispatch_head t =
  match t.queue with
  | [] -> t.head_dispatched <- false
  | Pending (call, _) :: _ ->
    (try
       Xml_printer.print t.xml_printer (Xmlprotocol.of_call call);
       t.head_dispatched <- true
     with Sys_error _ | End_of_file ->
       (* The subprocess died (or the pipe was closed). Don't crash
          the editor — fail every queued call cleanly. *)
       mark_dead t)

(* Add a pending entry to the back. Dispatch immediately if nothing is
   currently in flight. If the protocol is dead, fail the new entry
   directly without enqueueing. *)
let enqueue t pending =
  if t.dead then
    let Pending (_, k) = pending in
    k (Interface.Fail (Stateid.dummy, None, died_pp))
  else begin
    t.queue <- t.queue @ [pending];
    if not t.head_dispatched then dispatch_head t
  end

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

(* A single protocol message has grown past [max_fragment_bytes]
   (e.g. a notation/printing blowup). The stream is now desynced, so we
   can't safely resume parsing — fail the in-flight call with an
   explanatory message and tear the protocol down. Returns [false]
   (not alive) so the watch is dropped. *)
let reset_oversized t =
  Log.logf "handle_input: fragment exceeded %d bytes (got %d) -> reset"
    t.max_fragment (String.length t.fragment);
  let human n =
    if n >= 1024 * 1024 then Printf.sprintf "%d MB" (n / (1024 * 1024))
    else if n >= 1024 then Printf.sprintf "%d KB" (n / 1024)
    else Printf.sprintf "%d bytes" n
  in
  let msg =
    Pp.str (Printf.sprintf
      "Rocq response exceeded %s (likely a notation/printing blowup); \
       session reset."
      (human t.max_fragment))
  in
  (match t.queue with
   | Pending (_, k) :: rest ->
     t.queue <- rest;
     t.head_dispatched <- false;
     k (Interface.Fail (Stateid.dummy, None, msg))
   | [] -> ());
  mark_dead t;
  false

(* Parse as many complete protocol messages as [s] holds, dispatching
   each, and leave any trailing incomplete bytes in [t.fragment]. *)
let parse_fragment t s =
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

let [@warning "-32"] handle_input t ~read_all =
  let s = read_all () in
  if String.length s = 0 then false  (* EOF / empty *)
  else begin
    t.fragment <- t.fragment ^ s;
    (* Runaway cap: bound the single-message size so the (now linear, but
       still per-message) re-lex and the value tree can't grow without
       limit. *)
    if String.length t.fragment > t.max_fragment then reset_oversized t
    else begin
      (* Advance the boundary scanner over just the new bytes, and only
         re-lex once a complete top-level message is buffered. Without
         this, an in-progress giant message would be re-lexed from byte 0
         on every drain — O(N²). The scanner is O(new bytes). *)
      t.scan <- Xml_framing.feed t.scan s;
      if Xml_framing.at_boundary t.scan then begin
        ignore (parse_fragment t t.fragment);
        (* parse_fragment trimmed [t.fragment] to the incomplete
           remainder; re-sync the scanner to it. *)
        t.scan <- Xml_framing.feed Xml_framing.initial t.fragment
      end;
      true
    end
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
           let alive = handle_input t ~read_all in
           if not alive then mark_dead t;
           alive
         with e ->
           ignore e;
           mark_dead t;
           false)
  in
  let xml_printer = Xml_printer.make (Xml_printer.TChannel cout) in
  let t = {
    process; out_chan = cout; xml_printer;
    pending_feedback = []; queue = []; head_dispatched = false;
    fragment = ""; scan = Xml_framing.initial; lexerror = None; dead = false;
    max_fragment = default_max_fragment_bytes ();
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

(* Interrupt callback — set by the application to handle ^C during
   the blocking [init] / [block_for_response] path. *)
let interrupt_hook : (t -> unit) option ref = ref None

let set_interrupt_hook f = interrupt_hook := Some f

(* Block until [h] is filled. The only blocking call site post-refactor
   is [init] (which runs once at session creation, before the main
   loop starts). Uses [select_with_watches] so other watches keep
   running and ^C still interrupts via [interrupt_hook]. *)
let block_for_response t h =
  while !h = None do
    let ready = Main_loop.select_with_watches [Unix.stdin] 0.1 in
    if List.mem Unix.stdin ready then
      (match !interrupt_hook with Some f -> f t | None -> ())
  done;
  Option.get !h

let is_busy t = t.queue <> []

let init t filename =
  let h = submit t (Xmlprotocol.init filename) in
  match block_for_response t h with
  | Interface.Good id -> id
  | Interface.Fail (_, _, msg) ->
    failwith ("rocq init failed: " ^ Pp.string_of_ppcmds msg)

let quit t =
  (* Best-effort: send Quit then kill. Don't wait for response — the
     subprocess is being torn down anyway. *)
  (try ignore (submit t (Xmlprotocol.quit ())) with _ -> ());
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
