#ifndef TERM_H
#define TERM_H

#if !defined(MEM_H) || !defined(SYSBUF_H)
#warning "term.h" requires "mem.h" and "sysbuf.h"
#endif

/*----------------------------------------------------------------------------
  Graphic Rendition
  ----------------------------------------------------------------------------

  struct gr has four 32-bit words: three color words (fg, bg, ul) and one
  attribute word `a`.

  Color word layout (same for fg, bg, ul):
    bits  0..23  color value (16-color index, 256-color index, or RGB)
    bits 24..25  mode:
                   00 = default        (value bits unused, conventionally 0)
                   01 = 16-color       (value 0..15)
                   10 = 256-color      (value 0..255)
                   11 = 24-bit RGB     (value RGB)
    bits 26..31  unused

    Default state for a color word is the entire word = 0 (mode = default).
    DEFAULT_COLOR is a name for that sentinel.

    16-color mode addresses all 16 palette entries directly (the SGR 30..37
    block plus the xterm 90..97 bright block). The bright colors are NOT
    derived from intensity — they are first-class colors here.

    ul has no 16-color SGR (SGR 58 takes only :5: or :2:), so ul never uses
    mode 11; default / 256-color / 24-bit only.

  Attribute word `a` layout:
    bit   0      bold
    bits  1..2   italic_style    (0 normal, 1 italic, 2 Fraktur)
    bits  3..5   underline_style (0 none, 1 single, 2 double,
                                  3 curly, 4 dotted, 5 dashed)
    bit   6      inverse
    bit   7      strikethrough
    bit   8      faint
    bit   9      conceal
    bit  10      overline
    bit  11      spacing
    bits 12..13  blink           (0 none, 1 slow, 2 rapid)
    bits 14..15  frame           (0 none, 1 framed, 2 encircled)
    bits 16..17  script          (0 none, 1 super, 2 sub)
    bits 18..25  font            (0 primary; 1..9 xterm alt; 10..255 ext via SGR 10:n)
    ----- bits 0..25 above match the half-buffer wire format -----
    bits 26..29  width           (0..8 per-cell metadata, in-memory only)
    bits 30..31  unused

  See doc/sgr-plan.md for the full rationale. */

#define GR_CLR_MASK    0x00ffffffu
#define GR_MD_MASK     0x03000000u
#define GR_MD_16       0x01000000u
#define GR_MD_256      0x02000000u
#define GR_MD_24       0x03000000u
#define GR_MD_CLR_MASK (GR_MD_MASK|GR_CLR_MASK)
#define GR_MD_BITS     24

#define DEFAULT_GLYPH 0x20u
#define DEFAULT_COLOR 0u    /* "default" color word: mode=00, value=0 */

#define A_BOLD          0
#define A_ITALIC        1
#define A_UNDERLINE     3
#define A_INVERSE       6
#define A_STRIKETHROUGH 7
#define A_FAINT         8
#define A_CONCEAL       9
#define A_OVERLINE      10
#define A_SPACING       11
#define A_BLINK         12
#define A_FRAME         14
#define A_SCRIPT        16
#define A_FONT          18
#define A_WIDTH         26

#define A_BOLD_MASK          (1u  << A_BOLD)
#define A_ITALIC_MASK        (3u  << A_ITALIC)
#define A_UNDERLINE_MASK     (7u  << A_UNDERLINE)
#define A_INVERSE_MASK       (1u  << A_INVERSE)
#define A_STRIKETHROUGH_MASK (1u  << A_STRIKETHROUGH)
#define A_FAINT_MASK         (1u  << A_FAINT)
#define A_CONCEAL_MASK       (1u  << A_CONCEAL)
#define A_OVERLINE_MASK      (1u  << A_OVERLINE)
#define A_SPACING_MASK       (1u  << A_SPACING)
#define A_BLINK_MASK         (3u  << A_BLINK)
#define A_FRAME_MASK         (3u  << A_FRAME)
#define A_SCRIPT_MASK        (3u  << A_SCRIPT)
#define A_FONT_MASK          (0xffu << A_FONT)
#define A_WIDTH_MASK         (15u   << A_WIDTH)

#define A_WIRE_MASK  0x03ffffffu  /* bits  0..25  wire-format attribute bits */
#define A_SHORT_MASK 0x000000ffu  /* bits  0..7   ENC_ATTRB  payload         */
#define A_MID_MASK   0x0000ffffu  /* bits  0..15  ENC_ATTRB2 payload         */
#define A_FULL_MASK  0x003fffffu  /* bits  0..21  ENC_ATTRB3 payload         */

