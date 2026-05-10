# Styled-text refactor for messages / goals panes

Today `Tab.msg_tab.mt_lines` and `mt_lines_cache` are `string list`,
rendered everywhere with one default attribute. We want per-segment
styling in those panes — to color the Errors-tab severity glyph, dim
paths, highlight the active entry, and (later) carry Rocq Pp tags as
spans on goals/messages content.

This refactor introduces a single styled-line type and migrates the
message and goals pane plumbing to use it. **No user-visible behavior
change** — every existing producer wraps strings as plain styled lines.
Span-emitting producers (Errors tab, eventually Pp output) come in
follow-up changes.

## Module: `lib/styled.ml` + `.mli`

```ocaml
type span = { start : int; len : int; attr : Grid.attr }
  (** Byte range over the [text] of a line. *)

type line = { text : string; spans : span list }
  (** Spans needn't be disjoint or ordered; render applies them in
      list order so later spans overlay earlier ones. *)

val plain  : string -> line
val style  : string -> Grid.attr -> line
val concat : line list -> line
  (** Horizontal concat. Spans on each piece are shifted by the
      cumulative byte length of preceding pieces. *)

val length : line -> int   (** byte length of [text] *)
val width  : line -> int   (** display width *)

(** Wrap each input line to [width]. Continuation segments get
    [hanging] leading spaces. Spans are remapped to the new (segment,
    offset) coordinates, with the hanging-indent pad emitting no
    spans. *)
val wrap : ?hanging:int -> int -> line list -> line list

(** Plain-string convenience (for callers producing strings):
    [of_strings ss = List.map plain ss]. *)
val of_strings : string list -> line list

(** Drop spans, return underlying text — for selection extraction
    and click-position computation. *)
val to_string : line -> string
```

Implementation notes:

- `wrap` re-uses the existing per-codepoint logic from
  `View.wrap_lines`, but returns `line` records and remaps spans by
  scanning each source line's spans against the segment's byte range.
- `concat` is just a left fold building one big text buffer and
  shifting spans.

## Type migration

`lib/tab.{ml,mli}`:

```ocaml
type msg_tab = {
  ...
  mutable mt_lines       : Styled.line list;
  mutable mt_lines_cache : Styled.line list;
  ...
}
```

## Plumbing changes

`lib/view.ml`:

- Drop the local `wrap_lines` helper; use `Styled.wrap`.
- `render_text_pane` accepts `Styled.line list`. After `Render.put_str`
  on each wrapped line, iterate its `spans` and `Render.chgat` the
  display columns covered by each span (mirroring how `render_script`
  applies `Highlight.span`).
- `render_goals` produces `Styled.line list` from goals_text by
  splitting on `\n` and calling `Styled.plain`.
- `update_msg_tabs` does the same conversion for Rocq + Build tabs.
- `pane_selection_text` reads `.text` of each cached line.

`lib/editor/geom.ml`:

- `screen_to_pane_pos` reads `(List.nth lines_cache row).text` instead
  of the raw string.

`lib/editor/mouse.ml`, `lib/editor/editor.ml`, `lib/editor/modals.ml`:

- Pass `Styled.line list` through where `mt_lines_cache` is read.
  Most callers feed it to `pane_selection_text`, which already takes
  the cache — its signature becomes
  `Tab.pane_selection -> Styled.line list -> string option`.

`lib/build_errors.ml`:

- `render_errors_tab` already returns `string list`. Have it return
  `Styled.line list` (still all `Styled.plain` — coloring comes in a
  follow-up). Update its `.mli`.

## Wrap correctness

The trickiest part is span re-mapping inside `Styled.wrap`. Algorithm
per source line:

1. If the source `text`'s display width fits in `avail`, emit one
   segment with the original spans unchanged.
2. Otherwise, walk codepoints to find segment byte boundaries
   `[b0=0, b1, b2, ...]` exactly as the current `View.wrap_lines`
   does.
3. For segment `k` covering bytes `[b_k, b_{k+1})`:
   - Take each source span `{ start; len; attr }` and clamp it to
     the segment range: `s' = max(start, b_k) - b_k`, `e' = min(start
     + len, b_{k+1}) - b_k`.
   - If `e' > s'`, add `{ start = s' + pad_len; len = e' - s'; attr }`
     to the segment, where `pad_len = String.length pad` for `k > 0`,
     else 0.
4. Continuation segments emit `pad ^ sub` as their text; the pad
   itself carries no spans.

## Out of scope (follow-ups)

- Coloring the Errors tab (severity glyph, path, active-entry header).
- Pp tags → spans on Rocq messages and goals.
- Coloring of selection text within spans (selection's `chgat`
  composes with the span's already-applied attr — should "just work"
  in a terminal, but worth eyeballing).

## Test plan

- `dune build`, `dune runtest`, `dune build @e2e` — all green; behavior
  unchanged.
- Manual: open a project, trigger a build with errors. Confirm Rocq tab,
  Build tab, Errors tab still render identically. Selection-copy from
  any pane still produces the same text. Mouse click positioning still
  works on Errors-tab rows (jump to file). F9 cycle still works.
