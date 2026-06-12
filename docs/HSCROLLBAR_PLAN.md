# Horizontal scrollbar — design

> **Status: implemented** — `lib/hscrollbar.ml`, geometry unit tests
> in `test/test_hscrollbar.ml`.

## Status quo

The horizontal scroll indicator is a fixed 10-cell mini-bar
(`◀───███──▶`) embedded in the status-line text
(`view.ml`, `hscroll_ind`, ~line 995). Problems:

- It competes for status-bar space with search info, compose hints,
  focus help, etc., and disappears into the noise.
- It only appears when `hscroll > 0` — no affordance that a long line
  runs off the right edge before you've scrolled.
- Max line width is estimated from a hardcoded `scroll .. scroll+30`
  line scan, which may not match the actual visible rows.
- 10 cells is too coarse to read position from.

## Proposal

Give the scrollbar the **bottom row of the script pane** when it is
shown, full content width. Remove the status-line mini-bar entirely.

### Visibility rule

Show the scrollbar iff:

```
hscroll > 0  ||  max visible line width > content_cols
```

i.e. the view is horizontally scrolled, **or** something on the
current screen runs off the right edge. Otherwise the row returns to
ordinary content.

- "Visible lines" = exactly the rows on screen
  (`scroll_top .. scroll_top + content_rows - 1`), replacing the
  30-line approximation.
- Guard: never show when the pane is very short (`rows < 3`).

Chicken-and-egg note: visibility depends on which lines are visible,
which depends on how many content rows there are, which depends on
visibility. Resolve by computing visibility against `rows` (the full
pane height) and accepting the one-row fuzz at the boundary — a line
that pokes past the edge only on the row the scrollbar replaces will
briefly toggle it; harmless in practice. Revisit with hysteresis only
if it jitters in real use.

### Module

New `lib/hscrollbar.ml` / `.mli`, mirroring `lib/minimap.ml`: a
self-contained widget module owning visibility, geometry, and
drawing, pure with respect to state (`hscroll` stays in `Buffer`).
The col↔track mapping has two consumers — rendering (thumb
placement) and mouse (click/drag must invert the same mapping) — so
it lives here once. `view.ml` reserves the row and calls
`Hscrollbar.draw`; `lib/editor/mouse.ml` calls its hit-test /
inverse-mapping functions.

### Layout integration

- In `render_script`: when shown, content rows = `rows - 1`; the last
  row renders the scrollbar instead of buffer content.
- `ensure_visible_h` gets the reduced row count so the cursor can
  never hide under the bar (same pattern as `panel_rows` for the find
  panel).
- When the find panel is open (`panel_rows > 0`), the scrollbar sits
  on the bottom-most *visible* script row, i.e. it stacks above the
  panel, not under it.
- Tools (`grid_cat`) and headless mode are unaffected — they don't
  scroll horizontally.

### Geometry

Track spans the content area only — starting at column `gw` (gutter
width), `content_cols` wide — so thumb position aligns with the text
columns directly above it. (The row's bg tint covers the gutter
cells too, but the thumb never enters them.)

```
total       = max (max_visible_width, hscroll + content_cols)
thumb_start = hscroll * track_len / total
thumb_len   = max 1 (content_cols * track_len / total)
```

#### Sub-cell thumb resolution (8×)

Block-fill thumbs can render edges at 1/8-cell precision, in the
spirit of the braille minimap:

- **Right edge**: the left-fill eighth blocks `▏▎▍▌▋▊▉█` directly —
  a cell 3/8 covered by the thumb is drawn as `▍` in thumb color.
- **Left edge**: no right-fill counterparts exist, so draw the edge
  cell as a left-fill block with the `reverse` attribute — the
  glyph's ink becomes background and the remainder thumb color.
  Works with terminal-default colors (SGR 7 swaps whatever is in
  effect).

With a ~50-cell track this yields ~400 subpositions, so the thumb
moves on every column of scroll instead of every 2–4 columns.

Caveat: the un-filled fraction of an edge cell renders as flat
background, so a textured track (`░`, `─`) shows a sub-cell gap
adjacent to the thumb. Invisible with no track; minor with a line
track.

Line-drawing chars (`─`/`━`) have no sub-cell variants — a pure
line-style thumb is limited to 1-cell resolution.

#### Arrow glyphs

The Geometric Shapes triangles sit on the text baseline, not the
line centerline, so they misalign with `─`/block rows: `◀`/`▶`
(U+25C0/25B6) visibly, and the small `◂ ▸` (U+25C2/25B8) the same
way but proportionally worse at their size (verified in iTerm2).
Use `⯇`/`⯈` (U+2BC7/U+2BC8, black medium triangle *centred*) —
designed for the arrow centerline and confirmed aligned in iTerm2.
(They're Unicode 7.0 Misc Symbols and Arrows; font coverage is
narrower than the Geometric Shapes ones — acceptable for now,
revisit if tofu shows up on other setups.)

### Style — chosen: tinted row + floating 8× block thumb

The scrollbar row gets a **faint background tint** across the full
pane width so it reads as chrome, with a **floating block thumb**
(no track glyphs — the flat tint *is* the track):

```
 ²⁰⁵ app : forall (l l' : list B) (a : A) (f : A ->
 ²⁰⁶ left f (l ++ l') a = fold_left f l' (fold_left
 ◂            ▐███████████████▍                   ▸    <- row bg tinted
 main.v  Ln 206, Col 17  [4 verified]  ^S:Save ...
```

- **Row bg**: new theme color, faint and distinguishable from the
  default bg *and* from the `verified_bg` / `processing_bg` region
  tints (e.g. solarized-dark: verified is 235 on default bg, so
  something like 237 works). One new theme field, e.g.
  `hscroll_bg`, plus `hscroll_thumb_fg` for the thumb.
- **Thumb**: `█` cells in the thumb fg over the tint, with
  eighth-block edges (8× resolution, see below). Flat-tint track
  means the sub-cell edge caveat vanishes — nothing for the partial
  cell to interrupt.
- **End indicators**: `⯇` / `⯈` (U+2BC7/U+2BC8 black medium
  left/right-pointing triangle **centred** — the "centred" variants
  sit on the arrow/line centerline rather than the text baseline,
  and render correctly aligned in iTerm2). Each is shown only when
  there is more content in that direction; they double as
  page-left/right click targets. Easily dropped if they prove noisy.
- Track geometry (thumb mapping) still spans the content area
  (`gw .. cols-1`); the tint covers the whole row including the
  gutter cells so the strip reads as deliberate chrome.

Rejected alternates considered: status-bar-widget scale-up with
`◀`/`▶` arrows (glyph alignment problems), pure line-drawing
`─`/`━` minimal bar (liked, but capped at 1-cell resolution),
`░`-shaded track (heavy, and textures fight the sub-cell edges).

### Mouse

A dedicated row makes mouse support natural (the status-line widget
had none):

- Click on track: center the thumb at the click → set `hscroll`.
- Drag the thumb: continuous horizontal scroll.
- Click arrows (style A/D): page left/right by `content_cols / 2`.
- Routed via `pane_at` = `PScript` + row == scrollbar row in the
  mouse handler.

### Removal

Delete `hscroll_ind` from `update_status` in `view.ml`.

## Out of scope (for now)

- Horizontal scroll-wheel events.
- Per-buffer max width (whole-file scan) — visibility is driven by
  the current screen only, per the rule above.
- Hysteresis / sticky visibility — only if the simple rule proves
  jittery.
