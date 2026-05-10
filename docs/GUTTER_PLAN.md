# Line-number gutter — plan

Adds a line-number gutter to the script pane. Designed to be the substrate
for future markers (build errors/warnings, git diff stripes), not just a
standalone feature.

## Goals

- Show line numbers in the script pane.
- Reserve a marker column from day one so future error/warning/git markers
  drop in without reshaping widths.
- Keep the gutter unobtrusive: superscript digits, dim, theme-tinted.

## Design decisions

| Question | Decision | Notes |
|---|---|---|
| Width policy | Fixed minimum, grows with line count | min 4 digits, expand as needed |
| Numbering | Absolute | Relative numbering can be a later config option |
| Toggleable | Yes, default on | Persisted in config; bound to Alt+L |
| Wrapped lines | N/A | The script pane doesn't wrap (yet) |
| Style | Superscript digits ⁰¹²³⁴⁵⁶⁷⁸⁹ | Smaller visual weight than full digits |
| Color | Dim, theme-tinted bg | New `ga_gutter` attr in theme grid_attrs |
| Separator | None | Just whitespace gap before the content |
| Marker column | Dedicated, far-left | Always present when gutter is on; blank in v1 |

### Layout

```
  [marker:1][digits: max(4, ndigits)][gap:1][content...]
```

Minimum gutter width is 6 columns. The digit area grows for files with
≥10000 lines.

Mockup (errors/warnings shown for illustration; v1 leaves the marker
column blank):

```
       ¹  Definition foo : nat := 0.
       ²  Lemma bar : foo = 0.
  ●    ³  Proof.
       ⁴    reflexivity.
  ▲    ⁵  Qed.
  ~   ⁴²  (* line 42 — modified *)
     ¹⁰⁰  (* line 100 *)
    ¹²³⁴  (* line 1234 *)
```

### Why a dedicated marker column

Considered alternatives:
- **Color/background only, no glyph** — disappears in monochrome and
  doesn't survive when categories stack (error on a modified line).
- **Glyph replaces leading-space slot when free, else falls back to
  color** — width rule depends on line count, surprising.
- **Dedicated 1-char column** *(chosen)* — simple mental model, survives
  wide line counts, cheap to skip when nothing's marked.

## Toggle binding: Alt+L

The only free Ctrl-letter is ^V (and that's a poor fit). Alt-letter space
is wide open. Alt+L reads as "line numbers."

- Kitty code: `(108, 3)` (lowercase 'l', alt modifier)
- Legacy (non-Kitty) ESC+letter: currently `input.ml` swallows
  ESC+letter as `RawKey 27`. **Punt on legacy for v1**; document that
  Alt+L requires Kitty mode. Other Alt bindings (Alt+. interrupt,
  Alt+arrows step) have their own legacy mappings, so this is a known
  inconsistency to revisit later.

## Files to touch

| File | Change |
|---|---|
| `lib/config.ml` | Add `show_line_numbers : bool ref` (default `true`) |
| `lib/theme.ml` | Add `ga_gutter` to `grid_attrs`; populate per theme (dim fg + optional tinted bg) |
| `lib/keys.ml` | Add `toggle_gutter` binding for Alt+L |
| `lib/view.ml` | In `render_script`: compute `gutter_width`, render gutter at pane col 0, shift `put_str` content + cursor placement by `gutter_width` |
| `lib/editor/geom.ml` | Subtract `gutter_width` in `screen_to_buffer_pos` |
| `lib/main_loop.ml` (or wherever globals dispatch) | Wire toggle action |

A small helper like `Geom.gutter_width_of_view` may be cleaner than
threading state through every call site that does column math.

## Subtleties

- Gutter is non-scrolling: hscroll only affects the content area.
- Highlight spans (syntax, search, selection) apply to content, never to
  the gutter.
- Toggling off → `gutter_width = 0`; the marker column also disappears
  with the rest of the gutter.
- Cursor stays at the same buffer position when toggled; only its screen
  column shifts.

## Risk / unknowns

- Other code paths may assume "screen col 0 = buffer col 0" — status bar
  overlays, error/highlight rendering, minimap. Audit during
  implementation.
- Theme work: every theme record needs a `ga_gutter` value. Pick
  reasonable defaults from the existing palette (e.g. dim variant of the
  border color).

## Future extensions (motivation, not scope)

The gutter is the substrate for:

- **Build error/warning markers** (`docs/TODO.md:74`) — populate the
  marker column from parsed compiler output. Click on the marker (or on
  the corresponding line in the build pane) jumps to the error and
  pushes onto the same jump stack as ^L.
- **Git diff stripes** (`docs/TODO.md:126`) — added/modified/deleted
  glyphs in the marker column.
- **Go to line number** (`docs/TODO.md:48`) — independent of the gutter
  but naturally fits alongside.

Marker priority when categories stack: error > warning > git.
