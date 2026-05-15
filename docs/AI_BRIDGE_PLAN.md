# AI bridge — build plan

Status: design draft. No code yet. Specifies the order of work for
building the AI bridge process and its fake-client harness, *before*
any rocqtui-side wiring. Companion to
[`AI_SUGGESTIONS_PLAN.md`](AI_SUGGESTIONS_PLAN.md), which has the
overall design and Phase 0 measurements.

## Why bridge-first

The bridge is a self-contained process with a JSON-in/JSON-out
interface. The hard parts — prompt engineering, stream parsing,
anchor matching, classifier heuristic, request cancellation — are
independent of rocqtui's render path. Python iteration is much
faster than OCaml + TUI iteration, so we can grow a comprehensive
test corpus and pressure-test the design with a synthetic consumer
before paying any OCaml-build cost.

Phase 0 already validated the core logic and the wire-format shape;
this plan is engineering, not design discovery.

The risk to manage: designing for an imagined rocqtui consumer. The
*fake client* mitigates that by exercising the bridge from a
consumer's perspective without OCaml. By the time rocqtui's
`Ai_client` is wired up, the bridge has been hardened by a synthetic
consumer that hits the same patterns.

## Scope

In scope:

- New top-level `ai-bridge/` directory in this repo with a Python
  package, tests, and a CLI fake client.
- A wire-format spec, treated as v0 (expect revisions once rocqtui
  consumes it).
- Production-quality bridge: streaming, cancellation, error
  reporting, logging.
- Test corpus of 20+ scenarios driving CI.

Out of scope:

- Any rocqtui code changes. The bridge knows nothing about OCaml.
- Multi-file context. Single-buffer requests only.
- Auth / multi-user. Unix socket permissions are sufficient.
- Model selection logic. `llama-server` is launched externally
  with the model already chosen (7B + 1.5B-draft per Phase 0).

## Repo layout

```
ai-bridge/
├── pyproject.toml             # python project metadata, deps, scripts
├── README.md                  # how to run, how to develop
├── ai_bridge/
│   ├── __init__.py
│   ├── protocol.py            # request/response dataclasses, JSON schema
│   ├── llama.py               # llama-server HTTP client, SSE streaming
│   ├── parse.py               # S/R block parser, anchor matching
│   ├── prompts.py             # system prompts for FIM and edits
│   ├── classify.py            # count-based heuristic classifier
│   ├── server.py              # Unix socket server, request dispatch
│   └── __main__.py            # `python -m ai_bridge` entry point
├── ai_bridge_cli/             # fake rocqtui client
│   ├── __init__.py
│   └── main.py
├── scenarios/                 # JSON test scenarios — the long-lived asset
│   ├── fim/
│   │   ├── compose.json
│   │   └── ...
│   ├── edits/
│   │   ├── implicit-uniform.json
│   │   └── ...
│   └── none/
│       └── ...
└── tests/
    ├── test_classify.py
    ├── test_parse.py
    ├── test_anchor.py
    └── test_e2e.py            # needs running llama-server; skipped unless env set
```

Plain Python, stdlib-only where reasonable. Likely deps: none for
the bridge itself (urllib + socket + json + re are enough); `pytest`
for tests; the `unidiff` lib only if we later add unified-diff
parsing as a fallback to S/R blocks.

## Protocol

See [`AI_BRIDGE_PROTOCOL.md`](AI_BRIDGE_PROTOCOL.md) for the v0
wire-format spec. Summary: NDJSON over Unix socket, one request +
streamed responses per connection, cancellation = socket close,
no version negotiation (fail loud, rebuild).

## Bridge components

In dependency order, each ~50-150 lines:

1. **`protocol.py`** — dataclasses for `Request`, `EditChange`,
   `Response` variants. JSON serialization helpers. Single source
   of truth for the schema.

2. **`llama.py`** — wraps the `llama-server` HTTP API. Two
   functions: `infill(prefix, suffix, ...)` (one-shot) and
   `chat_stream(messages, ...)` (yields content chunks). Uses
   stdlib `urllib` + manual SSE line parsing — no aiohttp.
   Connection cancellation closes the underlying TCP connection.

3. **`parse.py`** — `parse_sr_blocks(text) -> list[(search, replace)]`
   regex parser. `anchor(buffer, search, replace) -> change_or_none`
   that returns a `range` only if `search` is unique in the buffer.

4. **`prompts.py`** — `EDIT_SYSTEM_PROMPT` and helpers to build the
   user message from `(buffer, recent_edits)`. FIM prompts are
   trivial enough to inline in `server.py`.

5. **`classify.py`** — single function:
   ```python
   def classify(recent_edits: list[Edit]) -> Literal["fim", "edits"]:
       return "edits" if len(recent_edits) >= 2 else "fim"
   ```
   Phase 0 confirmed this gets every scenario right. A docstring
   notes that this heuristic is the fallback if a future
   model-based classifier doesn't pan out.

6. **`server.py`** — Unix socket loop. Per accepted connection:
   read one NDJSON request, dispatch to FIM or edits handler, stream
   results back, close. Uses `asyncio` (stdlib) or threaded
   `socketserver`; preference for `asyncio` so cancellation on
   socket close is natural.

   The edits handler is the streaming path:
   - Build prompt, call `llama.chat_stream`.
   - Accumulate content as it arrives.
   - After each chunk, re-scan accumulated text for new fully-formed
     S/R blocks. For each new block, run `parse.anchor`. If it
     anchors, write an `edit` response line immediately. If it
     doesn't, log and discard.
   - When the stream ends, write the `done` sentinel.

