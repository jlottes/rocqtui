# Rocq protocol — pull-style refactor

Status: design draft. No code yet. Replaces the current mixed
synchronous (`eval_call`) + asynchronous (`send_call` with
continuation) call model in `lib/rocq_protocol.ml` with a single
pull-style model: callers submit, get back a handle, and read the
result from `Session.poll` later.

## Motivation

Two failures have surfaced from the current design:

1. **The assert at `lib/rocq_protocol.ml:88`** (`assert (t.waiting_for
   = None)`) crashes when ^A (About) is pressed shortly after
   verification finishes. The auto-goals refresh chain in
   `Session.poll` (session.ml:357–373) issues an asynchronous
   `set_options` followed by `goals` via `send_call`. While the
   `set_options` response is in flight, a synchronous `Session.query`
   from the keystroke calls `eval_call` → `send_call`, which tries to
   write into the already-occupied `waiting_for` slot. Boom.

2. **More generally,** the synchronous path (`eval_call`) is only
   safe when the call is fast. With a queue of any kind, an
   `eval_call` arriving behind slow queued work would block the UI
   for as long as that work takes, defeating the "this is fast,
   just block" justification.

The right model: drop synchronous calls entirely after the initial
`init`. Every call is non-blocking. Compound operations (Session.query,
fetch_goals_text, rewinds, the goals refresh) become explicit state
machines driven by `Session.poll`, in the same shape as the existing
`needs_rewind`, `goals_dirty`, `target_end`, `user_step_pending`
intents.

## Design

### Protocol layer: handles

`lib/rocq_protocol.ml` exposes only:

```ocaml
type 'a handle = 'a Interface.value option ref

val submit : t -> 'a Xmlprotocol.call -> 'a handle
val poll_response : 'a handle -> 'a Interface.value option

val is_busy : t -> bool       (* queue non-empty *)
val poll : t -> unit          (* run the main loop briefly *)
val quit : t -> unit          (* clears queue, kills subprocess *)
```

Internally, a FIFO holds existentially-typed pending entries:

```ocaml
type pending = Pending : 'a Xmlprotocol.call * 'a handle -> pending

type t = {
  ...
  mutable queue : pending list;   (* head is in flight *)
  mutable dead : bool;
}

let submit t call =
  let h = ref None in
  if t.dead then h
  else begin
    let was_empty = t.queue = [] in
    t.queue <- t.queue @ [Pending (call, h)];
    if was_empty then dispatch_head t;
    h
  end

(* called from the input handler when a final answer arrives *)
let handle_final_answer t xml =
  match t.queue with
  | [] -> ()
  | Pending (call, h) :: rest ->
    t.queue <- rest;
    h := Some (Xmlprotocol.to_answer call xml);
    if rest <> [] then dispatch_head t
```

`init` stays synchronous (it runs once at startup, before the main
loop). Everything else is `submit` + `poll_response`.

### One union to rule them all

Every interaction with rocqtop — including verification — is modeled
as a single tagged union:

```ocaml
type op_state =
  | Op_verifying        of { sentence : sentence_info; pending : add_handle }
  | Op_rewinding        of { target : Stateid.t; pending : edit_at_handle }
  | Op_refreshing_goals of refresh_phase   (* set_options → goals *)
  | Op_query            of pending_query
  | Op_fetch_goals      of pending_goals

mutable current_op : op_state option
```

"Rocq at rest" is the single observable predicate `current_op = None`.
By construction, two ops cannot be active simultaneously — the type
forbids it.

This matches the "Rocq is single-threaded" mental model and aligns
with the user's expectation that a query reflects the post-verification
state: a query press while verification is running waits for the
entire verification to complete (or to be interrupted), not just for
the in-flight sentence.

`Session.poll` reduces to:

