# RegionBuffer — implementation plan

## Goals

Centralize text mutation behind a single module that enforces the
invariants in [`REGION_INVARIANTS.md`](REGION_INVARIANTS.md). The
invariants are currently honored most of the time but rarely violated,
likely because edits arrive on multiple paths (script-pane keys, MCP
server, clipboard paste, file reload, undo/redo) and each path is
individually responsible for consulting `Editor.Block` before mutating.
Replace that "ask before you mutate" discipline with an "only one writer
exists" structure.

## Non-goals

- Not refactoring `Session` ownership. `Session` keeps the sentence
  stack, state IDs, Rocq protocol connection, and rewinding logic.
- Not changing the cursor/selection model. Cursor and selection live in
  `Buffer` and remain freely mutable from anywhere — they are display
  state, not committed text.
- Not introducing rewind-on-edit. Edits that would violate verified-
  region invariants are *rejected*; the user explicitly steps back to
  edit verified text.

## Module shape

`lib/region_buffer.ml(i)`. Three peers held by `Tab`: `Buffer`,
`Session`, `RegionBuffer`. `RegionBuffer` is the only writer of the
`Buffer`'s text content.

```ocaml
(** RegionBuffer: text mutation gateway that enforces region invariants.

    Holds a [Buffer.t] and reads boundary positions from a [Session.t].
    All text-mutating editor paths must go through this module. *)

type t

type reject_reason =
  | In_verified_region        (* edit overlaps [0, verified_end) *)
  | Erodes_boundary           (* edit would un-terminate the boundary "." *)
  | In_pending_region         (* edit overlaps [verified_end, target_end) *)
  | Locked                    (* MCP lock, etc. *)

type result = Applied | Rejected of reject_reason

val create : Buffer.t -> session:Session.t option -> t
val buffer : t -> Buffer.t   (* read-only-by-convention escape hatch *)

(* Atomic edits. Each one validates against invariants, then applies
   (or rejects). On Applied, performs reactive bookkeeping
   (error-region clearing, target shifting/clearing). *)
val try_insert  : t -> at:int -> string -> result
val try_delete  : t -> start:int -> len:int -> result
val try_replace : t -> start:int -> len:int -> string -> result

(* Cursor-relative wrappers (today's editor uses these shapes). *)
val try_insert_char     : t -> char -> result
val try_insert_newline  : t -> result
val try_delete_char_at  : t -> result
val try_delete_char_before : t -> result
val try_paste           : t -> string -> result
val try_cut_line        : t -> result
val try_indent_lines    : t -> int -> result
val try_unindent_lines  : t -> int -> result

(* Wholesale text replacement. Semantically a single try_replace of
   the whole buffer, subject to the same invariants. If the new text
   agrees with the verified prefix and preserves the boundary, the
   session is left intact; otherwise rejected. *)
val try_load_text : t -> string -> result
val try_reload_from_disk : t -> result

(* Undo/redo: an undo can move the verified-region cursor backward
   in time, so it must consult the session and reject if the resulting
   text would violate invariants. *)
val try_undo : t -> result
val try_redo : t -> result

(* Locking (MCP lease etc.). *)
val lock   : t -> unit
val unlock : t -> unit
val locked : t -> bool
```

## Key checks

### Boundary-fusion (verified-region invariant 2)

Already settled in conversation. The check is a one-byte predicate on
post-edit text:

```ocaml
let preserves_boundary ~post_edit_text ~verified_end:n =
  n >= String.length post_edit_text
  || Sentence.is_space post_edit_text.[n]
```

This covers every terminator shape (`.`, `...`, bullet run, `{`, `}`)
because they all share the same trailing-whitespace-or-EOF rule.
Requires only `Sentence.is_space` (already exposed).

### Verified-region overlap (invariant 1)

`try_insert at:n` overlaps when `n < verified_end`. `try_delete
~start ~len` overlaps when `start < verified_end`. `try_replace`
combines both.

For wholesale replacement (`try_load_text`, `try_reload_from_disk`),
the check is: `new_text` and the current text agree on the byte range
`[0, verified_end)`. This subsumes both the overlap check and the
boundary-fusion check uniformly — if the verified prefix is
byte-identical and `at_space_or_eof new_text verified_end` holds, the
session can be preserved. This generalizes today's `diff_at < vend`
logic in `file_manager.ml` and fixes a latent bug there: the current
check considers only `diff_at < vend`, not `diff_at == vend` with a
non-whitespace byte appearing at the boundary, which would erode it.

### Pending-region overlap

Today's `Editor.Block` blocks edits with cursor `< pending_end`. Keep
that policy: any edit that touches `[verified_end, pending_end)` is
`Rejected In_pending_region`.

## Reactive bookkeeping (on `Applied`)

- **Error region.** If the edit's affected range overlaps
  `Session.error_range`, call `Session.clear_error`.
- **Target.** If the edit is an insertion before the target, shift
  the target forward by the inserted length. If the edit is a deletion
  before the target, shift backward. If the edit *touches* the target's
  anchor character, clear the target. (Under today's pending-region
  policy this is unreachable — the pending check fires first — but
  encoding it makes the invariant real if policy changes.)

`Session` exposes the small setter surface needed: `clear_error`,
`shift_target ~by`, `clear_target`. The gateway never reaches into
`Session`'s internals.

## Migration sequence

1. **Add `RegionBuffer` alongside the existing `Editor.Block`.**
   Implement the API. Keep `Editor.Block` working. Don't migrate any
   callers yet.
2. **Wire `RegionBuffer` into `Tab.t`.** Construct it in `Tab.create`
   from the existing `Buffer.t` and `Session.t option`. Both
   `tab.buf` and `tab.region_buffer` coexist during migration.
