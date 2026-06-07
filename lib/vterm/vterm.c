#define _XOPEN_SOURCE 600
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/types.h>
#include "c99.h"
#include "mem.h"
#include "utf-8.h"
#include "sysbuf.h"
#include "term.h"
#include "char_width.h"
#include "wrap.h"
#include "sel.h"
#include "vterm.h"

/* --- layout --- */

struct layout_state { struct gr gr; unsigned col, subline_col; };

/* vterm_cell analog of term.h's cluster_widen_leader. Walks back in
   cell_buffer to the cluster's leading cell and widens it from 1 to 2;
   the layout cursor (col, subline_col) tracks the extra cell. */
static void vterm_widen_leader(struct vterm *v, unsigned line_start,
                               struct layout_state *st)
{
  struct vterm_cell *cells = array_data(struct vterm_cell, &v->cell_buffer);
  unsigned k = v->cell_buffer.n;
  while(k > line_start) {
    --k;
    if(cells[k].w > 0) {
      if(cells[k].w == 1)
        cells[k].w = 2, ++st->col, ++st->subline_col;
      return;
    }
  }
}

struct layout_row {
  int r, margin; unsigned sub, col0, col1;
  struct layout_state st, st_end;
  const uchar *enc_start; unsigned enc_max;
  const struct cell *fwd_cell; unsigned fwd_n;
  const struct cell *bwd_cell; unsigned bwd_n;
};

/* struct vterm_row_sel_range defined in vterm.h */

static struct layout_state layout_cells(
  struct vterm *restrict const v,
  const struct cell *restrict cell, const int step, unsigned n,
  struct layout_state st,
  unsigned y, int cursor)
{
  const int xmax = v->t.w; // TODO: use scroll_dw
  struct gr gr; unsigned col=st.col; int x=st.subline_col;
  if(!n) return st;
  while(n--) {
    int w = char_width(cell->code,col);
    gr=cell->gr;
    if(w && x>=xmax) break;
    if(cursor&&v->t.cursor.col>=col&&v->t.cursor.col<col+(unsigned)w) {
      struct cursor_pos *restrict const cp = &v->layout.cursor_pos;
      cursor=0, cp->on_screen=1, cp->attrb=cell->gr.a,
      cp->x=x, cp->y=y, cp->w=w,
      cp->mode=cell->code==ENC_TAB?2:0, cp->pos.cell = cell,
      cp->max = n+1, cp->step=step;
    }
    col+=w, x+=w, cell+=step;
  }
  st.gr=gr, st.col=col, st.subline_col=x;
  return st;
}


static struct layout_state layout_enc_cells(
  struct vterm *restrict const v,
  const uchar *restrict const start, unsigned max,
  struct layout_state st,
  unsigned y, int cursor)
{
  const unsigned xmax = v->vw;
  unsigned x=0, w;
  struct read_utf8_fast r = { 0, 0 };
  if(!max || *start==ENC_NL) return st;
  for(;;) {
    uchar c = start[r.i]; unsigned old_i=r.i;
    if(c==ENC_NL||r.i>=max) break;
    else if(is_gr_encoding(c))
      r.i += gr_decode(&st.gr,start+r.i);
    else {
      r=read_utf8_fast(start,r.i), w=char_width(r.c,st.col);
      if(w && x>=xmax) break;
      if(cursor&&v->t.cursor.col>=st.col&&v->t.cursor.col< st.col+w) {
        struct cursor_pos *restrict const cp = &v->layout.cursor_pos;
        cursor=0, cp->on_screen=1, cp->attrb=st.gr.a,
        cp->x=x, cp->y=y, cp->w=w,
        cp->mode=(r.c==ENC_TAB?2:1),
        cp->pos.c = start+old_i, cp->max = max-old_i;
      }
      st.col+=w, x+=w;
    }
  }
  st.subline_col=x;
  return st;
}

static unsigned layout_blank(
  struct vterm *restrict const v, struct gr gr, unsigned col,
  unsigned x, unsigned y, int cursor)
{
  if(x<v->vw) {
    if(cursor && v->t.cursor.col>=col) {
      struct cursor_pos *restrict const cp = &v->layout.cursor_pos;
      cp->on_screen = 1,
      cp->x=x+(v->t.cursor.col-col),cp->y=y,cp->w=1,cp->mode=2;
      if(cp->x>(int)v->vw) cp->on_screen=0;
    }
  }
  return y+1;
}

