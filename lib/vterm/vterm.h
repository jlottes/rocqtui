#ifndef VTERM_H
#define VTERM_H

#if !defined(TERM_H) || !defined(WRAP_H) || !defined(SEL_H)
#warning "vterm.h" requires "term.h", "wrap.h", and "sel.h"
#endif

struct vterm_row_sel_range { unsigned x0, x1; };

struct vterm_cell {
  uint32 code;       /* Unicode codepoint, ENC_TAB (0x16), or '\n' */
  struct gr gr;
  unsigned col;
  unsigned short x, w;
  uchar selected;    /* 1 if within selection */
  uchar cursor;      /* 1 if part of cursor */
};

struct cursor_pos {
  int on_screen;
  int x,y, w;
  uint32 attrb;     /* gr.a — full 22-bit rendition state plus width bits */
  int mode;
  union {
    const struct cell *cell;
    const uchar *c;
  } pos;
  unsigned max;
  int step;
};

struct vterm {
  struct term t;
  struct wrap_breaks wb;
  struct scroll_pos scroll;
  unsigned wrap_mode;
  int scroll_dw, scroll_dh; /* display size delta when scrolled.
    scroll_dh affects row count. scroll_dw currently only affects
    the trailing blank width; wrap width is always t->w.
    TODO: plumb scroll_dw through wrap_update for re-wrap support. */
  struct {
    int on; struct scroll_pos b,e;
    int dirty; struct sel_desc desc;
  } sel;
  unsigned vw, vh;
  struct {
    int dirty;
    struct array /* of layout_row */ row;
    struct cursor_pos cursor_pos;
  } layout;
  struct {
    int dirty;
    struct array /* of vterm_row_sel_range */ row;
  } layout_sel;
  struct array /* of vterm_cell */ cell_buffer;
};


/* init / cleanup */

void vterm_init(
  struct vterm *restrict const v,
  unsigned backlog, unsigned fwdlog,
  unsigned short w, unsigned short h,
  int scroll_dw, int scroll_dh,
  unsigned wrap_mode
);

void vterm_done(struct vterm *restrict v);

/* processing */

struct vterm_out {
  const uchar *feedback;
  unsigned feedback_len;
  const uchar *name;
  uchar mouse_changed;
  uchar *clipboard;          /* caller takes ownership (must free) */
  unsigned clipboard_len;
};

struct vterm_out vterm_sync(struct vterm *v);

/* Drain the next dirty font slot (1..255). Returns 0 when none remain.
   Caller then reads vterm_font_slot(v, n) to get the new pattern string
   (NULL = unbound). Mirrors the OSC 1547 binding push model. */
unsigned vterm_drain_font_slot(struct vterm *v);
const uchar *vterm_font_slot(const struct vterm *v, unsigned i);

void vterm_resize(struct vterm *v, unsigned short w, unsigned short h);
int vterm_set_wrap_mode(struct vterm *v, unsigned wrap_mode);

/* display */

unsigned vterm_prepare_rows(struct vterm *v);
struct array *vterm_get_row(struct vterm *v, unsigned y);

struct scroll_pos vterm_hit_test(struct vterm *v,
  unsigned display_row, unsigned display_col);

/* selection */

void vterm_sel_start(struct vterm *v, struct scroll_pos pos);
void vterm_sel_extend(struct vterm *v, struct scroll_pos pos);
void vterm_sel_word(struct vterm *v, struct scroll_pos pos);
uchar *vterm_sel_text(struct vterm *v);

/* scroll */
int vterm_scroll(struct vterm *v, int n);
int vterm_scroll_to_end(struct vterm *v, int top);

#endif

/*
  Notes:

    model is user can read struct members but not set them
*/