#define a_get(a,N)   ( ((a) & A_##N##_MASK) >> A_##N )
#define a_set(a,N,v) ( (a) = ((a) & ~A_##N##_MASK) | ((uint32)(v) << A_##N) )

struct gr { uint32 fg, bg, ul, a; };

#define default_gr_ilzr    { 0, 0, 0, 0 }
#define default_gr_w1_ilzr { 0, 0, 0, (uint32)1 << A_WIDTH }

static const struct gr default_gr    = default_gr_ilzr;
static const struct gr default_gr_w1 = default_gr_w1_ilzr;

/* Compare two gr ignoring cell-width bits (which are per-cell, not part of
   rendition state). */
#define gr_ne(x,y) ( ((x).fg != (y).fg)               \
                   | ((x).bg != (y).bg)               \
                   | ((x).ul != (y).ul)               \
                   | ((((x).a ^ (y).a) & A_WIRE_MASK) != 0) )

struct cell { uint32 code; struct gr gr; };

#define cell_w(c)       a_get((c).gr.a, WIDTH)
#define set_cell_w(c,w) a_set((c).gr.a, WIDTH, (w))

/*----------------------------------------------------------------------------
  Cluster cells

  A cell whose `code` field has CLUSTER_BIT set carries a cluster table
  index in its low bits (masked by CLUSTER_INDEX_MASK) instead of a
  literal codepoint. The cluster table (cluster.c) holds the codepoint
  sequence for the cluster.

  CLUSTER_NARROW_BIT encodes width: clear = width 2 (the common case —
  flags, ZWJ emoji, keycaps, skin-tone, VS-16 emoji), set = width 1
  (rare VS-15 forced text presentation).

  Cluster cells form atomically at the parser layer (see term.c). Wrap
  and selection treat them as ordinary single cells; the renderer
  dispatches on CLUSTER_BIT to look up the sequence and hand it to
  shaping. See doc/cluster-cell-plan.md. */

#define CLUSTER_BIT         0x80000000u
#define CLUSTER_NARROW_BIT  0x40000000u
#define CLUSTER_INDEX_MASK  0x3fffffffu
#define is_cluster(code)    ((code) & CLUSTER_BIT)
#define cluster_index(code) ((code) & CLUSTER_INDEX_MASK)

/*----------------------------------------------------------------------------
  Half-buffer encoding tokens

  ENC_ATTRB / ENC_ATTRB2 / ENC_ATTRB3 / ENC_ATTRB4 each replace a different
  number of low attribute-word bits, preserving the rest. Encoder picks the
  smallest that covers all changed bits.

  fg, bg each have four possible new states (default / 16 / 256 / 24-bit),
  so each gets four tokens. ul has three states (no 16-color form for SGR 58).

  ENC_CLR_16 is the packed-pair shortcut: both fg AND bg change to 16-color
  values in the same step. Encoder is free to emit two separate ENC_FG_16 +
  ENC_BG_16 instead; the packed form just saves 2 bytes when applicable.

  See doc/sgr-plan.md "Proposed half-buffer encoding" for the wire format. */

#define ENC_ATTRB    0u  /* +1 byte: low 8 bits  (SHORT)                  */
#define ENC_ATTRB2   1u  /* +2 bytes: low 16 bits (MID)                   */
#define ENC_ATTRB3   2u  /* +3 bytes: low 22 bits (FULL)                  */
#define ENC_CLR_16   3u  /* +1 byte: packed 4-bit fg + 4-bit bg (16-clr)  */
#define ENC_FG_DEF   4u  /* no payload: fg → default                      */
#define ENC_FG_16    5u  /* +1 byte: fg 16-color (low 4 bits)             */
#define ENC_FG_256   6u  /* +1 byte: fg 256-color index                   */
#define ENC_FG_24    7u  /* +3 bytes: fg RGB                              */
#define ENC_BG_DEF   8u  /* no payload: bg → default                      */
#define ENC_BG_16    9u  /* +1 byte: bg 16-color                          */
#define ENC_BG_256  10u  /* +1 byte: bg 256-color                         */
#define ENC_BG_24   11u  /* +3 bytes: bg RGB                              */
#define ENC_UL_DEF  12u  /* no payload: ul → default                      */
#define ENC_UL_256  13u  /* +1 byte: ul 256-color                         */
#define ENC_UL_24   14u  /* +3 bytes: ul RGB                              */
#define ENC_NL      15u  /* no payload: end of line                       */
#define ENC_TAB     16u  /* no payload: tab cell                          */
#define ENC_ATTRB4  17u  /* +4 bytes: low 26 bits (WIRE — includes 8-bit font slot) */
#define ENC_CLUSTER_REF 18u  /* +varint: cluster table index                  */