```ocaml
let poll t =
  Rocq_protocol.poll t.rocq;
  process_feedback t;
  match t.current_op with
  | Some op -> advance_op t op
  | None ->
    (* Priority order: verification settles the document state first;
       refresh derives display state; user requests come last. *)
    if verified_end t < t.target_end then start_verify t
    else if verified_end t > t.target_end then start_rewind t
    else if t.goals_dirty then start_refresh_goals t
    else match t.pending_query with
         | Some pq -> t.pending_query <- None; start_query t pq
         | None ->
           match t.pending_fetch with
           | Some pf -> t.pending_fetch <- None; start_fetch_goals t pf
           | None -> ()
```

Pending intents are one-deep slots:

```ocaml
mutable pending_query : pending_query option   (* drop-on-second-press *)
mutable pending_fetch : pending_fetch option   (* MCP get_goals *)
```

`Session.query` becomes:

```ocaml
let query ?(extra_opts=[]) t phrase ~reply_to =
  match t.pending_query with
  | Some _ -> ()   (* one already queued; drop *)
  | None ->
    t.pending_query <- Some { phrase; extra_opts; reply_to }
```

The state machine that does the actual setup → query → restore work
lives in `start_query` / the `Op_query` arm of `advance_op`.

### Compound op state machines

All compound ops follow the same shape: a phase enum, advance from
the current phase by polling its handle, transition or finish.

#### `Session.query`

```ocaml
type query_phase =
  | Qp_setup    of { remaining : string list; tip : Stateid.t;
                     pending : (Stateid.t * 'a) Interface.value option ref }
  | Qp_query    of { tip : Stateid.t;
                     pending : unit Interface.value option ref }
  | Qp_restore  of { pending : unit Interface.value option ref }

type reply_target =
  | Reply_msgs                              (* interactive: write to t.msgs *)
  | Reply_mcp of mcp_reply                  (* deferred MCP response *)

(* The intent (set by Session.query) *)
type pending_query = {
  phrase : string;
  extra_opts : Printopts.override list;
  reply_to : reply_target;
}

(* The active state machine (constructed in start_query) *)
type query_op_state = {
  q : pending_query;
  original_tip : Stateid.t;
  setup_msgs : Pp.t list;       (* feedback from setup, discarded *)
  phase : query_phase;
}

(* Stored as Op_query of query_op_state in current_op. *)
```

The driver in `poll`:

```ocaml
let advance_query_op t =
  match t.query_op with
  | None -> ()
  | Some q ->
    match q.phase with
    | Qp_setup r ->
      (match Rocq_protocol.poll_response r.pending with
       | None -> ()
       | Some (Interface.Good (new_id, _)) ->
         process_feedback t;
         (match r.remaining with
          | [] ->
            let h = Rocq_protocol.submit t.rocq
              (Xmlprotocol.query (0, (q.phrase, new_id))) in
            t.query_op <- Some { q with phase = Qp_query { tip = new_id; pending = h } }
          | next :: rest ->
            let eid = t.next_edit_id in
            t.next_edit_id <- eid - 1;
            let call = Xmlprotocol.add ((((next, eid), (new_id, false)), 0), (0, 0)) in
            let h = Rocq_protocol.submit t.rocq call in
            t.query_op <- Some { q with phase = Qp_setup { r with remaining = rest; tip = new_id; pending = h } })
       | Some (Interface.Fail _) ->
         (* setup failed; query at original_tip, no restore needed *)
         let h = Rocq_protocol.submit t.rocq
           (Xmlprotocol.query (0, (q.phrase, q.original_tip))) in
         t.query_op <- Some { q with phase = Qp_query { tip = q.original_tip; pending = h } })
    | Qp_query r ->
      (match Rocq_protocol.poll_response r.pending with
       | None -> ()
       | Some _ ->
         process_feedback t;
         let query_msgs = t.msgs in
         t.msgs <- [];  (* discard setup msgs collected earlier *)
         if Stateid.equal r.tip q.original_tip then begin
           deliver_reply q.reply_to query_msgs;
           t.query_op <- None
         end else begin
           let h = Rocq_protocol.submit t.rocq (Xmlprotocol.edit_at q.original_tip) in
           t.query_op <- Some { q with phase = Qp_restore { pending = h };
                                       setup_msgs = query_msgs }
         end)
    | Qp_restore r ->
      (match Rocq_protocol.poll_response r.pending with
       | None -> ()
       | Some _ ->
         process_feedback t;
         deliver_reply q.reply_to q.setup_msgs;
         t.query_op <- None)

let query ?(extra_opts=[]) t phrase ~reply_to =
  if t.query_op <> None then ()  (* drop; caller can re-try *)
  else begin
    let setup = Printopts.to_vernac_sentences ~override:extra_opts () in
    match setup with
    | [] ->
      let h = Rocq_protocol.submit t.rocq (Xmlprotocol.query (0, (phrase, t.tip))) in
      t.query_op <- Some {
        phrase; original_tip = t.tip; reply_to;
        setup_msgs = [];
        phase = Qp_query { tip = t.tip; pending = h };
      }
    | first :: rest ->
      let eid = t.next_edit_id in
      t.next_edit_id <- eid - 1;
      let call = Xmlprotocol.add ((((first, eid), (t.tip, false)), 0), (0, 0)) in
      let h = Rocq_protocol.submit t.rocq call in
      t.query_op <- Some {
        phrase; original_tip = t.tip; reply_to;
        setup_msgs = [];
        phase = Qp_setup { remaining = rest; tip = t.tip; pending = h };
      }
  end
```

