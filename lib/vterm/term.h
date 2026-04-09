#ifndef TERM_H
#define TERM_H

#if !defined(MEM_H) || !defined(SYSBUF_H)
#warning "term.h" requires "mem.h" and "sysbuf.h"
#endif

#define ATTRB_BD 0x01u
#define ATTRB_UL 0x02u
#define ATTRB_BL 0x04u
#define ATTRB_IN 0x08u
#define ATTRB_DM 0x10u

#define ENC_ATTRB  0x00u
#define ENC_CLR_16 0x01u
#define ENC_FG_256 0x02u
#define ENC_BG_256 0x03u
#define ENC_FG_24  0x04u
#define ENC_BG_24  0x05u
#define ENC_NL     0x06u
#define ENC_TAB    0x07u

#define DEFAULT_GLYPH 0x20u
#define DEFAULT_COLOR 0x09u
#define SAME_COLOR    0x08u


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

struct gr { uint32 fg, bg; };
/* Graphic Rendition

   fg : bit structure is
        0 ATTRS MD  RRRR RRRR  GGGG GGGG  BBBB BBBB

        here MD is 2 bits to specify color mode
          0 - 16 color  (actually 0-7, 9 for default)
          1 - 256 color
          2 - 24-bit color
        
        ATTR is any combination of ATTRB_ flags
        
        (fg & 0x00ffffffu) is the actual foreground color,
          in the appropriate range

   bg : highest 6 bits stores char width, but only when part of a cell
*/

#define GR_CLR_MASK   0x00ffffffu
#define GR_MD_256     0x01000000u
#define GR_MD_24      0x02000000u
#define GR_MD_MASK    0x03000000u
#define GR_MD_CLR_MASK (GR_MD_MASK|GR_CLR_MASK)
#define GR_ATTRB_MASK 0x7c000000u
#define GR_W_MASK     0xfc000000u
#define GR_MD_BITS 24
#define GR_ATTRB_BITS 26

#define gr_fg_mode(g) ( ((g).fg & GR_MD_MASK)    >> GR_MD_BITS ) 
#define gr_bg_mode(g) ( ((g).bg & GR_MD_MASK)    >> GR_MD_BITS ) 
#define gr_attrb(g)   ( ((g).fg & GR_ATTRB_MASK) >> GR_ATTRB_BITS )
#define gr_fg(g)      ( (g).fg & GR_CLR_MASK ) 
#define gr_bg(g)      ( (g).bg & GR_CLR_MASK )
#define gr_fg_full(g)      ( (g).fg & GR_MD_CLR_MASK ) 
#define gr_bg_full(g)      ( (g).bg & GR_MD_CLR_MASK )

#define set_gr_attrb(g,at) ((g).fg = ((g).fg & GR_MD_CLR_MASK) \
                                   | (((uint32)at) & 0x1fu) << GR_ATTRB_BITS)
#define add_gr_attrb(g,at) ((g).fg |=  ((((uint32)at) & 0x1fu)<<GR_ATTRB_BITS))
#define del_gr_attrb(g,at) ((g).fg &= ~((((uint32)at) & 0x1fu)<<GR_ATTRB_BITS))

#define default_gr_ilzr { DEFAULT_COLOR, DEFAULT_COLOR }
#define default_gr_w1_ilzr { DEFAULT_COLOR, DEFAULT_COLOR \
                                            | (((uint32)1)<<GR_ATTRB_BITS) }
#define gr_ne(a,b) ( ((a).fg!=(b).fg) | gr_bg_full(a) != gr_bg_full(b) )

static const struct gr default_gr = default_gr_ilzr;
static const struct gr default_gr_w1 = default_gr_w1_ilzr;

struct cell { uint32 code; struct gr gr; };

#define cell_w(c) (((c).gr.bg & GR_W_MASK) >> 26)
#define set_cell_w(c,w) ((c).gr.bg = ((c).gr.bg & GR_MD_CLR_MASK) \
                                   | ((w) & 0x3fu) << 26) 

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

#define is_gr_encoding(ch) ( (ch)<=ENC_BG_24 )

/* precondition: is_gr_encoding(*in);
   updates gr, returns length of encoding */
static unsigned gr_decode(
  struct gr *restrict const gr, 
  const uchar *restrict const in)
{
  const uint32 at = (gr->fg & ~GR_MD_CLR_MASK);
  const uint32 c256 = GR_MD_256 | in[1];
  const uint32 c24  = GR_MD_24 | (uint32)in[1]<<16 | (uint32)in[2]<<8 | in[3];
  switch(in[0]) {
  case ENC_ATTRB:  set_gr_attrb(*gr,in[1]); return 2;
  case ENC_CLR_16:
    if( (in[1]&0x0fu) != SAME_COLOR    ) gr->fg = at | (in[1]&0x0fu)   ;
    if( (in[1]&0xf0u) != SAME_COLOR<<4 ) gr->bg =      (in[1]&0xf0u)>>4;
    return 2;
  case ENC_FG_256: gr->fg = at | c256; return 2;
  case ENC_BG_256: gr->bg =      c256; return 2;
  case ENC_FG_24:  gr->fg = at | c24;  return 4;
  case ENC_BG_24:  gr->bg =      c24;  return 4;
  default: return 0;
  }
}

void term_init(struct term *restrict const t, unsigned blim, unsigned elim);
void term_done(struct term *restrict const t);
void term_resize(struct term *restrict const t,
                 unsigned short w, unsigned short h);
void term_proc(
  struct term *restrict const t,
  const uchar *restrict start,
  const uchar *restrict const end);

#endif