#define MODE_APP_KEYPAD   0x01u
#define MODE_APP_CURSOR   0x02u
#define MODE_META         0x04u
#define MODE_ORIGIN       0x08u
#define MODE_SHOW_CURSOR  0x10u
#define MODE_INSERT       0x20u

#define MOUSE_MODE_OFF  0
#define MOUSE_MODE_X10  1   /* DECSET 9    */
#define MOUSE_MODE_NORM 2   /* DECSET 1000 */
#define MOUSE_MODE_BTN  3   /* DECSET 1002 */
#define MOUSE_MODE_ANY  4   /* DECSET 1003 */

#define MOUSE_SGR        0x01u  /* DECSET 1006 — SGR encoding    */
#define MOUSE_FOCUS      0x02u  /* DECSET 1004 — focus reporting  */
#define MOUSE_ALT_SCROLL 0x04u  /* DECSET 1007 — alternate scroll */

#define MAX_ESCAPE      1023

#ifndef UTF_8_H
typedef unsigned char uchar;
struct utf8_state { uchar c[4]; int n; };
#endif

/* Varint (LEB128) for cluster indices in the encoded stream. Low 7 bits per
   byte; continuation bit in MSB. Index 0..127 fits in 1 byte, etc. */
static inline unsigned varint_count(unsigned x)
{
  unsigned n = 1;
  while(x >>= 7) ++n;
  return n;
}
static inline uchar *varint_encode(uchar *restrict out, unsigned x)
{
  while(x >= 0x80u) *out++ = (uchar)((x & 0x7fu) | 0x80u), x >>= 7;
  *out++ = (uchar)(x & 0x7fu);
  return out;
}
static inline unsigned varint_decode(
  const uchar *restrict in, unsigned *restrict consumed)
{
  unsigned x = 0, shift = 0, n = 0;
  for(;;) {
    uchar b = in[n++];
    x |= (unsigned)(b & 0x7fu) << shift;
    if(!(b & 0x80u)) break;
    shift += 7;
  }
  *consumed = n;
  return x;
}

struct line {
  struct array /* of cell */ beg; /* normal order, known tab widths */
  struct array /* of cell */ end; /* reverse order, unknown tab widths */
  unsigned col;
  struct gr nl_gr; /* the graphic rendition of the final new line,
                      which determines the background color from the end
                      of the line to the edge of the screen */
};
struct line_data { unsigned off; };
struct half_buffer {
  struct sysbuf /* of uchar            */ data;
  struct sysbuf /* of struct line_data */ lines;
  unsigned base; /* actual offsets into data are (lines[i].off-base) */
  unsigned limit;
};
struct term_buffer {
  struct half_buffer beg; /* normal  order */
  struct half_buffer end; /* reverse order */
};
struct rel_cursor { unsigned row, col; struct gr gr; };
struct abs_cursor { unsigned row, col; struct gr gr; };
struct term_screen {
  struct term_buffer buf;
  int line_row;
  unsigned cursor_row;   /* absolute screen row */
  unsigned cursor_col;
  struct gr cursor_gr;
  struct abs_cursor saved_cursor;
  uchar mode, saved_mode;
  char G[4], linedraw, curG;
  unsigned short w, h;
};
struct term {
  unsigned short w, h, mt, mb;
  struct term_buffer buf;
  struct array /* of struct line */ margin;
  int line_row; /* margin [0], always present, is not in the margin,
                   but rather, the line in buf between buf.beg and buf.end,
                   and located at mt + line_row on (or off) the screen */
  struct rel_cursor cursor;
  struct abs_cursor saved_cursor;
  uchar mode, saved_mode;
  char G[4], linedraw, curG;
  uchar name_change, name[MAX_ESCAPE];
  uchar feedback_buffer[MAX_ESCAPE];
  unsigned feedback_len;
  uchar state; buffer escape_buf;
  unsigned escape_escape;
  struct utf8_state utf8_state;
  uchar cluster_state;   /* CPS_* — cluster parser state (see cluster.h)
                            survives across term_proc calls like utf8_state */
  /* kitty keyboard protocol */
  #define KITTY_KB_STACK_MAX 8
  uchar kitty_kb_flags;
  uchar kitty_kb_stack[KITTY_KB_STACK_MAX];
  uchar kitty_kb_stack_n;
  /* mouse */
  uchar mouse_mode;    /* MOUSE_MODE_* */
  uchar mouse_flags;   /* MOUSE_SGR | MOUSE_FOCUS | MOUSE_ALT_SCROLL */
  uchar mouse_change;  /* set when mouse_mode changes; cleared by caller */
  uchar bracketed_paste;
  /* OSC 52 clipboard set */
  uchar osc52_sel;    /* 0=primary, 1=clipboard */
  uchar *osc52_data;  /* decoded data (malloc'd), NULL if none */
  unsigned osc52_len;
  /* OSC 1547 font slots — heap-owned NUL-terminated pattern strings
     (or NULL for unbound). Slot 0 is reserved (always NULL): it represents
     "no override / use codepoint dispatch via fontmap". font_slot_dirty
     is a 256-bit bitmap; bit n set means client should re-resolve slot n. */
  uchar *font_slot[256];
  uint32 font_slot_dirty[8];
  /* alternate screen */
  struct term_screen primary;
  uchar alt_screen;
};