`deliver_reply` either appends to `t.msgs` (interactive) or hands the
result to a registered MCP reply callback (see "MCP" below).

#### `Session.fetch_goals_text` → `goals_op`

Same shape, simpler:

```ocaml
type goals_phase =
  | Gp_set_options of unit handle
  | Gp_fetch       of unit handle  (* actually goals option *)

type pending_goals = {
  all_hyps : bool;
  width : int;
  reply : goals_text_reply;
  phase : goals_phase;
}

mutable goals_op : pending_goals option
```

#### `Session.rewind_to_target` / `rewind_to_state` → `rewind_op`

The current loop ("while verified > target, edit_at to previous
sentence") becomes a state machine that issues one edit_at per poll
tick after the previous one returns.

#### Auto goals refresh in `poll` → `refresh_op`

The set_options + goals chain at session.ml:357–373 becomes a
two-phase state machine on the same pattern, replacing both
`Rocq_protocol.send_call` invocations.

### Atomicity / interleaving

Atomicity is automatic: only one `op_state` can occupy `current_op`
at a time. Verification cannot squeeze between query setup and restore
because it can't start until `current_op = None`, which won't happen
until the query op finishes its restore phase.

The intent priority in `poll` (verify > rewind > refresh > query >
fetch) ensures queries wait for verification to settle, matching the
"Rocq is single-threaded" mental model. A query press during a long
Alt+End verification waits until verification reaches target (or
until the user interrupts with Alt+.).

### Cancellation

- **Tab close / `Session.quit`**: set `current_op <- None`,
  `pending_query <- None`, `pending_fetch <- None`, then call
  `Rocq_protocol.quit t.rocq` which sets `dead <- true`, clears the
  queue, kills the subprocess. Any handles still held remain `None`
  forever, harmless.
- **`Session.interrupt` (Alt+.)**: cancel everything user-initiated.
    1. Clear pending intents: `pending_query <- None`,
       `pending_fetch <- None`. For each cleared entry whose
       `reply_to` is `Reply_mcp _`, deliver an `interrupted` error
       reply so the bridge stops polling.
    2. Send SIGINT to rocqtop.
    3. The in-flight call (if any) returns Fail; the active op's
       Fail handler runs (see "Per-op Fail behavior" below).

  Convention: every Fail handler must either clear `current_op` or
  transition into a finite cleanup phase that eventually clears it,
  so we never get stuck.

#### Per-op Fail behavior

| Op | On Fail |
|----|---------|
| `Op_verifying` | Drop the Processing sentence, lower `target_end` to `verified_end`, clear `current_op`. |
| `Op_rewinding` | Leave verified state as-is (rocqtop's `safe_id` semantics handle the actual position), clear `current_op`. |
| `Op_refreshing_goals` | Clear `current_op`. (Goals just stay stale until next refresh trigger.) |
| `Op_query` (Qp_setup) | If any setup sentence succeeded (tip ≠ original_tip), issue `edit_at original_tip` to restore, then deliver `interrupted` reply and clear. Otherwise just deliver and clear. |
| `Op_query` (Qp_query / Qp_restore) | Deliver `interrupted` reply (or the partial `query_msgs` for a Qp_restore Fail), clear. |
| `Op_fetch_goals` | Deliver `interrupted` reply, clear. |
- **No closures over `Session.t`** anywhere. All state lives in `t`'s
  fields; the state machine reads current `t` at advance time.

### Hazards revisited

- **Stale state in continuations**: not applicable. State machines
  read fresh `t` on each poll tick; no captured-at-call-site values
  survive past one transition.
- **Edits during a query**: Session.query's `original_tip` was valid
  when the user pressed ^A. If the user advances `target_end` while
  the query is running, verification waits (compound-op gate).
  After the query's restore completes, poll resumes verification from
  `original_tip` toward the new `target_end`. Same outcome as today.
- **Tab close while query in flight**: handles never fire, fields
  cleared on quit, no leak.

## MCP server: split sync handlers into start / poll

The two MCP tools that currently call synchronous Session functions:

- `query` → `Session.query` (session.ml:521)
- `get_goals` → `Session.fetch_goals_text` (session.ml:553)

Both run on the main thread inside `dispatch_message`
(mcp_server.ml:1106) and produce the JSON-RPC result inline. After
the refactor, neither Session function returns synchronously, so the
MCP layer needs a deferred-reply mechanism.

### Server-side changes

Replace each synchronous tool with a **start** tool that returns a
ticket, plus a **poll** tool that reports status / result.

```
query        →  query_start  (returns { ticket: "q-N" })
                query_poll   (args: { ticket }; returns
                              { status: "pending" }
                              | { status: "done", text: "..." })

get_goals    →  get_goals_start  (returns { ticket: "g-N" })
                get_goals_poll   (args: { ticket }; returns
                                  { status: "pending" }
                                  | { status: "done", text: "..." })
```

The server keeps a small `pending_replies : (ticket, ticket_state)
Hashtbl.t`. `*_start` initiates the Session op with `reply_to =
Reply_mcp ticket_id` and stores a slot in the table. The Session op,
on completion, writes the result into the slot. `*_poll` reads it.

Tickets are reaped after delivery and after a TTL to avoid leaks if
the bridge disconnects mid-poll.

This keeps the MCP server pure non-blocking: handlers always return
immediately, never spin the main loop.

### Bridge-side changes

`bridge/rocqtui_mcp.ml` already provides synchronous wrappers for
high-level operations. The wrappers for `query` and `get_goals`
become the natural place for the start/poll loop:

```ocaml
let query_sync conn args =
  match call_tool conn "query_start" args with
  | Some (`Assoc fields, _) ->
    let ticket = List.assoc "ticket" fields |> ...to_string in
    let rec wait () =
      match call_tool conn "query_poll" (`Assoc ["ticket", `String ticket]) with
      | Some (result, _) when status_of result = "done" ->
        text_of result
      | _ ->
        Unix.sleepf 0.05;
        wait ()
    in
    wait ()
  | _ -> ...