3. **Migrate call sites in waves**, in roughly this order (smallest
   blast radius first):
   - `lib/editor/script.ml` — keypress-driven edits. The bulk of
     normal edits.
   - `lib/file_manager.ml` — file reload. Replace the bespoke
     `diff_at < vend` logic with `try_reload_from_disk`. The auto-
     reload path stays: if invariants hold, the gateway returns
     `Applied` and the session is preserved (today's common case);
     otherwise `Rejected` and `file_manager` surfaces
     `VerifiedAffected` as it does today. Bonus: this fixes the
     boundary-erosion edge case in the existing check.
   - `lib/mcp_server.ml` — every `insert_*`/`delete_*` path. Many
     sites. Each currently checks locks ad-hoc; the gateway absorbs
     that. Where this changes externally observable behavior (new
     rejection reasons, preserved-session semantics for whole-buffer
     replace), update in lockstep:
     - `bridge/rocqtui_mcp.ml` — the in-tree MCP bridge that
       orchestrates low-level tools into high-level ones
       (`proof_insert`, `proof_verify`, `proof_rewind`, etc.). Its
       error-handling and state-inspection assumptions need to match
       the new server contract; today it treats all tool errors as
       opaque strings.
     - `CLAUDE_MCP.md` — imported by downstream projects bridging to
       rocqtui's MCP server. This file is the public contract.
   - `lib/tab.ml` — initial file load.
4. **Hide `Buffer`'s text-mutating API.** Once all call sites route
   through `RegionBuffer`, move `Buffer.insert_*`,
   `Buffer.delete_*`, `Buffer.paste`, `Buffer.cut_line`,
   `Buffer.indent_lines`, `Buffer.unindent_lines`, `Buffer.undo`,
   `Buffer.redo`, `Buffer.load_file`, `Buffer.reload` out of
   `Buffer.mli`. Expose them only to `RegionBuffer` (via a private
   `lib/buffer_internal.ml` or by friend-style packaging).
5. **Remove `Editor.Block`.** Its predicate role is subsumed by
   `RegionBuffer`'s rejection results.

Each wave is independently shippable. Steps 1–3 are additive; steps
4–5 are the cleanup that locks in the invariant.

## Call-site audit checklist

Mutating sites discovered today (40 total). To migrate:

- `lib/editor/script.ml` — ~20 sites: insert_char, insert_newline,
  delete_selection, cut_line, paste, delete_char_at,
  delete_char_before, insert_newline_auto_indent, indent/unindent,
  unicode codepoint insert.
- `lib/mcp_server.ml` — ~20 sites: `insert`, `delete_range`,
  `replace_range`, `set_text` style operations, plus `undo`/`redo`.
- `lib/file_manager.ml` — `Buffer.reload` (1 site). Consolidate the
  `diff_at < vend` reasoning into `RegionBuffer.reload_from_disk`.
- `lib/tab.ml` — `Buffer.load_file` (1 site, initial open).
- `lib/session.ml` — `Buffer.move_to_byte_offset` only (cursor, not
  text); no migration needed.

`Buffer.move_*`, `set_anchor`, `clear_selection`, `move_to_byte_offset`
do not mutate text and stay public.

## Open questions

1. **Undo granularity.** `Buffer.undo` may step back through several
   character-level operations. Does each underlying step get
   re-validated, or do we validate the cumulative diff? Cumulative is
   simpler and correct — implement that.
2. **Selection-replace as atomic edit.** The common pattern
   `delete_selection; insert_text` is two mutations today. Bundle as
   `try_replace` so the gateway sees one atomic edit, otherwise
   intermediate states could trip a check.
3. **MCP `set_text` (whole-buffer replace).** Routes through
   `try_load_text`. If the new text preserves the verified prefix
   and boundary, the session is kept; otherwise rejected with
   `In_verified_region`. The MCP caller can react to rejection by
   explicitly rewinding and retrying.
4. **Where the lock lives.** Today `tab.locked` is a bool on `Tab`.
   Move to `RegionBuffer` so the lock check is part of the same
   gateway, or keep on `Tab` and have the gateway read it. Probably
   move it.

## Risks

- **Migration breakage.** 40 call sites is enough that a wave can
  miss one. Mitigation: after each wave, grep for residual
  `Buffer.insert_*` / `Buffer.delete_*` outside `region_buffer.ml`
  and fix.
- **Selection-replace atomicity.** If we naively migrate
  `delete_selection; insert` as two `try_*` calls, the gateway may
  reject the second after the first applied — leaving a partial edit.
  Must convert to `try_replace` during migration, not after.
- **Hidden mutators.** `Buffer.cut_line` mutates a cut-buffer side-
  channel; `Buffer.paste` reads from it. The gateway must keep that
  pairing intact. Audit `Buffer.ml` for any other implicit state
  during step 4.
- **MCP contract drift.** Three files move together: `mcp_server.ml`
  emits the new error shapes, `bridge/rocqtui_mcp.ml` consumes them
  (and may want to take advantage of new behaviors like preserved-
  session whole-buffer replace), and `CLAUDE_MCP.md` documents the
  contract for downstream consumers. Likely additions: a unified
  `rejection_reason` enum (`in_verified_region`, `erodes_boundary`,
  `in_pending_region`, `locked`) replacing today's ad-hoc strings,
  and explicit documentation that `set_text`-style operations may
  succeed without rewinding when the verified prefix is preserved.
  Without lockstep updates, `proof_insert` / `proof_verify` will
  silently misclassify rejections.