#define CURSOR_IN_MARGIN(t) (( (t).cursor.row>>(UINT_BITS-1) )&1u)

static unsigned half_buffer_line_off(
  const struct half_buffer* restrict  hb, unsigned i)
{
  const struct line_data *ld = hb->lines.ptr;
  return ld[i].off - hb->base;
}

#define is_gr_encoding(ch) ( (ch)<=ENC_UL_24 || (ch)==ENC_ATTRB4 )

/* precondition: is_gr_encoding(*in);
   updates gr, returns length of encoding.
   C256 reads in[1]; C24 reads in[1..3] — used only in cases that have
   that many bytes of payload, so no past-the-end reads. */
#define gr_decode_C256 (GR_MD_256 | in[1])
#define gr_decode_C24  (GR_MD_24 | (uint32)in[1]<<16 | (uint32)in[2]<<8 | in[3])
static unsigned gr_decode(
  struct gr *restrict const gr,
  const uchar *restrict const in)
{
  switch(in[0]) {
  case ENC_ATTRB:
    gr->a = (gr->a & ~A_SHORT_MASK) | in[1];
    return 2;
  case ENC_ATTRB2:
    gr->a = (gr->a & ~A_MID_MASK)
          |  (uint32)in[1]
          | ((uint32)in[2] << 8);
    return 3;
  case ENC_ATTRB3:
    gr->a = (gr->a & ~A_FULL_MASK)
          |  (uint32)in[1]
          | ((uint32)in[2] << 8)
          | ((uint32)(in[3] & 0x3fu) << 16);
    return 4;
  case ENC_ATTRB4:
    gr->a = (gr->a & ~A_WIRE_MASK)
          |  (uint32)in[1]
          | ((uint32)in[2] <<  8)
          | ((uint32)in[3] << 16)
          | ((uint32)(in[4] & 0x03u) << 24);
    return 5;
  case ENC_CLR_16:
    gr->fg = GR_MD_16 | ((in[1] & 0xf0u) >> 4);
    gr->bg = GR_MD_16 |  (in[1] & 0x0fu);
    return 2;
  case ENC_FG_DEF: gr->fg = 0;                          return 1;
  case ENC_FG_16:  gr->fg = GR_MD_16 | (in[1] & 0x0fu); return 2;
  case ENC_FG_256: gr->fg = gr_decode_C256;             return 2;
  case ENC_FG_24:  gr->fg = gr_decode_C24;              return 4;
  case ENC_BG_DEF: gr->bg = 0;                          return 1;
  case ENC_BG_16:  gr->bg = GR_MD_16 | (in[1] & 0x0fu); return 2;
  case ENC_BG_256: gr->bg = gr_decode_C256;             return 2;
  case ENC_BG_24:  gr->bg = gr_decode_C24;              return 4;
  case ENC_UL_DEF: gr->ul = 0;                          return 1;
  case ENC_UL_256: gr->ul = gr_decode_C256;             return 2;
  case ENC_UL_24:  gr->ul = gr_decode_C24;              return 4;
  default: return 0;
  }
}
#undef gr_decode_C256
#undef gr_decode_C24

void term_init(struct term *restrict const t, unsigned blim, unsigned elim);
void term_done(struct term *restrict const t);
void term_resize(struct term *restrict const t,
                 unsigned short w, unsigned short h);
void term_proc(
  struct term *restrict const t,
  const uchar *restrict start,
  const uchar *restrict const end);

/* Drain the next dirty font slot index. Returns the slot index (1..255) and
   clears its dirty bit, or 0 when no dirty slots remain. Caller reads
   t->font_slot[i] for the new pattern (NULL = unbound). */
unsigned term_drain_font_slot(struct term *restrict t);

#endif
