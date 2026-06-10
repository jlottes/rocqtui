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

One new primitive in `vterm_stubs.c` (rocqtui-specific — vendored
files stay byte-for-byte):

```c
/* caml_render_cp_class : int -> int
   Returns char_width(cp) in the low bits plus flag bits:
   TRIGGER_EXTEND, RI, PICTOGRAPHIC — from the vendored
   cluster.h classifiers and char_width.h. */
```

- Guard `cp < 32`: return width 1 with no flags (avoids the `ENC_TAB
  = 16` collision; control codepoints never reach layout anyway).
- `wcwidth < 0` maps per `char_width.h` (→ 1); the OCaml walker
  decides skip-vs-place, preserving current `put_str` semantics
  (non-printable → skip).
- One OCaml wrapper in `Grid` (or a small `Cellclass` module) decodes
  the bitmask. This is the *single width authority*: `grid.ml`'s
  three `wcwidth` call sites and `utf8.ml`'s `codepoint_width` all
  route through it. `locale_stubs.c`'s `caml_wcwidth` stays for
  anything genuinely locale-shaped, or dies if nothing else uses it.

Using the vendored `cluster.h` static inlines + `char_width.h` keeps
the classification aligned with upstream by construction — same
argument as upstream's `emoji_presentation.h` factoring. Note the two
sets differ on purpose: widening uses the Emoji_Presentation set
(post-`3d63ef3`); cluster *extension* uses the broader pictographic
approximation. `fontvis/text.ml`'s `render_width` still widens by the
pictographic blanket — upstream drift to fix separately.

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
- `diff` / `emit_all` are unchanged beyond `cell_eq`.

`terminal.ml` barely changes: it already passes `~attr` for every
width-0 cell; remove nothing, rename `combs` uses.

### 3. Cluster-aware layout walker (editor path)

A single string-walking function (in `grid.ml` or a new small module)
producing display cells from a UTF-8 string + base attr:

```
walk : string -> (leader_text * width * follower_texts) list
```

- Port of the `CPS_*` state machine from `fontvis/text.ml`
  `build_lines` (itself a port of glterm's `cluster_step`), driven by
  the classification stub: trigger-extend absorbs into the leader
  (VS-16 → width 2, VS-15 → width 1, skin tone/keycap/tag → width 2,
  ZWJ → await pictographic), RI pairs collapse, lone RI is width 2.
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

## Phases

Each phase is a build-clean, test-clean stopping point.

1. **Width authority.** Classification stub; route `grid.ml` and
   `utf8.ml` widths through it (no cluster collapse yet — flags
   unused). Editor gains Emoji_Presentation widening parity.
   `test_width.ml` updated.
2. **Cell model + emit.** `followers` always distinct; forced-break
   emit rule; transparency test added (this is where Gap 1 closes).
3. **Cluster walker.** `walk` + rewire `put_str` /
   `put_str_in_rect` / `utf8.ml` column math (Gap 2 closes).
4. **Verify & prune.** Probe tools updated; manual check in glterm
   (✔/⚠ markers, emoji in a `.v` comment, `cat` of zwj-test files in
   the embedded terminal, copy round-trip).

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
