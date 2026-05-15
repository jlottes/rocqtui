# AI inline suggestions — plan

Status: design sketch plus Phase 0 results. UX outline and bridge
architecture validated against a Python prototype driving
`llama-server` with Qwen2.5-Coder-Instruct (Q4_K_M, 1.5B / 3B / 7B
compared, 1080 Ti). See [Phase 0 — viability
check](#phase-0--viability-check-done) for measurements.

## Goals

Provide AI-generated code suggestions inside the script pane:

- **Unobtrusive.** Never moves text, never grabs focus, never inserts
  anything without an explicit user keystroke.
- **Opt-in at every step.** Suggestions render but do nothing until
  accepted. A globally-disabled mode hides them entirely.
- **Local-only.** Backend is a `llama-server` instance on
  `127.0.0.1`. No network egress.
- **Composable acceptance.** Accept a prefix of the suggestion (one
  word, one line, all) so the user can use whatever portion is correct
  and keep typing the rest.
- **Plays with the existing TUI.** No overlays, popups, or modal
  panes. Visual signal is colors + dim style on inline text only.

Non-goals for the first iteration:

- Proof-tactic suggestions that depend on the live Rocq goal state.
  (Vanilla FIM hallucinates tactics, as confirmed in experiments.
  See [Phase 3 / Rocq-aware](#phase-3--rocq-aware-proof-suggestions).)
- Multi-file or repo-level context. The prompt is the current buffer
  only.

## One trigger, two suggestion shapes

There's a single user-facing concept: "AI suggests something." Behind
the scenes there are two distinct *response shapes* the model can
emit. The model picks which one is useful given the context — it's
not the user's job to choose.

### The unified request

On the existing idle-pause trigger (~300 ms after the last keystroke,
no other request in flight), one HTTP request goes to the backend
containing:

- The current buffer (or a window around the cursor for long files).
- The cursor position.
- A short ring of recent edits (last N edit events from this tab and
  optionally adjacent tabs).
- A small instruction asking the model to respond with one of three
  things, as JSON:

```json
{ "kind": "fim",   "insertion": "g (f x)" }
{ "kind": "edits", "changes": [ {"range": [..], "replacement": ".."} ] }
{ "kind": "none" }
```

The model decides:

- If the user just made a series of similar edits, the recent-edit
  ring biases it toward `kind: "edits"` with pattern-propagated
  changes elsewhere in the buffer.
- If the user is in the middle of typing a fresh expression, the
  cursor context biases it toward `kind: "fim"` with a single
  inline completion.
- If nothing useful comes to mind, `kind: "none"` — the UI silently
  shows no suggestion.

This collapses both shapes onto a single trigger and avoids burdening
the user with mode selection. It does add a small classification
burden on the model itself; **whether a 7B model can do this
reliably in JSON is an open question that we should validate in an
early prototype** before committing to the design (see [Open
questions](#open-questions)).

### Shape A — inline completion (FIM-style)

`kind: "fim"` is rendered as **ghost text**: dimmed,
distinguishable-color glyphs to the right of (and possibly below)
the cursor that aren't part of the buffer.

Use cases this is good at, from experiments:

- Function bodies (`fun x => g (f x)`)
- Pattern-match arms (`S (length t)`)
- Type signatures (constructor types in inductives)
- Lemma statements
- Library boilerplate

### Shape B — edit prediction (multi-location)

`kind: "edits"` is rendered as colored highlights on the existing
buffer text plus phantom inserted lines (see [Visual
design](#visual-design)). Use cases:

- Mechanical refactors across many definitions
- Consistent parameter renames
- Semantic rewrites that follow a uniform mapping
  (e.g. `match n with S^k O => true | _ => false` → `n = k`).

Shape B is the one the user described in the original question. It
is NOT classic FIM — FIM has no notion of "what just changed." It
needs the diff history of recent edits as part of the prompt, which
is why every request includes the recent-edit ring whether or not
the model ends up using it.

## Visual design

### Shape A — ghost text after cursor

```
   ┌────────────────────────────────────────────────────┐
   │  Definition compose {A B C} (g : B → C) (f : A     │
   │    → B) : A → C := fun x =>█g (f x).               │
   │                            └─dimmed ghost text─┘   │
   └────────────────────────────────────────────────────┘
```

- Ghost glyphs use a "dim" attribute (or a low-contrast theme color
  named `theme.ai_ghost`) so they're visibly suggestion-only.
- If the suggestion contains a newline, the ghost continues into
  subsequent rows. Lines below the cursor get pushed down visually —
  but the buffer's actual line numbers don't change. The gutter shows
  the real, unchanged line numbers; the ghost rows have no number.
- If a real character occupies the cell where ghost would go, ghost
  yields. (We never render over real text.)

Open question: in vte mode (e.g. when terminal pane is focused) we
naturally suppress all suggestions. Keep that simple — suggestions
only render when the script pane has focus.

### Shape B — multi-location diff

A predicted-edit set is rendered as colored highlights on the
existing buffer text, plus phantom inserted lines where new content
is suggested.

Two style classes:

- `theme.ai_delete`: dim red background OR strikethrough on the
  characters that would be removed.
- `theme.ai_insert`: dim green background on the characters that
  would be added. For new lines, those rows have no gutter number
  (mirroring ghost text in shape A).

Multiple predicted edit *sites* are flagged. There's a "current
site" — the one the cursor is at (or the nearest below). Jump
keybindings move between sites. Accept/reject keys act on the current
site.

### Status indicator

A small AI-state widget lives in the chrome — likely in the script
pane's status line, far right, so it doesn't compete with the buffer
state already shown there:

| Glyph | Meaning |
|---|---|
| `[AI ●]` | enabled, idle |
| `[AI ◐]` | request in flight |
| `[AI ✦]` | suggestion ready |
| `[AI ·]` | enabled, no suggestion |
| `[AI ○]` | globally disabled |
| `[AI !]` | backend unreachable |

## Keybindings

Acceptance has to be in the user's flow without colliding with
existing density (see `lib/keys.ml`). Proposal:

| Key | Action | Shape |
|---|---|---|
| **Tab** (while ghost shown) | Accept entire suggestion | A |
| **Alt+→** | Accept next word | A |
| **Alt+↓** ⚠️ | Accept next line | A |
| **Esc** / any other typing | Dismiss ghost | A |
| **^]** / **^[** | Jump to next / previous predicted site | B |
| **Tab** (at predicted site) | Accept site | B |
| **Alt+A** ⚠️ | Accept all predicted sites | B |
| **Alt+Backspace** | Reject current site | B |
| **^G** | Toggle AI globally on/off | A+B |
| **^G ^Space** | Force a suggestion request now (bypass idle delay) | A+B |

No mode-selection key — the model classifies. Acceptance keys mostly
overlap (`Tab` accepts whichever shape is on screen). Only the
site-navigation keys (`^]` / `^[`) are exclusive to shape B and they
only do anything when a shape-B suggestion is visible.

⚠️ conflicts to resolve:

- **Alt+↓** is currently `Step forward` (Rocq verification). Need a
  different binding. Options: **Shift+→** (accept line), or a chord
  `^G l`.
- **Alt+A** is currently "Replace all matches" inside the find
  panel. Outside that panel it appears free — verify against
  `lib/keys.ml`.
- **Tab** in the script pane: confirm not bound to anything (it's
  the find/replace toggle but only inside the find panel; in the
  script pane I believe it's currently inserted as a literal tab —
  this would need to be conditional on "ghost text is active").

A simpler safer first cut: introduce a leader **^G** and put all AI
commands behind it (^G ^G accept all, ^G w accept word, ^G l accept
line, ^G t toggle, ^G p predict, ^G n next site, etc). Pros: zero
conflict, easy to remember. Cons: more keystrokes per acceptance,
defeats the "in-flow" goal.

Decision: support both. Default to direct keys (Tab / Alt+→ / etc.)
for shape-A acceptance, with a `^G`-leader for everything else and as
a fallback. Make all of these reconfigurable in `lib/keys.ml`.

## Trigger logic

There is one trigger that produces either shape (or nothing) per the
model's choice.

- Idle for **N ms** since last keystroke (default 300 ms) **and**
  AI is enabled **and** the previous request isn't still pending →
  issue a unified request.
- Any keystroke cancels the in-flight request and dismisses any
  visible ghost or edit overlay.
- Acceptance keys consume the suggestion (writing accepted text /
  applying accepted edits to the buffer) and then re-trigger after
  the same idle delay.
- Explicit trigger: **^G ^Space** forces a request immediately.

Don't request on:
- Cursor moves without edits (move-only doesn't usefully change the
  completion context).
- During Rocq verification activity that's blocking the UI.
- While a modal panel (find, build menu, file picker) is open.

The recent-edits ring is **always** included in the request body
regardless of cursor activity, so the model can choose `kind:
"edits"` even right after the user moved away from an edit cluster.

## Architecture: AI bridge process

Rocqtui does **not** talk to `llama-server` directly. Between them
sits a wrapper process — call it the **AI bridge** — that owns
everything model-shaped:

```
   ┌─────────┐   stable narrow JSON     ┌──────────────┐
   │ rocqtui │ ───────────────────────► │  ai-bridge   │
   │         │ ◄─────────────────────── │  (Python)    │
   └─────────┘  (kind, fim or edits[])  └──────┬───────┘
                                               │  HTTP
                                               ▼
                                         ┌────────────┐
                                         │ llama-server│
                                         │   :8080     │
                                         └────────────┘
```

### Why a wrapper

LLMs are good at emitting **recognizable text formats** they've seen
in training — unified diff hunks, before/after blocks, search/replace
markers. They are **bad at producing byte ranges or character
counts**. Asking a 7B model to return `{"range": [127, 145], ...}` is
asking it to do arithmetic it doesn't do well; asking it to produce
a unified diff and parsing that in Python is much more reliable.

The wrapper translates between "what the model is good at producing"
and "what rocqtui needs to apply an edit cleanly." It also isolates
all the messy parts (prompt templates, response parsing, anchor
resolution, output validation, retry logic) from the main editor
binary.

### What the wrapper owns

1. **Classification** — decide which prompt template to send
   (FIM vs. edit-pattern vs. nothing) via a count-based heuristic on
   the recent-edits ring (`≥ 2 recent edits → edits-shape`). Phase 0
   confirmed this gets every scenario right; no model-based
   classification call needed.
2. **Prompt selection** — for FIM, use Qwen's `<|fim_*|>` tokens via
   `/infill`. For edits-shape, use Aider-style search/replace blocks
   via `/v1/chat/completions`. (Phase 0 confirmed S/R blocks parse
   cleanly; unified diff was not tried.)
3. **Streaming consumption** — read SSE from llama-server and parse
   S/R blocks incrementally, emitting each anchored change as soon
   as it's complete. Phase 0 measured this as the biggest perceived-
   latency win.
4. **Parsing & validation** — convert the model's natural-text
   output into concrete buffer ranges by anchor-matching against
   the buffer it received. If anchors don't match, **discard the
   suggestion** rather than ship a corrupt edit to rocqtui. This
   was the critical guard in Phase 0's mixed-context scenario.
5. **Backend management** — owns the `llama-server` HTTP client,
   request cancellation, model-specific quirks (Qwen FIM tokens,
   stop strings, etc.). Production setup runs llama-server with
   `--spec-draft-model` pointing at the 1.5B GGUF for ~1.6× total
   speedup at zero quality cost.

### Failure modes are contained

- AI bridge crashes → rocqtui shows `[AI !]`, AI feature dormant,
  user keeps editing.
- llama-server is down → bridge returns `kind: none` quickly;
  rocqtui shows `[AI !]` but everything else works.
- Model returns garbage that doesn't parse / doesn't anchor →
  bridge returns `kind: none`; nothing is shown.

### Transport

Unix socket in the user's runtime dir, same pattern as MCP and
headless mode. JSON-line request/response. Connection-per-request
is fine; bridge is a long-lived process.

### Wrapper protocol (rough)

Request from rocqtui to bridge:

```json
{
  "buffer": "...full text or windowed slice...",
  "cursor": { "line": 42, "col": 18 },
  "language": "rocq",
  "recent_edits": [
    {
      "kind": "replace",
      "before": "Definition foo {X Y : Set} (n : nat) ...",
      "after":  "Definition foo (n : nat) ...",
      "line_hint": 38
    }
  ]
}
```

Response from bridge to rocqtui:

```json
{ "kind": "fim", "insertion": "g (f x)" }
```

or

```json
{
  "kind": "edits",
  "changes": [
    {
      "range": { "start_line": 42, "start_col": 16, "end_line": 42, "end_col": 36 },
      "replacement": ""
    }
  ]
}
```

or `{ "kind": "none" }`.

Ranges are **resolved against the buffer the bridge was sent**. If
the buffer drifted in flight (the user kept typing), rocqtui's
acceptance flow re-validates by anchor before applying. Worst case:
discard and re-request.

### Model-side prompts (illustrative)

For shape A (`kind: "fim"`) the wrapper uses Qwen's FIM tokens
directly via `/infill`. Cheap, clean, no parsing burden.

For shape B (`kind: "edits"`) the wrapper sends a chat-completion
request that asks for Aider-style search/replace blocks (Phase 0
confirmed these parse cleanly with the 7B model). The SSE response
is consumed incrementally — each S/R block is anchor-matched and
emitted as soon as it's fully received, instead of waiting for the
full response.

### `/infill` vs `/v1/chat/completions`

Both endpoints on `llama-server` are used, picked by the wrapper
depending on the kind selected. rocqtui doesn't know either endpoint
exists.

```
       script pane             new module: Ai_client (lib/ai/)
        |                       |
        v                       v
   on idle pause     ────►   issue unified request
                                 |
                                 v   (cancellable, Unix socket)
                              ai-bridge
                                 |
                                 v        (HTTP /infill or chat)
                            llama-server :8080
                                 |
                                 v
        ghost text   ◄────   structured suggestion
        or diff      ◄────   (kind=fim | edits | none)
        overlay
```

New module `lib/ai/` with submodules:

- `Ai_client` — wraps the Unix-socket client to the AI bridge,
  request cancellation, JSON shapes. One outstanding request at a
  time per session, with explicit cancel. Knows nothing about
  llama-server, FIM tokens, prompts, or diff parsing.
- `Ai_state` — global AI on/off, last request id, status (idle /
  pending / error).
- `Ai_ghost` — per-tab ghost-text state: `{ text; accepted_prefix;
  origin_cursor; valid_until }`.
- `Ai_edits` — for shape B: a list of `{ range; replacement; status }`
  records on the tab.

Touch points in existing modules:

- `lib/keys.ml` — new bindings.
- `lib/view/` — render ghost glyphs, render diff highlights.
- `lib/tab.ml` or wherever per-tab state lives — add `ai_ghost`,
  `ai_edits`, `ai_recent_edits` fields.
- `lib/buffer.ml` — record recent edits in a small ring so shape B
  has its diff history.
- Status line in the chrome — render the indicator.

New top-level dir `ai-bridge/` (Python):

- `ai_bridge/server.py` — Unix-socket server, request dispatch.
- `ai_bridge/classify.py` — heuristic + model classifier.
- `ai_bridge/prompts/` — prompt templates per task.
- `ai_bridge/parse.py` — unified-diff / search-replace parsers,
  anchor-matching to convert text edits to buffer ranges.
- `ai_bridge/llama.py` — llama-server HTTP client.
- `tests/` — scenario-based tests of the wrapper alone.

## Process management

Two user-managed processes:

- **`llama-server`** is heavy (~6 GB VRAM resident on the 1080 Ti —
  4.4 GB for the 7B target plus ~1.2 GB for the 1.5B draft used for
  speculative decoding, plus KV cache). Long-lived. The AI bridge is
  its only client. Launch with both models:
  ```
  llama-server -m qwen2.5-coder-7b-instruct-q4_k_m.gguf \
               --spec-draft-model qwen2.5-coder-1.5b-instruct-q4_k_m.gguf \
               -ngl 99 -c 8192
  ```
  Spec decoding gives ~1.6× total / ~2.6× time-to-first speedup at
  zero quality cost — measured in Phase 0.
- **`ai-bridge`** is lightweight Python, fast to start, the rocqtui-
  facing endpoint. Consumes SSE from llama-server (streaming is
  baseline, not optional — it's the bigger latency win).

Neither is spawned by rocqtui. The expected setup: a user-systemd
unit (or equivalent) starts llama-server, another starts ai-bridge.
Rocqtui:

- Probes the bridge's Unix socket at startup. If unreachable, the
  indicator shows `!` and the feature is dormant (no requests
  issued).
- If the socket becomes reachable later, the indicator updates and
  the feature is silently enabled.
- A pair of helper scripts `scripts/llama-server.sh` and
  `scripts/ai-bridge.sh` (out of scope for this plan) can be
  provided for users who want them managed via systemd-user or
  similar.

## Phasing

### Phase 0 — viability check (done)

Built a minimal Python bridge (~120 lines, `/tmp/ai_bridge_proto.py`
plus `/tmp/ai_bridge_stream.py` for streaming) and ran it against 10
scenarios — 5 FIM and 5 edit-shape — covering uniform patterns,
semantic rewrites, mixed contexts, and one-off recent edits. All
results below from the 1080 Ti with Q4_K_M GGUFs.

#### Model comparison

| Size | Pass rate | FIM median | Edits median | Verdict |
|---|---|---|---|---|
| 1.5B | 4/10 | 608 ms | 513 ms | Garbled output, mostly rejected by anchor matching |
| 3B | 6/10 | 954 ms | 1206 ms | **Hallucinates plausible-looking edits** that pass anchor matching — silent corruption risk |
| 7B | **10/10** | **231 ms** | 2524 ms | Reliable. Counterintuitively fastest at FIM (better EOS behavior) |

**Counterintuitive finding**: smaller models are **not** faster at
FIM end-to-end. They don't emit EOS confidently and fill the
`n_predict` budget with extra tokens. The 7B knows when to stop, so
even with lower per-token throughput it finishes sooner overall.

**The 3B was the most dangerous failure mode.** On the user's
`{X Y : Set}` deletion scenario it returned plausible-looking but
wrong edits — e.g. silently swapping `fst` to `snd`, `length` to
`sum`, `+` to `*`. The anchor-matching wrapper only validates that
the SEARCH text exists; it doesn't validate the REPLACE against
the pattern. Those hallucinated edits would have shipped to
rocqtui.

**Decision: 7B for both shapes.** No model-size tiering.

#### Optimizations tested

1. **Streaming** (SSE response, parse and emit each S/R block as it
   arrives): time-to-first-change drops from 2.52 s → 1.38 s (~1.8×)
   at zero quality cost. **Baseline behavior in the bridge**, not an
   optional optimization.

2. **Compact prompt format** (ask for shortest unique anchor instead
   of full lines): **no measurable effect**. The 7B model ignored
   the instruction and emitted full lines anyway, byte-identical
   output to the verbose prompt. Skipped. (Would probably need
   few-shot examples to budge.)

3. **Speculative decoding** with 1.5B-draft / 7B-target: cumulative
   ~2.6× speedup on time-to-first (0.98 s median) and ~1.6× on total
   time (1.62 s median). **Zero quality cost**: spec decoding only
   accepts draft tokens the target would have produced anyway, so
   the 1.5B's hallucinations don't survive verification.

#### Measured baseline (post-optimization)

| Shape | Time-to-first | Total | Quality |
|---|---|---|---|
| FIM | 231 ms | 231 ms | 5/5 |
| Edits | **0.98 s** | **1.62 s** | 5/5 |

Both comfortably in the usable range. FIM is in IDE-ghost-text
territory; edits is in user-initiated-batch-refactor territory.

#### Classifier resolution

The "model classifies the kind" plan was unnecessary. A trivial
count-based heuristic in the bridge — `len(recent_edits) >= 2 →
kind=edits, else kind=fim` — got every scenario right. **No model
classification call needed.** This resolves the "biggest risk" open
question raised earlier.

#### Wrapper architecture validated

The mixed-context scenario is the clearest demonstration of why the
bridge process is the right design. On that test the 7B proposed 4
edits, 2 of which were hallucinations targeting lines that didn't
match the pattern. The bridge's anchor matching silently discarded
the 2 invalid blocks and returned only the 2 correct edits to the
caller. Without the wrapper, those would have shipped to rocqtui as
"suggested changes" and the user would learn not to trust the
feature.

#### Where the prototypes live

- `/tmp/ai_bridge_proto.py` — base bridge (classify, FIM via
  `/infill`, edits via chat with S/R block parsing + anchor match).
- `/tmp/ai_bridge_stream.py` — adds SSE streaming of edit blocks.
- `/tmp/ai_eval.py`, `/tmp/ai_eval_stream.py`,
  `/tmp/run_model_evals.sh` — scenario harness.

These are throwaway. Production code lives in `ai-bridge/` under
the repo per the architecture section.

### Phase 1 — bridge + rocqtui integration, FIM-shape only

- Bridge ships with FIM-shape support only (Phase 0 may have
  validated `edits` shape already, but rocqtui consumes only
  `fim` first).
- `Ai_client` in rocqtui talks to the bridge over Unix socket.
- Ghost rendering in the script pane (single-line first).
- Tab to accept all, Esc to dismiss, ^G to toggle.
- Status indicator showing on/off and pending/error.
- Idle trigger (300 ms default).

This is enough to be usable for definitions, types, pattern matches
— the things FIM does well per experiments.

### Phase 2 — granular acceptance + multi-line ghost

- Accept-word and accept-line keys.
- Multi-line ghost rendering (phantom rows below cursor).
- Stop-token / suffix-matching truncation on the server response
  (Qwen tends to overshoot — observed in tests).
- Configurable trigger delay and minimum context length.

### Phase 3 — edit-shape suggestions, model-classified

- Recent-edit ring buffer per tab (always populated, even before
  this phase ships — Phase 1 can ignore it).
- Switch the request to the unified schema; same trigger as Phase 1.
- Diff overlay rendering when `kind: "edits"` comes back.
- Site navigation + accept/reject keys.

No new user-facing trigger. The user notices that "sometimes the
suggestion is ghost text and sometimes it's a diff" — both came from
the same Tab-or-keep-typing flow.

### Phase 3.5 — Rocq-aware proof suggestions (optional)

The single biggest gap from experiments: vanilla FIM hallucinates
proof tactics because it has no access to the live goal state.
Rocqtui already has the Rocq STM open via the MCP bridge. A more
interesting future integration is:

- When the cursor is in proof script position (inside `Proof. ... Qed.`
  block), the prompt to the model includes the current goal text
  (queried via the existing bridge) as additional context.
- This is a separate prompt path from FIM — closer to "given this
  goal state and these previous tactics, suggest the next tactic."

Out of scope for the initial plan, but worth keeping the
`Ai_client` interface generic enough to support it later.

## Open questions

- **~~Classifier viability~~**: resolved by Phase 0 — a trivial
  count-based heuristic in the bridge gets every scenario right.
  No model classifier needed.
- **Trigger debounce default**: 300 ms is a starting guess. Should
  probably be configurable, and possibly adaptive (lower when typing
  a continuation of a partial token, higher when the model has been
  failing).
- **What counts as a "word" for accept-word?** Probably whitespace-
  delimited, but Coq identifiers contain `.` (`Nat.add`) — accepting
  one identifier at a time is more useful than splitting on `.`.
- **Cancellation semantics**: do we cancel the *server-side*
  generation when the user types (HTTP connection drop), or just
  ignore the response when it arrives? Cancellation is cleaner but
  needs server-side streaming — check llama.cpp version.
- **Persistence of toggle state**: per-session or remembered across
  rocqtui restarts? (User preference probably; default per-session.)
- **Conflict with the `^M` (minimap) binding**: ^G doesn't conflict
  but if other AI keys are added later, the leader-and-direct dual
  binding gets dense. Keep an eye on it.
