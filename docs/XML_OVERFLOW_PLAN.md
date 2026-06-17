# Plan: guard against pathological XML payloads from coqidetop

## Symptom

Stepping a tactic (`lazy.`) that makes Rocq emit an enormous goal /
feedback pretty-print wedged rocqtui: 100% CPU, single thread, RSS
climbing to **3.6 GB**, UI frozen for ~7 minutes. Alt+. (interrupt)
did nothing. It eventually recovered on its own once the parse
finished.

Captured live with `eu-stack -p <pid>` (no gdb needed): every sample
sat deep in `Xml_parser.read_node ⇄ read_elems` with the GC
(`sweep_slice`, `caml_oldify`, `bf_allocate`) thrashing underneath.

## Root cause

Two compounding problems in `lib/rocq_protocol.ml:handle_input` and the
read path (`lib/main_loop.ml:read_all`):

1. **Quadratic re-lexing (the CPU killer).** `read_all` drains whatever
   is in the pipe (bounded by the ~64 KB kernel pipe buffer) per watch
   callback. `handle_input` appends it to `t.fragment`, then builds
   `Lexing.from_string` over the *entire* accumulated fragment and tries
   to parse. An incomplete top-level message raises `Xml_parser.Error`,
   is caught, and the fragment is **retained and re-lexed from byte 0**
   on the next drain. A single N-byte message arriving in ~64 KB chunks
   is therefore lexed ~N/64KB times over a growing buffer → O(N²). At
   N≈200 MB that is hundreds of GB of lexing work — the 19 min of CPU.

2. **Unbounded memory (the RSS killer).** Once the full giant message is
   finally buffered, the one successful `Xml_parser.parse` builds a
   multi-GB OCaml value tree (3.6 GB RSS), then frees it instantly when
   consumed — hence the collapse back to 62 MB.

Note the cap is **per incomplete message**: a normal stream of many
small feedback messages never trips it, because `handle_input`'s `loop`
consumes each complete message and trims `t.fragment` past it. Only a
*single* pathologically large message grows the fragment without bound.

Interrupt was useless because the bytes were already in rocqtui's buffer;
SIGINT to coqidetop can't stop local parsing, and the synchronous
`Xml_parser.parse` call can't be interrupted without editing the vendored
parser.

## Fix

### Primary: cap the incomplete-fragment size, fail cleanly on overflow

Add a cap on the size a *single un-parsed* fragment may reach.

- Constant `max_fragment_bytes`, default **16 MB**, overridable via
  `ROCQTUI_MAX_XML_BYTES` (follow the `Sys.getenv_opt` pattern in
  `lib/log.ml` / `lib/mosh.ml`). 16 MB is orders of magnitude above any
  legitimate goal/feedback message but small enough that the bounded
  re-lex work before bailing is a few seconds, not minutes.

- In `handle_input`, after `t.fragment <- s`, before attempting the
  parse loop: if `String.length t.fragment > max_fragment_bytes`, treat
  it as a runaway response:
  - `Log.logf` it (size, in-flight call) — visible in `ROCQTUI_LOG`.
  - Fail the in-flight head call with an explanatory
    `Interface.Fail (Stateid.dummy, None, msg)` where `msg` is a `Pp.str`
    like *"Rocq response exceeded 16 MB (likely a notation/printing
    blowup); session reset."*
  - Call `mark_dead t`. The stream is desynced (the rest of the giant
    message is still arriving), so we cannot safely resume parsing — the
    safe action is to tear the protocol down. `mark_dead` already fails
    every queued caller with `died_pp`, and `session.ml` already handles
    per-call `Interface.Fail`, so this surfaces as an error the user can
    act on instead of an unrecoverable freeze.

This converts a 19-minute silent freeze into an immediate, explained
reset, and the 16 MB cap prevents the fragment from ever growing large
enough to make either the re-lex or the giant allocation expensive.

The cap **bounds** the quadratic cost (you can't accumulate past 16 MB,
so worst-case re-lex work is ~16MB × (16MB/64KB) ≈ a few GB of scans →
a few seconds, then reset) but does **not eliminate** it. A legitimately
large-but-valid message still pays the quadratic on the way to success.

### Follow-up 1 (DONE): eliminate the O(N²) re-lexing

Implemented in `lib/xml_framing.ml` (+ `.mli`, + `test/test_xml_framing.ml`).
`handle_input` no longer re-lexes the whole fragment from byte 0 on every
drain. A pure incremental boundary scanner tracks XML element-nesting
depth byte by byte across `handle_input` calls (`t.scan`), advancing only
over newly-arrived bytes; `parse_fragment` is invoked only once the
scanner reports a complete top-level element is buffered (depth back to
0). After a parse trims the fragment, the scanner is re-synced to the
remainder. Boundary detection is O(total bytes), parse is O(message)
once — the quadratic term is gone, and the cap is now a pure backstop.

The scanner is purely a performance gate: `Xml_parser` stays
authoritative on real boundaries, so a false positive only costs a
wasted parse attempt the parser rejects as incomplete. The contract is
no false *negatives* for well-formed coqidetop output — hence depth
accounting mirrors coqide's `xml_lexer.mll` exactly (content excludes raw
`<`/`>`; `<!-- -->`/`<? ?>` are depth-neutral; attribute values are
quoted with backslash escapes and may contain `>`; no CDATA/DOCTYPE).
`test_xml_framing.ml` covers split feeds, self-close, nesting, `>` inside
attribute values, escapes, comments/headers, and the resync path.

### Follow-up 2 (separate commit): make Alt+. force a reset

Even with the cap, the user should have an escape hatch. Wire the
interrupt key so that, in addition to SIGINT to coqidetop, it can force
`mark_dead` / respawn when the protocol is mid-runaway. Lower priority —
the cap already removes the unbounded case.

## Test (done)

`test/test_protocol.ml` gained an oversized-response scenario (runs under
`dune runtest`, spawns a real coqidetop). It sets a small per-session cap
via `ROCQTUI_MAX_XML_BYTES`, enters a proof with a 2000-conjunct goal,
and asserts the `goals` query fails with the reset message rather than
hanging. Note the vehicle matters: `Check`'s printed output is elided by
Rocq's default printing depth and isn't reliably transmitted, whereas a
`goals` query returns the full pretty-printed goal as its *value*, giving
a deterministic >cap single message that the in-flight call observes.

### Considered and rejected

- *Resync by drain-and-discard until the lexer realigns.* Mid-stream XML
  resync is fragile and complex; `mark_dead` is the robust sledgehammer
  for a condition that only arises from genuinely broken output.
- *Streaming/incremental parser to kill the O(N²) honestly.* Large change
  to the vendored xml-light parser; the cap makes the quadratic term
  bounded and irrelevant.

## Test

Add to the e2e suite (`test/e2e/`, run with `dune build @e2e`): feed a
synthetic oversized XML payload (or a Rocq command known to blow up
printing) and assert rocqtui returns a Fail/reset promptly rather than
hanging. Keep a unit-level check that a normal large *stream* of small
messages still parses fully (cap is per-message, not cumulative).
