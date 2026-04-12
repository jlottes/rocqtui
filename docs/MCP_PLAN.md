# MCP Proving Workflow — Implementation Plan

Implements the design in `MCP_PROVE_DESIGN.md`: replace the Python bridge
with an OCaml bridge exposing high-level proving tools over a minimal
low-level API.

## Phase 1: Shared library code

New modules in `lib/` used by both rocqtui and the bridge.

### 1a. `lib/text_match.ml` — whitespace-normalized text matching

- `normalize : string -> string` — collapse whitespace runs to single space
- `find_all : haystack:string -> needle:string -> int list` — find all
  match positions (byte offsets in original haystack)
- `find_unique : haystack:string -> needle:string -> ?after_text:string ->
  ?line:int -> (int, error) result` — find exactly one match; error
  returns all match line numbers
- `line_of_offset : string -> int -> int` — byte offset to 1-based line
- `tail_matches : text:string -> tail_end:int -> pattern:string -> int option`
  — check if `pattern` matches the text ending at `tail_end`; returns
  start offset of match, or None

### 1b. `lib/context.ml` — sentence-aligned context extraction

- `before : string -> boundary:int -> ?min_bytes:int -> ?proof_start:int
  -> string` — extract complete sentences before boundary
- `after : string -> boundary:int -> ?max_bytes:int -> string` — extract
  complete sentences after boundary
- `find_proof_start : string -> boundary:int -> int option` — scan backward
  for proof-introducing command (Lemma, Theorem, etc.)
- Uses `Sentence.split` / `Sentence.find_end` for boundary detection

### 1c. `lib/mcp_json.ml` — JSON-RPC helpers

- JSON-RPC 2.0 message parsing/construction (extract from `mcp_server.ml`)
- Shared between server and bridge
- Request/response/notification types
- Error codes

## Phase 2: Refactor `mcp_server.ml` — minimal low-level API

Simplify the server to the primitives the bridge needs.

### 2a. Add `get_state` resource

- New resource `rocqtui://state` (or `rocqtui://state?tab=N`)
- Returns batched JSON: buffer, verified_end, target_end, is_busy, goals,
  messages, error, sentences, locked
- Single round-trip for all state the bridge needs

### 2b. Add `lock` / `unlock` tools

- Per-tab, per-client locking
- `mcp_server.ml`: track `locked_by: client option` per tab
- `editor.ml`: check lock before buffer mutations, ignore locked keystrokes
- Status bar: show lock indicator + spinner when locked
- Auto-unlock on client disconnect (in `handle_ready` when client is removed)

### 2c. Add `build_deps` tool

- Expose `Build.build_deps` through MCP
- Non-blocking on rocqtui side (build is already async)
- Bridge polls build status via `get_state` or a build-specific field

### 2d. Prune unnecessary tools

- Remove from exposed API (or mark internal): `step_forward`,
  `step_backward`, `go_to_end`, `replace_text`, `replace_range`,
  `batch_edit`, `move_cursor`, `offset_of_line`, `get_context`,
  `get_position`, `get_goals`, `undo`, `redo`, `switch_tab`
- Keep: `go_to_offset`, `insert_text`, `delete_range`, `query`, `save`,
  `open_file`, `is_busy` (still useful as a quick check), `interrupt`,
  `lock`, `unlock`, `build_deps`
- Remove old resources subsumed by `get_state`: `goals`, `messages`,
  `error`, `regions`, `sentences`, `cursor`, `line_offsets`
- Keep: `buffer`, `tabs`, `state` (new)

### 2e. Display options plumbing

- Add `options` parameter to `get_state` resource (or to `query` /
  `go_to_offset` tools) so display options affect goal/message formatting
- Reuse existing `Printopts` module

## Phase 3: OCaml bridge binary

### 3a. Skeleton: `bin/rocqtui_mcp.ml`

- Dune executable linking `lib/`
- Socket discovery (walk up for `.rocqtui-mcp.sock`, same as Python bridge)
- Socket connection + line-buffered JSON-RPC over socket
- Stdin/stdout JSON-RPC loop (MCP protocol)
- MCP initialization handshake (`initialize` / `initialized`)
- Tool list + resource list registration

### 3b. Low-level socket client

- `send_tool_call : socket -> name:string -> args:json -> json` —
  send JSON-RPC request, read response (blocking)
- `read_resource : socket -> uri:string -> json` — read resource
- `poll_until_idle : socket -> ?timeout:float -> ?tab:int -> state` —
  poll `get_state` until `is_busy` = false, return final state.
  `is_busy` is false only when `verified_end = target_end` AND no
  in-flight Rocq calls AND no pending rewinds/goal refreshes. This
  guarantees the verified region has fully caught up to the target
  (or an error has snapped the target back to verified_end).