static unsigned layout_tline(
  struct vterm *restrict const v,
  const struct line *restrict const line,
  const struct wrap_break *restrict const brk, unsigned nsub,
  unsigned sub, unsigned submax, unsigned y,
  int cursor, int margin)
{
  const struct cell *restrict const bbase = line->beg.ptr;
  const struct cell *restrict const eend  = line->end.ptr
    ? (const struct cell *)line->end.ptr + line->end.n : 0;
  const unsigned bn = line->beg.n, cn=bn+line->end.n, vh=v->vh;
  struct layout_row *restrict l = array_data(struct layout_row, &v->layout.row);
  for(;sub<submax && y<vh;++sub,++y) {
    struct layout_state st={default_gr_ilzr,0,0}; unsigned b=0,e;
    if(sub!=0) b=brk[sub-1].off, st.col=brk[sub-1].col;
    e = sub==nsub-1 ? cn : brk[sub].off;
    l[y].margin = margin;
    l[y].st = st;
    if(e>b && b<bn) {
      l[y].fwd_cell=bbase+b, l[y].fwd_n=(e>bn?bn:e)-b;
      if(e>bn) l[y].bwd_cell=eend-1, l[y].bwd_n=e-bn;
    } else if(e>b)
      l[y].bwd_cell=eend-1-(b-bn), l[y].bwd_n=e-b;
    if(l[y].fwd_cell)
      st=layout_cells(v,l[y].fwd_cell, 1,l[y].fwd_n,st,y,cursor);
    if(l[y].bwd_cell)
      st=layout_cells(v,l[y].bwd_cell,-1,l[y].bwd_n,st,y,cursor);
    if(sub==nsub-1) st.gr = line->nl_gr;
    l[y].st_end = st;
    layout_blank(v,st.gr,st.col,st.subline_col,y,cursor);
  }
  return y;
}

static unsigned layout_eline(
  struct vterm *restrict const v,
  const uchar *restrict data, unsigned off, unsigned max,
  const struct wrap_break *restrict const brk, unsigned nsub,
  unsigned sub, unsigned submax,
  unsigned y, int cursor)
{
  const unsigned vh = v->vh;
  struct layout_row *restrict l = array_data(struct layout_row, &v->layout.row);
  for(;sub<submax && y<vh;++sub,++y) {
    struct layout_state st = { default_gr, 0, 0 };
    unsigned b, e = sub==nsub-1 ? max : brk[sub].off;
    if(sub==0) b=off, st.col=0;
          else b=brk[sub-1].off, st.col=brk[sub-1].col,
                 st.gr = brk[sub-1].gr;
    l[y].st=st;
    l[y].enc_start=data+b, l[y].enc_max=e-b;
    st = layout_enc_cells(v,l[y].enc_start,l[y].enc_max,st,y, cursor);
    l[y].st_end=st;
    layout_blank(v,st.gr,st.col,st.subline_col,y,cursor);
  }
  return y;
}

static inline unsigned layout_bline(
  struct vterm *restrict const v,
  const struct half_buffer *restrict const hb, int l,
  const struct wrap_break *restrict const brk, unsigned nsub,
  unsigned sub, unsigned submax,
  unsigned y, int cursor)
{
  return layout_eline(v,hb->data.ptr, half_buffer_line_off(hb,l),hb->data.n,
                      brk,nsub,sub,submax, y,cursor);
}

static void layout_sline_nosel(
  struct vterm *restrict const v,
  int r, const struct wrap_break *restrict const brk, unsigned nsub,
  unsigned sub, unsigned submax, unsigned y)
{
  const unsigned vh = v->vh;
  struct layout_row *restrict l = array_data(struct layout_row, &v->layout.row);
  for(;sub<submax && y<vh;++sub,++y) {
    l[y].r = r;
    l[y].sub = sub;
    l[y].col0 = sub==0? 0 : brk[sub-1].col;
    l[y].col1 = sub==nsub-1 ? -1u : brk[sub].col;
  }
}

