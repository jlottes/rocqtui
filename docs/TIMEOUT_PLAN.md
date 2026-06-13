# Bridge verification timeouts

Problem: `poll_until_idle` gives up silently after 60s. A diverging
tactic leaves the response success-shaped (`error: null`, boundary
short of target), no interrupt is sent, and `proof_insert`'s cleanup
delete gets rejected (`in_pending_region`) because the inserted text
is still pending.

## Design

- Verifying tools (`verify_to`, `proof_insert`, `proof_forward`) take
  an optional `timeout` argument (seconds). Default 60, clamped to
  [1, 600] — no infinite waits.
- On timeout the bridge **auto-interrupts** (the server's `interrupt`
  tool, addressed to the tab), then waits for the session to settle
  (fixed 30s grace). The session's normal interrupt path errors the
  in-flight sentence ("User interrupt.") and retracts the boundary to
  the last verified sentence.
- `proof_insert` keeps its invariant — *only verified text stays in
  the buffer*. After the interrupt settles, the pending region is
  clear, so the existing cleanup delete of the unverified tail
  proceeds. If the session is somehow still busy after the grace
  period, raise an explicit error rather than a confusing
  `in_pending_region` rejection.
- Responses from the three verifying tools gain:
  - `timed_out` (bool) — unmistakable timeout signal; `error` is
    always non-null when set (falls back to a synthesized message if
    the session reports none).
  - `elapsed_seconds` (number, 0.1s resolution) — also on successful
    calls, so slow-but-finishing steps are visible.
- Non-verifying tools (`proof_rewind`, `replace_after`, `query`) are
  unchanged: rewind is an `edit_at` (fast), `replace_after` is a pure
  buffer edit, and `query` already reports timeouts via its `error`
  field.

## Test

New e2e test using the `Ltac loop := idtac; loop.` fixture from
`test_interrupt_recovery.ml`:
1. `proof_forward` through `loop.` with `timeout: 2` → `timed_out:
   true`, non-null `error`, boundary stopped at `Proof.`, session
   usable afterwards (query succeeds).
2. `proof_insert` of a hanging tactic with `timeout: 2` → `timed_out:
   true` and the buffer is byte-identical to before the call.
