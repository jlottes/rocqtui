# Input parser: push-based inversion + kitty-correct key forwarding

Plan doc. Three related changes, one theme: **terminal I/O should respect
the negotiated protocol across arbitrary byte boundaries, with no
timeout-driven parsing and no hardcoded special-case encodings.**

Motivation came from two field bugs:

1. **Paste corruption over iTerm2 (network transport).** Large pastes
   start fine, then auto-indentation kicks in partway through. Local
   glterm never reproduces it.
2. **tterm forwards `^\` (and other ctrl/alt combos, and ESC) in legacy
   encoding even when the embedded app enabled the kitty keyboard
   protocol.** iTerm2 sends `CSI 92;5u`; tterm sends `0x1c`.

Both are the same root disease seen from two sides: our input path uses
short per-byte read timeouts to assemble escape sequences (breaks under
network chunking), and our key-*forwarding* path hand-encodes legacy
bytes instead of running keys through the protocol-aware encoder.

---

## Part 1 — Pull → push input parser

### Current design (the problem)

`lib/input.ml` is a *pull* parser: `read_event ?timeout fd` reads one
byte at a time via `read_byte fd timeout` and assembles a complete event
before returning. To disambiguate a lone `ESC` keypress from the start
of an escape sequence, and to read the bytes *within* a CSI/paste
sequence, it uses fixed 25–50 ms `select` timeouts (`read_byte fd
0.05`).

That works when bytes arrive in one contiguous burst (local glterm). It
fails over a network link (laptop iTerm2 → host) where TCP delivers the
stream in chunks with inter-segment gaps:

- A gap landing inside a `ESC[200~` / `ESC[201~` bracketed-paste marker
  exceeds the 50 ms window → the marker is misparsed → bracketed-paste
  framing is lost → the remainder of the paste flows in as ordinary
  keystrokes, and each `\n` hits `Buffer.insert_newline_auto_indent`
  (`lib/buffer.ml:414`). That is the "auto-indent partway through" bug.
- Same hazard for any multi-byte sequence (CSI params, UTF-8
  continuation bytes) split across a gap.

Call sites (all the identical `drain()` shape):
- `bin/main.ml:624` — main loop input drain
- `bin/tterm.ml:537` — tterm input drain
- `bin/main.ml:190` — Rocq interrupt hook, a `timeout:0.0` peek for `^C`

A second, dead copy of the parser exists at `lib/keys.ml:567–650`
(`read_key_event`); `Input.read_event` is the live one. Delete the dead
copy as part of this work.

### Target design

A persistent state machine you *push* bytes into — the same shape as the
embedded terminal's `Vterm_api.proc` / `sync` (`lib/vterm/vterm_api.mli:52`).
It handles arbitrary breaks in the byte stream, including mid-UTF-8 and
mid-escape-sequence, by keeping state across `feed` calls. (OCaml 4.14 —
no effect handlers — so this is the explicit inversion, which is also the
idiom we already trust for vterm.)

New interface (replaces `read_event`):

```ocaml
type t
val create     : unit -> t
val feed        : t -> bytes -> off:int -> len:int -> unit  (* push raw bytes, enqueue events *)
val next_event  : t -> event option                          (* drain queue *)
val pending     : t -> bool          (* true iff mid-sequence (e.g. a lone ESC awaiting resolution) *)
val flush       : t -> unit          (* resolve a pending lone ESC as Escape; idempotent *)
```

State enum (internal):

```
Ground
| Esc                       (* saw ESC, awaiting next byte or flush *)
| Csi  of { priv; params }  (* ESC [ … ; private-prefix byte tracked for kitty/SGR *)
| Ss3                       (* ESC O *)
| Utf8 of { acc; need }     (* continuation bytes pending *)
| Paste_body                (* inside ESC[200~ … *)
| Paste_esc                 (* saw ESC inside paste body — maybe ESC[201~ *)
| Paste_esc_csi of buf      (* accumulating the 201~ candidate *)
```

The decode *knowledge* — the `match final with 'A' -> Up | …` block,
mouse decoding, CSI-u/kitty keycode mapping — transfers almost verbatim
from today's `parse_csi`. What changes is control flow: every
`read_byte fd 0.05` becomes "stay in this state until the next byte
arrives in some later `feed`." A split mid-sequence is now structurally
impossible to misparse.

### The one timing decision: lone ESC

The 25/50 ms timeout was only ever legitimate for the *first* byte after
a bare `ESC` (Escape keypress vs. start of a sequence). Once `ESC [` is
seen, the remaining bytes are machine-emitted and must be read without a
timeout. So:

- The parser never blocks. In `Esc` state it emits nothing.
- Resolution is driven by the **event loop**, which already has a
  `select` timeout:
  - bytes arrive → state advances (`[` → Csi, `O` → Ss3, printable →
    `Alt+key`, etc.).
  - `select` times out while `pending t` → loop calls `flush t`, which
    emits `Escape`.
- Integration: when `pending t`, cap the loop's `select` timeout at
  ~50 ms so a lone ESC resolves with the same feel as today. Otherwise
  the loop keeps its normal cadence.

Note: when the kitty keyboard protocol is honored by the outer terminal
(we send `ESC[>1u` in `lib/term.ml:38`), ESC arrives as `CSI 27 u` and
the ambiguity vanishes — `flush` simply never fires. We still implement
`flush` because (a) iTerm2 only honors the push when its "Apps can change
how keys are reported" setting is on, and (b) kitty mode often doesn't
survive ssh/tmux/mosh. Field finding: the user's iTerm2 sends a clean
`CSI 27 u` for ESC; the bare-`1b` fallback is what we must still handle
for terminals that ignore the push.

### Call-site changes

`drain()` becomes:

```ocaml
if List.mem stdin_fd ready then begin
  let n = Unix.read stdin_fd readbuf 0 bufsize in
  Input.feed parser readbuf ~off:0 ~len:n;
  let rec drain () = match Input.next_event parser with
    | Some ev -> handle ev; drain ()
    | None -> () in
  drain ()
end;
(* elsewhere, on select timeout: *)
if Input.pending parser then Input.flush parser   (* then drain again *)
```

The interrupt hook (`bin/main.ml:190`) is the only non-uniform site.
Today it pulls one event and acts only if it is `^C`, **dropping any
other event** (`| _ -> ()` at `:195`). New behavior: read available
bytes non-blocking, `feed` them, then scan the queue **non-destructively**
for `^C` (send `SIGINT` if present) and leave everything queued for the
main loop. This also fixes the latent event-drop bug.

`parser` (an `Input.t`) is created once and shared — it must be the same
instance across the main drain and the interrupt hook so no bytes/state
are lost between them.

---

## Part 2 — kitty-correct key forwarding to embedded terminals

### The bug

When an app inside tterm enables kitty disambiguate mode, ctrl/alt
combos and ESC are still forwarded as legacy bytes. Per the kitty spec,
disambiguate (flag `0b1`) reports **Esc, alt+key, ctrl+key,
ctrl+alt+key, shift+alt+key** as `CSI u` (except Enter/Tab/Backspace,
which stay legacy); plain text, plain arrows, and plain function keys
stay legacy. So `^\` must be `CSI 92;5u`, not `0x1c`.

The vterm C layer is correct: `cf_kitty_kb_push/_set/_pop/_query`
(`lib/vterm/term.c:2007–2039`) track the flags, and
`Vterm_api.kitty_keyseq` encapsulates the disambiguate rules. The defect
is in `lib/editor/pty.ml:forward_event`, which short-circuits exactly the
combos disambiguate escalates, *before* reaching the kitty encoder:

```
:99   Key cp<32 && ctrl       -> raw control byte          (BYPASS)
:102  Key ctrl && cp 64..127  -> cp land 0x1f  (^\ -> 0x1c) (BYPASS)
:110  Key alt && not ctrl     -> ESC-prefix               (BYPASS)
:112  Key (cp, mods)          -> send_key   (kitty-aware)
:114  Special (key, mods)     -> send_key   (kitty-aware)
```

Only the last two consult `kitty_flags`. ESC is additionally intercepted
for compose: `lib/terminal_input.ml:44` swallows `Special(Escape,_)`
(returns `Continue`), and the only emit path is the hardcoded `"\x1b"`
at `bin/tterm.ml:584` (compose NoMatch under `--xcompose`).

Consequence: with the bypass in place, *no* forwarded key reveals
whether the inner app's push was honored — plain keys/arrows look
identical either way, ctrl/alt are bypassed, ESC is intercepted. The
push reaching the vterm is moot until the bypass is removed.

### The fix

Route **all** keys through `send_key` and let `kitty_keyseq` (when
`kitty_flags > 0`) / legacy `keyseq` (when `0`) choose the encoding —
exactly as `send_escape` (`pty.ml:18`) already does for ESC. Remove the
pre-emptive legacy short-circuits at `pty.ml:99–111`; legacy stays the
internal fallback that `send_key` already provides.

ESC forwarding must stop hardcoding `"\x1b"`:
- `terminal_input.ml` ESC handling and the `tterm.ml:584` compose path
  should forward the **encoded** ESC for the active terminal (via
  `forward_event` / `Pty.send_escape`, which consult `kitty_flags`),
  not a literal byte.
- Keep compose semantics intact: under `--xcompose`, double-ESC still
  means "send ESC to the terminal" — but the byte(s) sent must be the
  protocol-correct encoding (`CSI 27 u` when the app asked for it).

### Legacy parity — must verify, don't regress

Before deleting the short-circuits, confirm `keyseq` (the `kitty_fl == 0`
path) reproduces today's exact bytes for non-kitty terminals:
- ctrl+letter → the control byte (`Ctrl+A` → `0x01`, `^\` → `0x1c`).
- alt+key → `ESC`-prefixed (`Alt+a` → `ESC a`).
- ctrl+alt+letter → `ESC` + control byte.
If `keyseq` doesn't cover a case, the fallback in `send_key`
(`pty.ml:79–92`) must — extend it rather than re-introduce a bypass.

---

## Part 3 — Tests

Unit tests for the push parser (`test/`, fast — no subprocess):
- Feed a bracketed paste **split across `feed` boundaries** mid-marker
  (`ESC[20` | `0~payload ESC[2` | `01~`) → exactly one `Paste` event
  with the correct payload; no stray `Enter`/`Key` events.
- Feed a UTF-8 codepoint split across `feed` boundaries → one `Key`.
- Feed `ESC` alone then `flush` → `Escape`. Feed `ESC` then `[A` in
  separate `feed`s (no flush between) → `Up`, never `Escape`.
- Feed `ESC[27u` → `Escape` (kitty path); `ESC[92;5u` → `Ctrl+\`.
- Mouse SGR and kitty-u keys split across boundaries.

Forwarding (can reuse `tools/keyspy.ml` manually inside tterm, and add a
focused unit test if `forward_event` can be exercised without a live
pty): with `kitty_flags = 1`, `^\` → `CSI 92;5u`, `Ctrl+A` → `CSI 97;5u`,
ESC → `CSI 27 u`; with `kitty_flags = 0`, the legacy bytes above.

`tools/keyspy.ml` already recognizes both encodings of `^\` for quit
(legacy `0x1c` and kitty `CSI 92;<mods>u`).

---

## Sequencing

1. Land the push parser + `flush` integration + interrupt-hook rewrite;
   delete the dead `keys.ml` parser. (Fixes the paste bug.)
2. Add parser unit tests.
3. Rewrite `forward_event` to route everything through `send_key`;
   de-hardcode ESC in the compose paths. (Fixes the kitty-forwarding
   bug.) Verify legacy parity first.
4. `dune build @e2e` (touches input/terminal paths); manual keyspy
   sweep in iTerm2 and inside tterm.

## Open questions

- Does the main loop's existing `select` cadence already wake often
  enough that capping at 50 ms when `pending` is a no-op in practice?
  Confirm the lone-ESC latency feels unchanged.
- `read` chunk size for `feed`: a single `Unix.read` into a reused
  buffer is fine; pick a size (e.g. 4096) that comfortably holds a
  pasted chunk without multiple syscalls in the common case.
