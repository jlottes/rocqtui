# SGR passthrough — embedded terminal full SGR support

Upstream glterm (`~/glterm-1`) landed commit `83ab18f` ("struct gr: 4-word
layout, separate underline color, full SGR encoding") which widens
`struct gr` from 8 to 16 bytes and tracks the full SGR vocabulary: italic,
strikethrough, conceal, overline, blink, underline style (single / double /
curly / dotted / dashed), underline color, plus the rarer frame / script /
font / spacing slots. Rendering inside glterm itself still only paints what
it painted before — the new state survives encode/decode but isn't drawn.

For our embedded terminal we want the opposite: glterm's state machine
parses the SGRs, we read them out via the C API, and we **forward all of it
back out** to the user's outer terminal. Apps running inside our embedded
terminal (`vim`, `bat`, `eza`, language servers, `git diff --color-words`)
should display the same as if they were running directly in the user's
terminal.

The upstream merge forces a small mechanical stub rewrite — `gr_attrb()`
macro is gone and the color-mode encoding changed. The interesting work is
expanding `Grid.attr` and `emit_attr` to carry and emit the new state.

## What changed at our boundary

Our boundary is `lib/vterm/vterm_stubs.c:191–241` — two helper functions
that convert `struct gr` into OCaml `Grid.attr` records. Both stop
compiling against the new upstream.

### `struct gr` shape

- Old: `{ uint32 fg, bg; }`. `fg` carried the attribute bitmask in bits
  26..30; `bg` carried cell width in bits 26..31.
- New: `{ uint32 fg, bg, ul, a; }`. Each of `fg/bg/ul` is a clean color
  word; `a` is the dedicated attribute word. Cell width moved to
  `a` bits 22..25.

We read `c->w` from `struct vterm_cell` (not from `gr.bg`), so the
width-move is invisible to us. ✓

### Color mode encoding

Mode bits (24..25) of each color word changed:

| mode | old | new |
|---|---|---|
| 00 | 16-color (with `DEFAULT_COLOR = 0x09` sentinel) | default (value 0) |
| 01 | 256-color | 16-color (0..15 directly) |
| 10 | 24-bit RGB | 256-color |
| 11 | unused | 24-bit RGB |

Two side-effects:

- The "8..15 disguised as 256-color" hack used for bright colors goes
  away. `90`–`97` / `100`–`107` SGRs land in `Basic 8..15` directly,
  which our `sgr_of_color` already maps to outer SGR `90`–`97`. Bonus:
  terminals with customised bright palettes now get the right color.
- The `DEFAULT_COLOR == 0x09` sentinel that collided with 16-color index
  9 is gone — default is now `mode == 0`, plain and unambiguous.

### Attribute accessors

`gr_attrb(g)` and `ATTRB_BD/UL/IN/DM` are gone. New API:

```c
a_get(g.a, BOLD)            /* 0 or 1 */
a_get(g.a, UNDERLINE)       /* 0..5 — underline style slot */
a_get(g.a, ITALIC)          /* 0/1/2 — none/italic/Fraktur */
/* ... see term.h A_* names ... */
```

Bold and faint are **independent bits** in `gr.a` (slot semantics live in
`cf_SGR`, not in storage), so our existing `bold:bool + dim:bool` split in
`Grid.attr` stays semantically correct. We don't need to collapse them
into a 2-bit slot at our level.

### Other items

- `cursor_pos.attrb` widened from `uchar` to `uint32`. We don't read it
  from OCaml — `caml_vterm_cursor_info` only reads `x/y/w`. No change.
- The half-buffer wire format expanded (17 tokens, ATTRB SHORT/MID/FULL
  variants, separate `ENC_*_DEF` tokens). Fully internal to vterm; we
  don't touch it.
- `gr_eff_bg`'s legacy "blink → bright bg" substitution was dropped.
  This was a glterm-only quirk. No effect on us.

## Target Grid.attr shape

Expand `lib/grid.{ml,mli}` to carry every SGR slot vterm tracks. Variants
where the slot is multi-valued, bools where it's a single bit:

```ocaml
type color =
  | Default
  | Basic of int          (* 0..15 — full 16-color palette *)
  | Color256 of int
  | TrueColor of int * int * int

type underline_style =
  | UL_none
  | UL_single
  | UL_double
  | UL_curly
  | UL_dotted
  | UL_dashed

type italic_style = Italic_none | Italic_on | Italic_fraktur
type blink_style  = Blink_none  | Blink_slow | Blink_rapid
type frame_style  = Frame_none  | Frame_box  | Frame_circle
type script_style = Script_none | Script_super | Script_sub

type attr = {
  fg : color;
  bg : color;
  ul : color;                       (* underline color *)
  bold : bool;
  dim : bool;                       (* aka faint *)
  italic : italic_style;
  underline : underline_style;
  reverse : bool;
  strikethrough : bool;
  conceal : bool;
  overline : bool;
  blink : blink_style;
  frame : frame_style;
  script : script_style;
  font : int;                       (* 0..9, primary..alt9 *)
  spacing : bool;                   (* proportional — almost nobody implements *)
}
```

Cost considerations:

- `Grid.attr` is a value type stored in cells. Records aren't allocated
  per-cell — they're shared by reference when the rendition doesn't
  change. So memory cost is per-rendition-transition, not per-cell.
- `cell_eq` becomes more fields but stays cheap: polymorphic `=` does
  pointer-equality first, and the same-rendition runs dominate.
- This is a breaking change to `Grid.attr` (record extension). Every
  existing constructor of `Grid.attr` needs the new fields. `default_attr`
  becomes the single point of truth for "no attributes" — every
  call-site of `{ Grid.default_attr with fg = ...; bold = ...; }`
  continues to work; bare `{ fg = ...; bg = ...; bold = ...; dim = ...;
  reverse = ...; underline = ...; }` constructors don't. We have 117
  hits across `lib/`, `bin/`, `test/` to audit, but most are the
  `with` pattern. The pure constructor form is mostly in test fixtures
  and a few of the UI panels.

Alternative considered: pack `gr.a` into an int and store as a single
field. Faster comparisons, smaller value, but the type leaks the bit
layout into every consumer. Rejected — record with named fields is
better for the dozens of UI panels that build attr values.

## Stub rewrite (`vterm_stubs.c`)

Two helpers change.

### `gr_color_to_ocaml`

```c
static value gr_color_to_ocaml(uint32 c)
{
  CAMLparam0();
  CAMLlocal1(v);
  switch (c & GR_MD_MASK) {
  case 0:           /* default */
    CAMLreturn(Val_int(0));
  case GR_MD_16:    /* Basic of int — full 0..15 */
    v = caml_alloc(1, 0);
    Store_field(v, 0, Val_int(c & 0x0fu));
    CAMLreturn(v);
  case GR_MD_256:   /* Color256 of int */
    v = caml_alloc(1, 1);
    Store_field(v, 0, Val_int(c & 0xffu));
    CAMLreturn(v);
  case GR_MD_24:    /* TrueColor of int * int * int */
    v = caml_alloc(3, 2);
    Store_field(v, 0, Val_int((c >> 16) & 0xff));
    Store_field(v, 1, Val_int((c >>  8) & 0xff));
    Store_field(v, 2, Val_int( c        & 0xff));
    CAMLreturn(v);
  }
  CAMLreturn(Val_int(0));
}
```

Call sites pass `g.fg` / `g.bg` / `g.ul` directly — no mode arg needed,
the helper reads it.

### `gr_to_attr`

```c
static value gr_to_attr(struct gr g)
{
  CAMLparam0();
  CAMLlocal4(v_attr, v_fg, v_bg, v_ul);
  v_fg = gr_color_to_ocaml(g.fg);
  v_bg = gr_color_to_ocaml(g.bg);
  v_ul = gr_color_to_ocaml(g.ul);
  /* Grid.attr — 16 fields, in declaration order */
  v_attr = caml_alloc(16, 0);
  Store_field(v_attr,  0, v_fg);
  Store_field(v_attr,  1, v_bg);
  Store_field(v_attr,  2, v_ul);
  Store_field(v_attr,  3, Val_bool(a_get(g.a, BOLD)));
  Store_field(v_attr,  4, Val_bool(a_get(g.a, FAINT)));
  Store_field(v_attr,  5, Val_int (a_get(g.a, ITALIC)));     /* immediate variant */
  Store_field(v_attr,  6, Val_int (a_get(g.a, UNDERLINE)));
  Store_field(v_attr,  7, Val_bool(a_get(g.a, INVERSE)));
  Store_field(v_attr,  8, Val_bool(a_get(g.a, STRIKETHROUGH)));
  Store_field(v_attr,  9, Val_bool(a_get(g.a, CONCEAL)));
  Store_field(v_attr, 10, Val_bool(a_get(g.a, OVERLINE)));
  Store_field(v_attr, 11, Val_int (a_get(g.a, BLINK)));
  Store_field(v_attr, 12, Val_int (a_get(g.a, FRAME)));
  Store_field(v_attr, 13, Val_int (a_get(g.a, SCRIPT)));
  Store_field(v_attr, 14, Val_int (a_get(g.a, FONT)));
  Store_field(v_attr, 15, Val_bool(a_get(g.a, SPACING)));
  CAMLreturn(v_attr);
}
```

The variant-style fields (italic/underline/blink/frame/script) are stored
as OCaml `int` tags because each variant type has only constant
constructors — the runtime representation is exactly `Val_int(n)`. The
slot value from `a_get` (0..N) matches the constructor order one-to-one.

## emit_attr changes (`grid.ml:338`)

Current logic: detect any attribute turning off, if so emit `\e[0m` and
re-emit everything that's on; otherwise emit just the deltas.

Extend in three steps:

1. **`needs_reset` predicate** grows to cover all attributes that can be
   cleared: bold/dim/reverse/underline-style, plus italic/strikethrough/
   conceal/overline/blink/frame/script/font/spacing transitions to
   their "none" / 0 state.
2. **"After reset, re-emit everything on"** branch gains an SGR for each
   non-default field.
3. **Incremental branch** gains a `if a.X <> p.X then …` line per slot.

SGR codes to emit:

| attribute | on | off |
|---|---|---|
| bold | `1` | (handled by `22` on dim too) |
| dim | `2` | `22` (resets bold + dim) |
| italic | `3` (italic) / `20` (Fraktur) | `23` |
| underline single | `4` | `24` |
| underline double | `21` (or `4:2`) | `24` |
| underline curly | `4:3` | `24` |
| underline dotted | `4:4` | `24` |
| underline dashed | `4:5` | `24` |
| reverse | `7` | `27` |
| conceal | `8` | `28` |
| strikethrough | `9` | `29` |
| blink slow | `5` | `25` |
| blink rapid | `6` | `25` |
| overline | `53` | `55` |
| frame box | `51` | `54` |
| frame circle | `52` | `54` |
| script super | `73` | `75` |
| script sub | `74` | `75` |
| font alt N | `10+N` | `10` |
| spacing | `26` | `50` |
| fg/bg/ul colors | `30+n` / `40+n` / `90+n` / `100+n` / `38;5;n` / `38;2;r;g;b` / `58;5;n` / `58;2;r;g;b` | `39` / `49` / `59` |

### Bold + dim interaction note

SGR `22` resets *both* bold and dim. So when transitioning from
`{bold; dim}` to `{}`, one `22` covers it. When transitioning from
`{bold}` to `{dim}`, we emit `22;2`. Trivially handled by the reset-and-
rebuild branch already in place.

### Curly underline syntax constraint

Curly / dotted / dashed underline use **colon-separated sub-parameters**:
`\e[4:3m`. There is no semicolon fallback. The outer terminal must parse
colon syntax — modern terminals do (kitty, vte, alacritty, wezterm, foot,
iTerm2, recent xterm). tmux ≥ 3.2 passes it through; mosh passes
arbitrary CSI bytes. Worth a comment in the emit code so future readers
know not to "fix" the colon.

For double underline we have a choice: `21` (single-parameter) or `4:2`
(colon sub). `21` is older-spec-compliant and works on more terminals.
Prefer `21`.

### Underline color

SGR `58` accepts only `5;n` (256-color) and `2;r;g;b` (RGB) forms — no
16-color variant. Our `sgr_of_color` for `ul` therefore needs to handle
`Basic n` by promoting it to `Color256 n` (the first 16 entries of the
256-color palette match the 16-color palette). Same for `Default` →
emit `59`.

### Reset code

The reset-and-rebuild branch in `emit_attr` re-emits "everything on". The
`\e[0m` reset clears every SGR slot, so we re-emit fg/bg/ul/bold/dim/
italic/underline/reverse/conceal/strikethrough/blink/overline/frame/
script/font/spacing as needed. Order doesn't matter; merge into one
`\e[...m` sequence as today.

## Mosh compatibility

`mosh_dim_color` (grid.ml:323-335) substitutes a darker fg when `dim` is
on because mosh drops SGR `2`. We should audit what other SGRs mosh
drops — likely italic (`3`), strikethrough (`9`), conceal (`8`),
overline (`53`), and the colon-form underlines (`4:3` etc.) are passed
through fine since they're ordinary CSI bytes, but worth verifying. If
some are dropped, extend `effective_attr` with analogous substitutions
(e.g. for missing strikethrough, fall back to nothing — there's no good
visual substitute).

This is follow-up work; punt until after the basic passthrough lands.

## Rollout

Three commits, each independently buildable and testable.

### Commit 1 — vterm bump + stub migration

- Pull upstream `83ab18f` into our vendored vterm (`lib/vterm/`).
- Rewrite `gr_color_to_ocaml` and `gr_to_attr` per above.
- **No `Grid.attr` change yet.** The new `gr_to_attr` discards the
  extra attribute bits at the C boundary and only populates the
  existing 6 record fields. So `Grid.attr` stays the same shape, and
  no OCaml call-site changes.
- Smoke test: `dune build`, `dune runtest`, `dune build @e2e`,
  launch `bin/main.exe`, open the embedded terminal (`^T`), run `vim`
  or `bat`, confirm rendering looks the same as before.

Reviewers can land this in isolation. It's purely a "keep building"
change.

### Commit 2 — extend Grid.attr

- Add the new fields and variant types to `lib/grid.{ml,mli}`.
- Update `default_attr`, `cell_eq`, `empty_cell`.
- Update `gr_to_attr` to populate the new fields.
- Audit the 117 `Grid.attr`-touching sites — most use the `with`
  pattern and need no change. Constructor forms (e.g. test fixtures)
  switch to `{ default_attr with ... }`.
- `emit_attr` still only emits the original four attrs (we discard
  the new data in the emit path for now).
- No user-visible behavior change.

Smoke test: same as commit 1. The new fields are silently truncated
by `emit_attr`, so the output is identical.

### Commit 3 — extend emit_attr

- Per the table above, extend `needs_reset`, the rebuild branch, and
  the incremental branch.
- Add `sgr_of_underline_color` (or extend `sgr_of_color` with a `~ul`
  flag) to handle the `58` / `59` / no-Basic-form requirement.
- Add comments at curly-underline emit and underline-color emit
  pointing at this doc.

Smoke test:

- `bat foo.ml` inside embedded terminal — comments italic ✓
- `eza --icons` — italic file names ✓
- `vim` with a syntax theme using italic / strikethrough ✓
- Language server in `vim` / `helix` — curly red under errors ✓
- `git diff --color-words` — strikethrough on removed words ✓
- `passwd` prompt — conceal hides typed chars ✓

### Optional follow-up

- Audit mosh fallthrough for italic / strikethrough / curly /
  underline color. Extend `effective_attr` substitutions as needed.
- Consider whether `Styled.span` (`lib/styled.ml`) wants to use any of
  the new attrs internally (e.g. strikethrough on dropped Errors-tab
  entries). Independent feature work, not part of passthrough.

## Out of scope

- No rendering changes inside glterm itself. Glterm still draws what
  it drew before; the new attributes only become visible when they
  exit our embedded terminal and hit the outer one.
- No new attributes we invent on our side — only the ones vterm tracks.
- No changes to `lib/styled.ml`. Span attributes already use
  `Grid.attr` and will pick up the new fields automatically.