static unsigned layout_blank_line(
  struct vterm *restrict const v, int r, unsigned y, int cursor
)
{
  struct layout_row *restrict l = array_data(struct layout_row, &v->layout.row) + y;
  struct layout_state st = { default_gr, 0, 0 };
  l->r = r;
  l->st = l->st_end = st;
  return layout_blank(v,st.gr,0,0,y,cursor);
}

unsigned layout_line(
  struct vterm *restrict const v,
  int r, unsigned sub, unsigned submax, unsigned y, int cursor)
{
  const struct wrap_line wl =
    array_data(struct wrap_line,&v->wb.lines)[r-v->wb.dtop.line];
  const struct wrap_break *restrict const brk = wl.nsub==0 ? 0 :
    array_data(struct wrap_break,&v->wb.brks) + wl.brki;
  if(submax==-1u) submax = wl.nsub;
  layout_sline_nosel(v,r,brk,wl.nsub, sub,submax, y);
  if(r==0)
    return layout_tline(v,v->t.margin.ptr,brk,wl.nsub,sub,submax,y,cursor,0);
  else {
    unsigned ar; const struct half_buffer *restrict hb;
    if(r>0) ar= r,hb=&v->t.buf.end;
       else ar=-r,hb=&v->t.buf.beg;
    if(ar>hb->lines.n) return layout_blank_line(v,r,y,cursor);
    else return layout_bline(v,hb,hb->lines.n-ar,
                             brk,wl.nsub,sub,submax, y,cursor);
  }
}

static unsigned layout_mt(
  struct vterm *restrict const v, unsigned y, const unsigned maxy)
{
  int i; for(i=0;i<v->t.mt&&y<maxy;++i)
    y=layout_tline(v,array_data(struct line,&v->t.margin)+1+2*i,
                   0,1,0,1, y, v->t.cursor.row == -(unsigned)(2*i+1), 1);
  return y;
}

static unsigned layout_mb(
  struct vterm *restrict const v, unsigned y, const unsigned maxy)
{
  int i=v->t.mb; for(--i;i>=0&&y<maxy;--i)
    y=layout_tline(v,array_data(struct line,&v->t.margin)+2+2*i,
                   0,1,0,1, y, v->t.cursor.row == -(unsigned)(2*i+2), 1);
  return y;
}


static int add_delta(int x, int dx)
{
  x += dx;
  return x >= 1 ? x : 1;
}

static inline int subline_less(struct subline a, struct subline b)
{
  return a.line<b.line || (a.line==b.line && a.sub<b.sub);
}

static void layout_setup(struct vterm *restrict const v)
{
  const int bot = (int)(v->t.h - (v->t.mt+v->t.mb)) - v->t.line_row;
  const int cursor=!CURSOR_IN_MARGIN(v->t),
            cline =(int)v->t.cursor.row-v->t.line_row;
  struct subline e = subline_less(v->wb.vtop,v->wb.dbot)?v->wb.vtop:v->wb.dbot;
  int r; unsigned sub,y=0, maxy=v->t.h;
  if(v->scroll.line!=-1u) maxy=add_delta(maxy, v->scroll_dh);
  v->vw = v->t.w, v->vh = maxy;  // TODO: handle dw
  struct layout_row *l = array_reserve(struct layout_row, &v->layout.row, maxy);
  memset(l, 0, maxy*sizeof(struct layout_row));
  v->layout.row.n = maxy;
  memset(&v->layout.cursor_pos, 0, sizeof(struct cursor_pos));
  for(r=v->wb.dtop.line,sub=v->wb.dtop.sub;r<e.line;++r)
    y=layout_line(v,r, sub,-1u, y,0), sub=0;
  if(r==e.line&&sub<e.sub)
    y=layout_line(v,r, sub,e.sub, y,0), sub=e.sub;
  y=layout_mt(v,y,maxy);
  for(e=v->wb.dbot;r<e.line;++r)
    y=layout_line(v,r, sub,-1u  , y,cursor&&(r==cline)), sub=0;
  if(r==e.line&&e.sub&&y<maxy)
    y=layout_line(v,r, sub,e.sub, y,cursor&&(r==cline)), sub=e.sub;
  for(;r<bot&&y<maxy;++r)
    y=layout_blank_line(v,r,y,cursor&&(r==cline));
  y=layout_mb(v,y,maxy);
}