```

The bridge already polls in a loop for high-level "prove" workflows,
so this fits the existing shape. Polling cadence: start at 50 ms,
back off to 250 ms after a few seconds, capped at 1 s. Total wait
unbounded (the user can ^C the bridge process if needed).

Alternative: a **server-pushed completion notification** via a
JSON-RPC notification (`rocqtui/op_done`) that the bridge listens
for, eliminating polling. Cleaner but requires the bridge to multiplex
responses with notifications. Worth considering if poll latency hurts.

### Other MCP tools to audit

A pass through `handle_tool` in mcp_server.ml will identify any other
handler that touches `Session.query`, `fetch_goals_text`, or rewinds.
Suspects to verify:

- `step_to`, `step_forward`, `rewind` — these set `target_end` and
  let `Session.poll` drive verification, so they're already
  pull-shaped. Confirm they still report status correctly through the
  new compound-op gate.
- `is_busy` — its semantics shift slightly: `is_busy = true` if any
  compound op is active (today: rocq queue non-empty OR verified < target).

## Migration order

Land in small commits to keep `dune build` green at each step:

1. **Add the queue + handle API to `Rocq_protocol`.** Keep
   `eval_call` and `send_call` working as wrappers (eval_call =
   submit + busy-loop poll_response; send_call = submit + record
   continuation in a thin shim). No call-site changes. ^A still
   crashes — the assert is just gone, replaced by ordering in the
   queue. *Verify:* unit tests pass, e2e smoke passes.

2. **Introduce `current_op` union with `Op_query` only.** Add the
   `pending_query` slot and the priority-ordered dispatch in
   `Session.poll`. Verification still uses `eval_call` for now, but
   gates on `current_op = None` (verification's `is_busy` check
   becomes `is_busy || current_op <> None`). Convert `Session.query`
   to set `pending_query` and run as a state machine. The keystroke
   binding already returns `Continue` immediately, so the editor side
   is unchanged. *Verify:* ^A no longer crashes; About output
   appears in the Rocq messages pane after a brief delay.

3. **Add `Op_verifying` to the union.** Replace verification's
   `eval_call`-based `submit_next_sentence` with a state machine
   step. After this, verification participates in `current_op` and
   the gate condition simplifies to just `current_op = None`.

4. **Add `Op_refreshing_goals`.** Convert the auto goals refresh
   chain in `Session.poll` (the last `send_call`-with-continuation
   site).

5. **Add `Op_fetch_goals` with `pending_fetch`.** Convert
   `Session.fetch_goals_text`. Reply targets so MCP can deliver
   asynchronously.

6. **Add `Op_rewinding`.** Convert `Session.rewind_to_target` and
   `rewind_to_state`.

7. **Split MCP `query` and `get_goals` into start/poll pairs.**
   Update bridge wrappers to do the poll loop.

8. **Delete `eval_call` and `send_call`-with-continuation.** Only
   `submit` remains. Audit `is_busy` callers (lib/, MCP server,
   bridge) for the new meaning.

## Decisions

- **Single `current_op` union covering verification too.** Picked over
  field-per-op so atomicity holds by construction.
- **Drop second query when one is pending.** `pending_query` is a
  one-deep slot; second ^A is silently ignored until the first
  completes.
- **MCP polling first, notification later if needed.** Bridge-side
  poll loop with a 50–250 ms backoff. Revisit only if latency hurts.

## Remaining things to verify during implementation

- **`set_options` + `goals` after every step.** Today this fires once
  per `goals_dirty` transition. If the user does many quick steps,
  it could fire repeatedly; verify `Op_refreshing_goals` collapses
  runs the same way (gate on `goals_dirty` only when `current_op =
  None`).
- **Audit `is_busy` callers in bridge/MCP** for the new meaning
  (`current_op <> None` rather than "rocq pipe occupied"). MCP's
  `is_busy` tool docs may need updating.
- **MCP `interrupted` reply shape.** Pick a JSON-RPC convention for
  "user cancelled" — probably `isError: true` with a typed error
  string. Bridge translates this into a thrown exception or a sentinel
  return value for high-level wrappers.
