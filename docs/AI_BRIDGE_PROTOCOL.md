# AI bridge protocol — v0

The wire format between rocqtui and the `ai-bridge` process. This is
v0 — treated as draft. Failures from mismatched shapes should be
loud (a rebuild of either end is acceptable). No version negotiation.

See [`AI_BRIDGE_PLAN.md`](AI_BRIDGE_PLAN.md) for the build plan and
[`AI_SUGGESTIONS_PLAN.md`](AI_SUGGESTIONS_PLAN.md) for the overall
design.

## Transport

Unix socket at `$XDG_RUNTIME_DIR/rocqtui-ai-bridge.sock` (override
with `--socket PATH` when launching the bridge).

Each connection carries **exactly one request and zero or more
streamed responses**, then closes. Rocqtui can pool or open per-
request; the bridge is connection-stateless.

Framing: **newline-delimited JSON (NDJSON)**. Each line is a single
complete JSON object terminated by `\n`. No multi-line JSON.

## Request

The client writes exactly one JSON line, then half-closes the write
side of the socket (`shutdown(SHUT_WR)`). The server uses EOF as the
signal that the request is complete.

```json
{
  "req_id": "abc-123",
  "kind": "suggest",
  "buffer": "...full text of the active script buffer...",
  "cursor": {"line": 42, "col": 18},
  "language": "rocq",
  "recent_edits": [
    {"before": "Definition foo {X Y : Set} (n : nat) ...",
     "after":  "Definition foo (n : nat) ..."}
  ]
}
```

Fields:

| Field | Type | Notes |
|---|---|---|
| `req_id` | string | Caller-chosen correlation id. Echoed in every response line. |
| `kind` | string | Currently always `"suggest"`. Reserved for future `"warmup"`, `"shutdown"`. |
| `buffer` | string | Full text of the active script buffer. |
| `cursor` | object | `{line, col}`, both 0-indexed. |
| `language` | string | `"rocq"` for now. Reserved for future language gating. |
| `recent_edits` | array | Zero or more `{before, after}` strings, oldest first. Bridge caps internally at 8 entries. |

## Responses

The server writes one or more JSON lines, each correlated by
`req_id`. The last line is always `type: "done"`. Then the server
closes the connection.

### FIM completion

```json
{"req_id": "abc-123", "type": "fim", "insertion": "g (f x)"}
{"req_id": "abc-123", "type": "done"}
```

### Edit suggestions (streaming)

One `edit` line per anchored change, emitted as soon as that change
parses successfully — *not* batched until the end.

```json
{"req_id": "abc-123", "type": "edit",
 "change": {
   "range": {"start_line": 41, "start_col": 0,
             "end_line": 41, "end_col": 58},
   "replacement": "Definition qux (p : nat * nat) : nat := fst p."
 }}
{"req_id": "abc-123", "type": "edit", "change": {...}}
{"req_id": "abc-123", "type": "done"}
```

All `start_line` / `end_line` / `start_col` / `end_col` are
0-indexed. Ranges are half-open at the end:
`buffer[start_offset..end_offset]` is exactly the text to replace.

### No suggestion

```json
{"req_id": "abc-123", "type": "done"}
```

### Error

The bridge can emit an error mid-stream (e.g. `llama-server`
disconnects after some edits have already streamed). Prior `edit` /
`fim` lines remain valid; the client decides whether to keep them.

```json
{"req_id": "abc-123", "type": "error",
 "message": "llama-server unreachable", "code": "backend_unreachable"}
{"req_id": "abc-123", "type": "done"}
```

Defined `code` values for v0:

| code | meaning |
|---|---|
| `backend_unreachable` | `llama-server` couldn't be contacted. |
| `backend_error` | `llama-server` returned an HTTP error. |
| `bad_request` | request didn't parse as JSON or was missing required fields. |
| `internal` | uncaught exception in the bridge. |

## Cancellation

v0 cancellation = **client closes the connection**. The bridge
detects the socket close, cancels its outstanding `llama-server`
HTTP request (also by closing that connection), reaps the task, and
exits the handler. There is no explicit cancel message.

If rocqtui needs to cancel across connections later (e.g. one socket
per session), a `{"req_id": "...", "kind": "cancel"}` request type
can be added in v1.

## Concurrency

The bridge accepts multiple connections concurrently. Internally it
serializes against `llama-server`, which does not multiplex
requests. Practical effect: a second simultaneous request waits its
turn but the socket stays responsive.

## Examples

### Smallest valid request

```json
{"req_id": "1", "kind": "suggest",
 "buffer": "Definition x := ",
 "cursor": {"line": 0, "col": 16},
 "language": "rocq",
 "recent_edits": []}
```

Response (assuming a FIM suggestion is produced):

```json
{"req_id": "1", "type": "fim", "insertion": "42"}
{"req_id": "1", "type": "done"}
```

### Edit propagation

Request:

```json
{"req_id": "2", "kind": "suggest",
 "buffer": "Definition foo (n : nat) ...\nDefinition bar {X : Type} (b : bool) ...",
 "cursor": {"line": 1, "col": 0},
 "language": "rocq",
 "recent_edits": [
   {"before": "Definition foo {X : Type} (n : nat) ...",
    "after":  "Definition foo (n : nat) ..."},
   {"before": "Definition baz {X : Type} ...",
    "after":  "Definition baz ..."}
 ]}
```

Response, streamed as blocks parse:

```json
{"req_id": "2", "type": "edit", "change": {...}}
{"req_id": "2", "type": "done"}
```
