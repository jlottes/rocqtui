# Render Cell Model Alignment

Align rocqtui's `Grid` cell model with glterm's display-cell model
(see `~/glterm-1/doc/cluster-cell-plan.md`) so that:

1. the embedded terminal is a functionally transparent pass-through —
   what a child app draws into vterm re-renders identically when the
   grid's emitted bytes hit the outer glterm; and
2. the editor's own content (script pane, panels, status bar) lays out
   with the same width rules glterm uses to render it.

## Where we already are

Per-follower SGR pass-through works today (`ed08db2` + `aadb219`):
vterm keeps each zero-width follower as its own cell with its own SGR,
`get_row` surfaces them individually, `terminal.ml` routes them to
`Grid.append_combining ~attr`, and `emit_cell_payload` replays each
comb under its own SGR transition. Cluster cells are expanded to their
full UTF-8 sequence by `get_row` (`c7af7c5`) and the outer glterm
re-clusters them to the same width.

Two gaps remain.

**Gap 1 — the text-fold erases the leader/follower boundary.**
`append_combining` folds a same-attr mark into `cell.text`
(`grid.ml:206`). Bytes come out identical, but the grid forgets where
the leader ends. Failure case: a child emits `✔ <SGR command that
changes nothing> VS-16`. Inner vterm breaks clustering on any SGR
command (matching kitty/xterm), storing leader + degenerate width-0
VS-16 follower — width 1. The grid folds the VS-16 into `cell.text`
(attrs equal), emits `✔` and `VS-16` contiguously with no SGR between,
and the outer glterm clusters them — width 2. Inner layout and outer
rendering disagree by one column.

**Gap 2 — the editor path has different width rules.** Only
vterm-sourced content gets cluster-aware widths. `put_str` /
`put_str_in_rect` use raw libc `wcwidth`: no Emoji_Presentation
widening, no cluster collapse. A VS-16 emoji or RI flag pair in a `.v`
buffer, a filename, or a message pane lays out 1 column while glterm
renders 2, shifting everything after it. `utf8.ml`'s column math has
the same problem, so the editor cursor walks out of sync with the
rendered line.

## Model

A grid cell is a *display cell*, matching glterm's spec:

- **Leader**: 1+ codepoints (a *cluster* when more than 1), width 1 or
  2, one SGR. Stored as `text : string` (UTF-8 of the leader
  codepoints only) + `width` + `attr`.
- **Followers**: zero or more zero-width codepoints, each with its own
  SGR. Stored as `followers : (string * attr) list` (in emit order;
  rename of today's `combs`, which is kept reversed — normalize while
  we're here or document the cons order, implementer's choice).
- Width-2 leaders are followed by a continuation slot (`width = 0`),
  as today.

The invariant the model must keep that today's doesn't: **`text`
never absorbs followers.** Every zero-width codepoint that arrives
after the leader is a follower entry, even when its attr equals the
leader's. The leader's multi-codepoint case comes only from cluster
sequences delivered whole (vterm cluster cells via `get_row`, or the
editor-side cluster walker below).

## Changes

### 1. Width + classification stub (vterm_stubs.c)

**Done** (`7799346`, re-synced for upstream `9eb45ae`). One primitive
in `vterm_stubs.c` (rocqtui-specific — vendored files stay
byte-for-byte):

```c
/* caml_render_cp_class : int -> int
   char_width(cp) in bits 0-3, plus flags: 0x10 nonprintable,
   0x20 cluster trigger-extend, 0x40 regional indicator,
   0x80 Extended_Pictographic — from the vendored char_width.h,
   cluster.h, and the generated emoji_props.h. */
```

- Guard `cp < 32`: nonprintable width 1 (avoids the `ENC_TAB = 16`
  collision; control codepoints never reach layout anyway).
- `Utf8.cp_class` + `class_*` accessors decode the bitmask. This is
  the *single width authority*: `grid.ml`'s three layout sites and
  `utf8.ml`'s `codepoint_width` route through it.
- Phase 3 extends the mask with the gating predicates from the
  generated `emoji_props.h`: `0x100 emoji_vs16_base`,
  `0x200 emoji_modifier_base`, `0x400 emoji_presentation`.

Upstream `9eb45ae` replaced the hand-written property lists with
predicates generated from vendored UCD 17.0 data, so the
classification is Unicode-data-driven end to end. Width prescription
(final): wcwidth corrected by the Emoji_Presentation set — EP=No
pictographs narrow, lone RI wide, bare EP=No modifier bases narrow
(the deliberate kitty divergence, see §5). `fontvis/text.ml`'s
`render_width` still widens by the old pictographic blanket —
upstream drift to fix separately.

### 2. Cell model (grid.ml)

