# MCP feedback tracker

Status of every entry from the `mcp-feedback.md` files that consumer
projects maintain (see "MCP integration" in `CLAUDE.md`). One row per
feedback item; an entry raising several independent issues gets a row
each.

**Checking for new feedback:** anything in a source file dated after
its "triaged through" date below is new. Source entries are dated
`## YYYY-MM-DD` headings, so `grep '^## ' <file>` lists them.

## Sources

| Project | File | Triaged through |
|---------|------|-----------------|
| affine | `~/rocq/affine/mcp-feedback.md` | 2026-06-12 |

## Items

Statuses: **open** (not yet addressed), **fixed** (behavior changed),
**docs** (behavior kept, documented), **WAI** (working as intended,
nothing to document), **wontfix**.

| Date | Source | Item | Status | Resolution |
|------|--------|------|--------|------------|
| 2026-03-28 | affine | Byte-offset editing (`replace_range` etc.) error-prone; wants text-based search-and-replace | fixed | `a7510ee` added `replace_text`; high-level bridge tools (`31157ec`) made raw offsets rarely needed |
| 2026-03-28 | affine | No visibility into which sentence `step_forward` will execute | fixed | `a7510ee`: step responses include `Executed:` and `Next:` sentence previews |
| 2026-03-28 | affine | Hard to confirm an edit landed without re-reading the whole buffer | fixed | `a7510ee`: edit tools return a context snippet around the edit point |
| 2026-06-09 | affine | Query timeout indistinguishable from empty output; stale boundary messages returned as query results | fixed | `2876a71`: explicit `error` field on query responses; messages are query output only, never the session buffer |
| 2026-06-09 | affine | Vernac state (`Set ...`) doesn't carry between sentences within one query | docs | `83d9135`: snapshot semantics + workarounds documented in CLAUDE_MCP.md and the tool description (Stm.query purifies state per sentence) |
| 2026-06-12 | affine | Backward `verify_to`/`proof_rewind` silently no-op on a non-active tab, success-shaped responses with stale `proof_status`; `delete: false` seemed to drop text | fixed | `e48fef5`: bridge now passes `tab` to inner mutating calls (root cause of all three symptoms); unknown tab id is an explicit error; e2e regression test |