- Error handling: socket errors, timeouts, malformed responses

### 3c. Common response builder

- `build_response : state -> json` — compute the common response fields
  (verified_end_line, last_sentence, goals, context_before, context_after,
  messages) from a `get_state` result
- Uses `Context.before`, `Context.after`, `Context.find_proof_start`
- Uses `Text_match.line_of_offset`

## Phase 4: High-level tool implementations

Each tool follows the pattern: lock → operate → poll → inspect → cleanup
→ unlock → respond.

### 4a. `proof_status` resource

- Read `get_state` from rocqtui
- Compute context (using `Context` module)
- Return formatted response
- No locking needed (read-only)

### 4b. `verify_to`

- Lock tab
- If no args: `go_to_offset(0)` (beginning)
- If `before_text`: use `Text_match.find_unique` on buffer to find offset,
  snap to sentence boundary
- If `line` only: compute offset from buffer
- `go_to_offset` with resolved offset
- `poll_until_idle`
- Build response (may include error if verification failed en route)
- Unlock

### 4c. `proof_insert`

- Lock tab
- Read `get_state` for current verified_end and buffer
- Validate: `Sentence.split` on input text, reject if incomplete
- Ensure separation: check char before verified_end, prepend space if needed
- `insert_text` at verified_end
- `go_to_offset` to end of inserted text
- `poll_until_idle`
- Read `get_state`, inspect sentences for errors
- If partial/total failure: compute what to delete, `delete_range`
- Build response
- Unlock

### 4d. `proof_forward`

- Lock tab
- Read `get_state` for buffer text after verified_end
- `Text_match.normalize` and compare with `sentences` param
- If mismatch: error with actual buffer content
- `go_to_offset` to end of matched region
- `poll_until_idle`
- Read `get_state`, check for errors (don't delete on failure)
- Build response
- Unlock

### 4e. `proof_rewind`

- Lock tab
- Read `get_state` for buffer text and sentence list
- `Text_match.tail_matches` against verified region tail
- If mismatch: error with actual tail
- `go_to_offset` to before matched region
- `poll_until_idle`
- If `delete`: `delete_range` on the matched region
- Build response
- Unlock

### 4f. `query`

- Read `get_state` for current state
- Set display options if provided
- `query` tool call
- Read `get_state` for messages
- Build response (messages field has query result)

### 4g. `save`, `open_file`, `build_deps`

- Thin wrappers: forward to low-level tools
- `build_deps`: lock, start build, poll build status until finished,
  unlock, return output

## Phase 5: Integration + cleanup

### 5a. Delete Python bridge

- Remove `scripts/rocqtui-mcp-bridge`
- Update `scripts/` and any references

### 5b. Update `.mcp.json` configuration

- Point to new OCaml binary:
  ```json
  { "mcpServers": { "rocqtui": {
      "command": "/home/jlottes/rocq/rocqtui/_build/default/bin/rocqtui_mcp.exe"
  } } }
  ```

### 5c. Update documentation

- Update `CLAUDE_MCP.md` with new API reference
- Update `CLAUDE.md` MCP section
- `MCP_PROVE_DESIGN.md` can stay as design rationale

### 5d. Testing

- Unit tests for `Text_match` (normalization, find_unique, tail_matches)
- Unit tests for `Context` (sentence-aligned extraction, proof_start detection)
- Manual end-to-end: connect Claude Code to new bridge, prove a theorem
- Verify lock/unlock works (edit rejection, auto-unlock on disconnect)
- Verify build_deps workflow (build → rewind to beginning → re-verify)

## Dependency graph

```
Phase 1 (lib/ modules)
  ├── 1a text_match
  ├── 1b context (depends on Sentence)
  └── 1c mcp_json
        │
Phase 2 (mcp_server refactor)        Phase 3a-b (bridge skeleton)
  ├── 2a get_state                      ├── 3a skeleton
  ├── 2b lock/unlock                    ├── 3b socket client
  ├── 2c build_deps                     └── 3c response builder
  ├── 2d prune tools                          │
  └── 2e display options                      │
        │                                     │
        └──────────┬──────────────────────────┘
                   │
             Phase 4 (high-level tools)
               ├── 4a proof_status
               ├── 4b verify_to
               ├── 4c proof_insert
               ├── 4d proof_forward
               ├── 4e proof_rewind
               ├── 4f query
               └── 4g save, open_file, build_deps
                   │
             Phase 5 (integration)
               ├── 5a delete python bridge
               ├── 5b update config
               ├── 5c update docs
               └── 5d testing
```

Phases 2 and 3 can be done in parallel. Phase 4 depends on both.
Within Phase 4, tools can be implemented incrementally (start with
`proof_status` + `verify_to` + `proof_insert` as the core loop).