static void layout_sel_setup(struct vterm *restrict const v)
{
  unsigned y;
  const unsigned vh = v->vh;
  struct layout_row *restrict const l =
    array_data(struct layout_row, &v->layout.row);
  struct vterm_row_sel_range *restrict const ls =
    array_reserve(struct vterm_row_sel_range, &v->layout_sel.row, vh);
  const struct sel_desc desc = v->sel.desc;
  memset(ls, 0, vh*sizeof(struct vterm_row_sel_range));
  for(y=0;y<vh;y++) {
    const int r = l[y].r; const unsigned col0 = l[y].col0, col1 = l[y].col1;
    unsigned b,e;
    if(l[y].margin) continue;
    if(desc.b.line>r || desc.e.line<r) continue;
    b = desc.b.line==r ? desc.b.pos.col : 0;
    e = desc.e.line==r ? desc.e.pos.col : -1u;
    if(b>col1 || e <=col0) continue;
    ls[y].x0 = col0<b ? b-col0 : 0;
    ls[y].x1 = e<col1 ? e-col0 : ( col1==-1u ? -1u : col1-col0 );
    if(ls[y].x0 >= ls[y].x1) ls[y].x0=ls[y].x1=0;
  }
}


/* --- lazy computations --- */

static void force_wraps(struct vterm *v)
{
  if(!v->wb.dirty) return;
  int sh = add_delta(v->t.h, v->scroll_dh);
  // TODO: plumb modified width here.
  //       consider applying the delta in wrap_update.
  wrap_update(&v->wb, &v->scroll, &v->t, v->wrap_mode, sh);
  v->layout.dirty=1;
}

static void force_sel(struct vterm *v)
{
  if(!v->sel.on || !v->sel.dirty) return;
  v->sel.desc=sel_fix(&v->t,v->sel.b,v->sel.e), v->sel.dirty=0;
  v->layout_sel.dirty=1;
}

static void force_layout(struct vterm *v)
{
  force_wraps(v);
  if(!v->layout.dirty) return;
  layout_setup(v);
  v->layout.dirty=0;
  v->layout_sel.dirty=1;
}

static void force_layout_sel(struct vterm *v)
{
  force_layout(v);
  force_sel(v);
  if(!v->layout_sel.dirty) return;
  layout_sel_setup(v);
  v->layout_sel.dirty=0;
}

/* --- get row --- */

static void append_cell(
  struct vterm *restrict const v,
  const struct vterm_cell cell
)
{
  unsigned n = v->cell_buffer.n++;
  struct vterm_cell *restrict const buf
    = array_reserve(struct vterm_cell, &v->cell_buffer, n+1);
  buf[n] = cell;
}

static struct layout_state append_code(struct vterm *restrict const v,
  uint32 code, struct layout_state st, unsigned short w, unsigned y)
{
  const struct vterm_row_sel_range *restrict const ls
    = array_data(struct vterm_row_sel_range, &v->layout_sel.row) + y;
  struct vterm_cell cell;
  cell.code=code, cell.w=w;
  cell.gr=st.gr, cell.col=st.col, cell.x=st.subline_col;

  unsigned x = st.subline_col;
  cell.selected = x>=ls->x0 && x<ls->x1;

  const struct cursor_pos cp = v->layout.cursor_pos;
  cell.cursor = cp.on_screen && cp.y==(int)y 
    && cp.x>=(int)x && cp.x<(int)v->vw;

  append_cell(v, cell);
  st.col+=w, st.subline_col+=w;
  return st;
}

static void append_blank(struct vterm *restrict const v,
  struct layout_state st, unsigned y)
{
  const struct vterm_row_sel_range *restrict const ls
    = array_data(struct vterm_row_sel_range, &v->layout_sel.row) + y;
  struct vterm_cell cell;
  cell.code='\n', cell.w=0;
  if(st.subline_col < v->vw) cell.w = v->vw-st.subline_col;
  cell.gr=st.gr, cell.col=st.col, cell.x=st.subline_col;

  cell.selected = ls->x1==-1u;

  const struct cursor_pos cp = v->layout.cursor_pos;
  unsigned x = st.subline_col;
  cell.cursor = cp.on_screen && cp.y==(int)y 
    && cp.x>=(int)x && cp.x<(int)v->vw;

  append_cell(v, cell);
}