- `combs` → `followers : (string * attr) list`; `append_combining`
  loses the fold branches — it always appends a follower (the
  `?attr` default becomes the cell's current attr).
- `cell_eq`, `copy`, `clear*`, `fill`, `chgat` (still resets
  followers), `set_underline`: mechanical.
- **Emit rules** (`emit_cell_payload`):
  - Leader text under leader attr, then each follower under its own
    attr, as today.
  - **Forced cluster break**: if a follower's first codepoint is a
    cluster trigger (`TRIGGER_EXTEND` or RI) and no SGR transition
    would otherwise be emitted, emit a redundant SGR (re-assert the
    current fg, e.g. `\e[39m` / current color) before the follower.
    Rationale: a trigger living in a *follower* means inner vterm
    chose not to cluster (an SGR command intervened); the outer glterm
    breaks clustering on any SGR command, so the redundant SGR
    reproduces vterm's split exactly. Non-trigger followers (ordinary
    combining accents) need no break — contiguous bytes are faithful.
    This rule is cold: real clusters arrive whole in the leader text,
    and divergent-attr followers carry a natural SGR transition that
    already breaks in the right place. It fires only when a producer
    interleaves an attr-invisible event (no-op SGR, same-spot cursor
    move) inside an emoji sequence — adversarial-test territory, not
    real traffic.
  - **Cross-cell hazards** (same genus, between *leader* cells): a
    lone-RI cell followed by an RI-leading cell would pair into a
    flag in the receiver, and a ZWJ-tailed cluster followed by a
    pictographic leader would join. Emit tracks a one-cell hazard
    lookbehind (reset on every cursor reposition, which already
    resets the receiver's parser) and forces a break when the
    boundary would fuse.
- `diff` / `emit_all` are unchanged beyond `cell_eq`.

`terminal.ml` barely changes: it already passes `~attr` for every
width-0 cell; remove nothing, rename `combs` uses.

### 3. Cluster-aware layout walker (editor path)

A single string-walking function (in `grid.ml` or a new small module)
producing display cells from a UTF-8 string + base attr:

```
walk : string -> (leader_text * width * follower_texts) list
```

- Port of glterm's `cluster_step` + `cluster_gate` (post-`9eb45ae` —
  NOT the older ungated `fontvis/text.ml` `build_lines`, whose
  "any trigger widens to 2" rule is now wrong). Triggers always
  absorb into the leader (round-trip), but width changes are gated:
  - VS-16 → width 2 only on `emoji_vs16_base` bases; else width
    unchanged.
  - VS-15 → width 1.
  - Skin tone → width 2 only on `emoji_modifier_base` bases; else
    unchanged.
  - ZWJ, bare keycap (U+20E3), tag characters → never change width;
    ZWJ continuation is gated by `extended_pictographic`. A
    minimally-qualified ZWJ sequence (no VS-16, EP=No base) stays at
    base width.
  - RI pairs collapse to one width-2 cell; lone RI is width 2 by
    itself (EP=Yes).
- The walker tracks *width only*. Presentation (mono vs color font)
  is the rendering terminal's concern — rocqtui re-emits the
  codepoints and the outer terminal applies UTS #51 itself (§5 pins
  the ambiguous cases).
- Zero-width non-triggers attach as followers (old combining path).
- Non-printables skip, as today.

Consumers:

- `put_str`, `put_str_in_rect` — replace their inline decode loops.
- `utf8.ml` column math (`byte_to_col` / `col_to_byte` /
  `codepoint_width` consumers) — must use the same walker so editor
  cursor/selection columns agree with rendered widths. `test_width.ml`
  grows cluster cases.
- `set_cell` stays as the raw single-cell primitive (callers pass
  pre-formed glyphs, e.g. file-tree markers).

Editor-side followers always carry the base attr today; divergent
follower SGR for editor content (e.g. colored accents in messages) is
enabled by the model but out of scope.

### 4. Transparency test (the point of all this)

`test/test_transparency.ml`, in `dune runtest` (no Rocq, no
subprocess needed — vterm *is* glterm's engine, so a second vterm
instance models the outer terminal):

1. Feed a crafted byte stream into vterm A (`Vterm_api.proc`).
2. Render A into a grid via `Terminal.render`.
3. `Grid.emit_all` the grid; feed those bytes into vterm B.
4. Render B into a second grid; assert the grids are cell-for-cell
   equal (text, width, attr, followers).

Cases: plain text + SGRs; combining marks with divergent SGR; ZWJ
sequences; RI flag pairs (incl. an odd RI); keycap; skin tone; VS-15
and VS-16 (on default-text and default-emoji bases); the
SGR-no-op-split corner from Gap 1 (fails until the forced-break emit
rule lands); tabs; wide chars and clusters at the right edge;
followers on wide leaders.