7. **`__main__.py`** — `python -m ai_bridge --socket PATH
   --llama-url http://...:8080`. Wires the server up and runs it.

## Fake client

`ai_bridge_cli/main.py`. Modes:

```
ai-bridge-cli scenario tests/scenarios/edits/implicit-uniform.json
ai-bridge-cli file path.v --line 42 --col 18 \
              [--history path-to-history.json]
ai-bridge-cli watch                        # repeat: read stdin, send, print
```

The `scenario` mode reads a JSON scenario (request + expected) and
emits a pass/fail badge + the response stream. This is what CI uses.

The `file` mode constructs a request from a real `.v` file and an
optional history JSON. Useful for ad-hoc human testing — points at
the bridge socket and prints the streamed responses to stdout. This
is the "synthetic consumer" that catches API issues before rocqtui
does.

The `watch` mode lets you pipe a stream of JSON requests in and
print responses. Useful for stress-testing or driving from another
script.

The CLI client uses the same `protocol.py` as the bridge — that's
the single source of truth for the wire format.

## Test corpus

Lives in `ai-bridge/scenarios/`. Each scenario is a JSON file:

```json
{
  "id": "edits-implicit-uniform",
  "description": "user removes {X Y : Set} from 3 definitions, expects 4 more",
  "request": {
    "kind": "suggest",
    "buffer": "...",
    "cursor": {"line": 0, "col": 0},
    "language": "rocq",
    "recent_edits": [...]
  },
  "expected": {
    "kind": "edits",
    "min_changes": 4,
    "max_changes": 4,
    "must_contain_each": [
      "Definition qux (p : nat * nat)",
      "Definition wibble (s : string)",
      "Definition wobble (a : nat) (b : nat)",
      "Definition flub (l : list bool)"
    ]
  }
}
```

Start by porting the 10 Phase 0 scenarios. Then grow to ~25-30 by
adding:

- More FIM contexts: let-bindings, fixpoints, record literals,
  notation/class boilerplate, proof-script tactics (expected to
  fail until Phase 3.5 Rocq-aware integration).
- More edit patterns: insertion-only, deletion-only, rename-with-
  body-update, swap-keyword, refactor-to-typeclass, multi-step
  chained edits.
- Edge cases: empty buffer, buffer with only one definition, edits
  larger than one line, edits that span newlines, recent edits that
  are non-pattern (expect `kind: fim` or `kind: none`).
- Negative cases: where the bridge should NOT suggest edits — e.g.
  recent edits are random typo fixes that don't generalize.

`test_e2e.py` runs every scenario through a live bridge against a
running llama-server. Skipped in unit-CI unless `AI_BRIDGE_E2E=1`
is set. Local invocation:

```
AI_BRIDGE_E2E=1 pytest ai-bridge/tests
```

Phase 0's `/tmp/run_model_evals.sh` becomes
`ai-bridge/tests/bench_models.py` as an offline benchmark for
re-evaluating models when the corpus grows.

## Milestones

| # | Deliverable | Roughly |
|---|---|---|
| M1 | This plan + `docs/AI_BRIDGE_PROTOCOL.md` (spec extracted) | trivial |
| M2 | Repo skeleton: `ai-bridge/` layout, pyproject, README, CI hook | half-day |
| M3 | `protocol.py` + `llama.py` + `parse.py` from prototype, with tests | half-day |
| M4 | `classify.py` + `prompts.py` + minimal `server.py` (FIM only) | half-day |
| M5 | Streaming `server.py` (edits shape), fake client `scenario` mode | half-day |
| M6 | Test corpus ported and expanded to ~25 scenarios | half-day |
| M7 | Cancellation, logging, error handling, fake client `file` mode | half-day |
| M8 | Bench harness rebuilt as Python tests; doc updates | half-day |

At M5 the bridge is functionally complete and rocqtui-side work
could start in parallel. M6-M8 harden it.

## Open decisions

- **Async or threaded?** Lean asyncio — cancellation on socket close
  is much cleaner. Stdlib only; no aiohttp dependency.
- **Logging destination?** Stderr by default, `--log-file PATH`
  override. Production use behind systemd-user will capture stderr
  to the journal.
- **Configuration?** CLI flags only in v0. No config file.
  Reasonable env-var overrides: `AI_BRIDGE_SOCKET`,
  `AI_BRIDGE_LLAMA_URL`, `AI_BRIDGE_LOG_LEVEL`.
- **One process or one-process-per-rocqtui?** One bridge process,
  multiple connections. Lets ghost-text and edit-shape requests be
  in flight for the same user without serializing on a single
  inflight request. The bridge serializes against `llama-server`
  itself, which doesn't multiplex.
- **What happens if `recent_edits` is huge (long session)?** Cap at
  N most-recent entries inside the bridge. Reasonable default 8.
  No need for rocqtui to do this — bridge handles it.
- **Model load failure / hot reload?** Out of scope. If
  `llama-server` is restarted with a different model, the bridge
  is oblivious — it just sees different responses. No model-side
  state in the bridge.