static struct layout_state append_cells(
  struct vterm *restrict const v,
  const struct cell *restrict cell, const int step, unsigned n,
  struct layout_state st,
  unsigned y)
{
  const unsigned xmax = v->vw;
  if(!n) return st;
  while(n--) {
    /* Use the cell's stored width; proc_graphic / cells_decode already
       forced cluster_cont cells to 0 so we don't double-count them at
       the vterm layout layer. */
    int w = cell_w(*cell);
    st.gr=cell->gr;
    if(w && st.subline_col>=xmax) break;
    st=append_code(v,cell->code,st,w,y);
    cell+=step;
  }
  return st;
}

static void append_tline(struct vterm *restrict const v, unsigned y)
{
  const struct layout_row *restrict const l
    = array_data(struct layout_row, &v->layout.row) + y;
  struct layout_state st = l->st;
  if(l->fwd_cell)
    st=append_cells(v,l->fwd_cell, 1,l->fwd_n,st,y);
  if(l->bwd_cell)
    st=append_cells(v,l->bwd_cell,-1,l->bwd_n,st,y);
  append_blank(v,l->st_end,y);
}

static void append_enc_cells(struct vterm *restrict const v, unsigned y)
{
  const struct layout_row *restrict const l
    = array_data(struct layout_row, &v->layout.row) + y;
  const uchar *restrict const start = l->enc_start;
  const unsigned max = l->enc_max;
  struct layout_state st = l->st;
  const unsigned xmax = v->vw;
  unsigned w;
  struct read_utf8_fast r = { 0, 0 };
  uchar c;
  /* Re-derive cluster_cont per codepoint as we stream the encoded line.
     The wire format doesn't carry the cluster_cont bit (it lives above
     A_WIRE_MASK), and this path bypasses cells_decode entirely. */
  uint32 prev_code = 0;
  int ri_unpaired = 0;
  unsigned line_start = v->cell_buffer.n;
  if(max && *start!=ENC_NL) {
    for(;r.i<max && (c=start[r.i])!=ENC_NL;) {
      if(is_gr_encoding(c))
        r.i += gr_decode(&st.gr,start+r.i);
      else {
        int cont;
        r=read_utf8_fast(start,r.i);
        cont = is_cluster_cont(r.c, prev_code, &ri_unpaired);
        w = cont ? 0 : char_width(r.c,st.col);
        if(w && st.subline_col>=xmax) break;
        /* Mirror proc_graphic / cells_decode by setting CLUSTER_CONT on
           the gr we hand to append_code. The wire format doesn't carry
           the bit; without this step draw_fg_pass sees no cluster_cont
           on cells that came out of scrollback. */
        a_set(st.gr.a, CLUSTER_CONT, cont ? 1 : 0);
        if(cont) vterm_widen_leader(v, line_start, &st);
        st=append_code(v,r.c,st,w,y);
        prev_code = r.c;
      }
    }
  }
  append_blank(v,l->st_end,y);
}

unsigned vterm_prepare_rows(struct vterm *v)
{
  force_layout_sel(v);
  return v->vh;
}

struct array *vterm_get_row(struct vterm *v, unsigned y)
{
  v->cell_buffer.n = 0;
  if(array_data(struct layout_row, &v->layout.row)[y].enc_start)
    append_enc_cells(v, y);
  else
    append_tline(v, y);
  return &v->cell_buffer;
}

/* --- hit test --- */

struct scroll_pos vterm_hit_test(struct vterm *v,
  unsigned display_row, unsigned display_col)
{
  struct scroll_pos out;
  const struct layout_row *l;
  force_layout(v);
  if(display_row >= v->vh) display_row = v->vh ? v->vh-1 : 0;
  l = array_data(struct layout_row, &v->layout.row) + display_row;
  out.line = l->margin ? -1u : l->r + v->t.buf.beg.lines.n;
  out.col = l->col0 + display_col;
  if(out.col > l->st_end.col) out.col = l->st_end.col;
  return out;
}

/* --- init / cleanup --- */