`tools/emoji_check.ml` / `tools/sgr_check.ml` remain as interactive
probes; update them for the renamed field.

### 5. Presentation disambiguation (VS injection)

Rocqtui follows glterm's width prescription exactly (via the vendored
headers), but kitty deviates from it on one class of codepoints: the
EP=No Emoji_Modifier_Base set — U+261D, U+26F9, U+270C, U+270D,
U+1F3CB, U+1F3CC, U+1F574, U+1F575, U+1F590 — bare-width 2 in kitty
(its widening rule is effectively EP||EMB), width 1 per UTS #51,
glibc wcwidth, glterm `9eb45ae`, and iTerm2's strict-EAW tables.
Upstream's full-plane sweep against kitty 0.45 confirms these nine
are the only spec-side divergence among codepoints the host libc
knows. Kitty honors VS-15/VS-16 for layout in both directions
(verified: VS-15 narrows the EMB hands to 1), so emission can pin
the width:

- The ambiguous set is exactly `emoji_modifier_base(c) &&
  !emoji_presentation(c)` — computable from the vendored generated
  `emoji_props.h`; no separate list to maintain. Phase 3's extended
  bitmask already carries both predicates, so the emit path derives
  the bit for free.
- `emit_cell_payload`: when a leader is a single bare ambiguous
  codepoint (no VS present — well-defined once followers are never
  folded into leader text), append VS-15 if the cell's width is 1,
  VS-16 if 2.
- Unconditional — no outer-terminal detection. Inside glterm the
  injected VS is a rendering no-op by construction (glterm honors VS
  and prescribes the same bare width).

Costs, accepted: emitted bytes differ from source bytes for those
codepoints, so copy/selection in the *outer* terminal picks up the
injected selector; and the round-trip transparency test must compare
modulo injected VS (vterm B clusters what vterm A held bare).

Since the nine ambiguous codepoints are all laid out narrow under the
prescription, injection is VS-15 in practice; the VS-16 direction of
the rule exists for symmetry should a future prescription change
introduce wide-but-ambiguous codepoints.

Out of reach from our side: content carrying an explicit VS-16 on a
narrow base misaligns in any outer terminal that ignores VS for
layout (iTerm2 status unverified — pending the cursor-position probe
on macOS); bare keycaps take no trailing VS, but need none — the
prescription keeps them narrow (kitty and iTerm2 both measure 1); and
the EAW=Ambiguous circled numbers U+3248-324F (glibc wide, kitty
narrow, not emoji) are not VS bases, so they cannot be pinned —
accepted divergence, we follow glibc.

The upstream gate is satisfied: the prescription landed as glterm
`9eb45ae` and is vendored here (rocqtui sync `c9ad02e`). This phase
is now implementable any time after Phase 2 (it needs the no-fold
leader invariant).

## Phases

Each phase is a build-clean, test-clean stopping point.

1. **Width authority.** DONE (`7799346`; re-synced to upstream
   `9eb45ae` in `c9ad02e`). Classification stub; `grid.ml` and
   `utf8.ml` widths routed through it; `test_width.ml` asserts the
   prescription.
2. **Cell model + emit.** DONE. `followers` always distinct;
   forced-break rules (follower triggers + cross-cell hazards);
   `test/test_transparency.ml` round-trips 23 byte streams through
   vterm → grid → emit → vterm and compares grids (Gap 1 closed).
   Bonus: the test immediately caught a stale `ENC_TAB` constant in
   `terminal.ml` (0x07 vs term.h's 16) — embedded-terminal tabs had
   been rendering as a raw DLE cell.
3. **Cluster walker.** Extend the bitmask with the gating predicates
   (`emoji_vs16_base`, `emoji_modifier_base`, `emoji_presentation`);
   `walk` + rewire `put_str` / `put_str_in_rect` / `utf8.ml` column
   math (Gap 2 closes).
4. **Verify & prune.** Probe tools updated; manual check in glterm
   (✔/⚠ markers, emoji in a `.v` comment, `cat` of zwj-test files in
   the embedded terminal, copy round-trip).
5. **VS injection.** Ambiguous bit (`EMB && !EP`), emit-time VS-15
   append, transparency test compares modulo injected VS. Needs
   Phase 2's no-fold invariant; upstream gate already satisfied.

## Open questions

- Forced-break SGR encoding: re-emitting the current fg is always
  attr-neutral; pick the shortest stable form. Outer terminals other
  than glterm may cluster differently regardless — we reproduce
  vterm's segmentation and accept that non-glterm outers are best
  effort.
- `followers` list order: normalize to emit order (append) vs keep
  reversed cons + `List.rev` at emit. Cosmetic; decide in Phase 2.
- Does any editor surface want divergent follower SGR now (e.g.
  search-highlight on a combining mark)? Out of scope unless trivial.