void vterm_init(
  struct vterm *restrict const v,
  unsigned backlog, unsigned fwdlog,
  unsigned short w, unsigned short h,
  int scroll_dw, int scroll_dh,
  unsigned wrap_mode
)
{
  memset(v, 0, sizeof(struct vterm));
  term_init(&v->t, backlog, fwdlog);
  term_resize(&v->t, w, h);
  v->scroll_dw=scroll_dw, v->scroll_dh=scroll_dh;
  v->wrap_mode = wrap_mode;
  v->scroll.line = -1u;
  v->wb.dirty = 1;
}

void vterm_done(struct vterm *restrict const v)
{
  term_done(&v->t);
  array_free(&v->wb.lines);
  array_free(&v->wb.brks);
  array_free(&v->layout.row);
  array_free(&v->layout_sel.row);
  array_free(&v->cell_buffer);
}


/* --- processing --- */

struct vterm_out vterm_sync(struct vterm *v)
{
  struct term *restrict t = &v->t;
  struct vterm_out out;
  memset(&out, 0, sizeof(struct vterm_out));
  v->sel.dirty = v->wb.dirty = 1;
  if(t->feedback_len) {
    out.feedback = t->feedback_buffer;
    out.feedback_len = t->feedback_len;
    t->feedback_len = 0;
  }
  if(t->name_change) {
    out.name = t->name;
    t->name_change = 0;
  }
  if(t->mouse_change) {
    out.mouse_changed = 1;
    t->mouse_change = 0;
  }
  if(t->osc52_data) {
    out.clipboard = t->osc52_data;
    out.clipboard_len = t->osc52_len;
    t->osc52_data = 0;
    t->osc52_len = 0;
  }
  return out;
}

unsigned vterm_drain_font_slot(struct vterm *v)
{
  return term_drain_font_slot(&v->t);
}

const uchar *vterm_font_slot(const struct vterm *v, unsigned i)
{
  return i<256 ? v->t.font_slot[i] : 0;
}

void vterm_resize(struct vterm *v, unsigned short w, unsigned short h)
{
  term_resize(&v->t, w, h);
  v->wb.dirty = 1;
}

int vterm_set_wrap_mode(struct vterm *v, unsigned wrap_mode)
{
  if(v->wrap_mode==wrap_mode) return 0;
  v->wrap_mode = wrap_mode;
  v->wb.dirty = 1;
  return 1;
}

/* --- selection --- */

static int nonempty(struct sel_desc desc)
{
  return desc.b.line != desc.e.line || desc.b.pos.col != desc.e.pos.col;
}

void vterm_sel_start(struct vterm *v, struct scroll_pos pos)
{
  v->sel.on = 0;
  v->sel.b = v->sel.e = pos;
}

void vterm_sel_extend(struct vterm *v, struct scroll_pos pos)
{
  if(v->sel.b.line==-1u || pos.line==-1u) return;
  v->sel.e = pos;
  v->sel.on = v->sel.dirty = 1;
  force_sel(v);
  v->sel.on = nonempty(v->sel.desc);
}

void vterm_sel_word(struct vterm *v, struct scroll_pos pos)
{
  const int bn = v->t.buf.beg.lines.n;
  if(pos.line==-1u) return;
  v->sel.b.line=-1u;
  v->sel.desc = sel_word(&v->t, (int)pos.line-bn, pos.col+.5f);
  v->sel.on = nonempty(v->sel.desc);
  if(!v->sel.on) return;
  v->sel.dirty=0; v->layout_sel.dirty=1;
  v->sel.e.line=v->sel.b.line= bn + v->sel.desc.b.line;
  v->sel.b.col=v->sel.desc.b.pos.col;
  v->sel.e.col=v->sel.desc.e.pos.col;
}

uchar *vterm_sel_text(struct vterm *v)
{
  force_sel(v);
  if(!v->sel.on) return 0;
  return sel_get(&v->t, v->sel.desc);
}

/* --- scroll --- */

int vterm_scroll(struct vterm *v, int n)
{
  return wrap_scroll(&v->scroll, &v->wb, &v->t, v->wrap_mode, n);
}

int vterm_scroll_to_end(struct vterm *v, int top)
{
  unsigned new_line = (top && !v->t.alt_screen) ? 0 : -1u;
  int dirty = v->scroll.line != new_line || v->scroll.col != 0;
  if(dirty) {
    v->scroll.line = new_line, v->scroll.col = 0;
    v->wb.dirty = 1;
  }
  return dirty;
}
