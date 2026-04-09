#define _XOPEN_SOURCE /* wcwidth */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <sys/types.h>
#include "c99.h"
#include "mem.h"
#include "utf-8.h"
#include "sysbuf.h"
#include "term.h"
#include "char_width.h"
#include "acs.h"

#ifndef TERM_DIAGNOSTICS
#  define TERM_DIAGNOSTICS 0
#endif

#define STATE_NORMAL      0u
#define STATE_ESC         1u
#define STATE_CSI         2u
#define STATE_XTERM       3u
#define STATE_CHAR_SET    4u

#define esc_buf(t)  ((uchar*)(t)->escape_buf.ptr)

#define default_cell { 0x20u, default_gr_w1 }

#define GR_BG_IS_DEF(g) ( gr_eff_bg(g) == DEFAULT_COLOR )

/*----------------------------------------------------------------------------
  Cells
  ----------------------------------------------------------------------------*/

static unsigned cells_col(unsigned col,
                          const struct cell *restrict c, unsigned n, int step)
{
  while(n--) col += c->code==ENC_TAB ? 8-(col&7u) : cell_w(*c), c+=step;
  return col;
}

static uint32 gr_eff_bg(struct gr gr)
{
  if(gr_attrb(gr) & ATTRB_IN) {
    uint32 bg = gr.fg & GR_MD_CLR_MASK ;
    if( (gr.fg & GR_MD_MASK) == 0 ) {
      if( bg == DEFAULT_COLOR )
        bg |= (uint32)ATTRB_IN << GR_ATTRB_BITS;
      else if( gr_attrb(gr) & ATTRB_BD )
        bg |= (uint32)ATTRB_BL << GR_ATTRB_BITS;
    }
    return bg;
  } else {
    uint32 bg = gr.bg & GR_MD_CLR_MASK ;
    if( (gr.bg & GR_MD_MASK) == 0
        && bg != DEFAULT_COLOR
        && (gr_attrb(gr) & ATTRB_BL) )
      bg |= (uint32)ATTRB_BL << GR_ATTRB_BITS;
    return bg;
  }
}

static unsigned gr_encode_bg_count(struct gr old, struct gr new)
{
  uint32 bg = gr_eff_bg(new);
  if(bg==gr_eff_bg(old)) return 0;
  else if((bg & GR_MD_MASK) == 0) {
    return (bg>>GR_ATTRB_BITS) != (gr_attrb(old) & (ATTRB_IN|ATTRB_BL))
           ? 4 : 2;
  } else if(bg & GR_MD_256) return 2;
  else                      return 4;
}

static uchar *gr_encode_bg(uchar *restrict out, struct gr old, struct gr new)
{
  uint32 bg = gr_eff_bg(new);
  if(bg==gr_eff_bg(old)) return out;
  else if((bg & GR_MD_MASK) == 0) {
    uchar at = bg>>GR_ATTRB_BITS;
    if( at != (gr_attrb(old) & (ATTRB_IN|ATTRB_BL)) )
      *out++ = ENC_ATTRB, *out++ = at;
    *out++ = ENC_CLR_16, *out++ = (bg & 0x0fu)<<4 | SAME_COLOR;
  } else if(bg & GR_MD_256)
    *out++ = ENC_BG_256, *out++ = bg & 0xffu;
  else if(bg & GR_MD_24)
    *out++ = ENC_BG_24,
    *out++ = (bg >> 16) & 0xffu,
    *out++ = (bg >>  8) & 0xffu,
    *out++ = (bg >>  0) & 0xffu;
  return out;
}


static unsigned gr_encode_count(struct gr old, struct gr new)
{
  unsigned at=0,c16=0,fg=0,bg=0;
  if( !gr_ne(old,new) ) return 0;
  if( (new.fg & GR_ATTRB_MASK) != (old.fg & GR_ATTRB_MASK) ) at=2;
  if( gr_fg_full(new)!=gr_fg_full(old) ) {
    switch(gr_fg_mode(new)) {
    case 0: c16=2; break;
    case 1: fg=2; break;
    case 2: fg=4; break;
    }
  }
  if( gr_bg_full(new)!=gr_bg_full(old) ) {
    switch(gr_bg_mode(new)) {
    case 0: c16=2; break;
    case 1: bg=2; break;
    case 2: bg=4; break;
    }
  }
  return at+c16+fg+bg;
}

static uchar *gr_encode(uchar *restrict out, struct gr old, struct gr new)
{
  uchar f16 = SAME_COLOR, b16 = SAME_COLOR; 
  if( (new.fg & GR_ATTRB_MASK) != (old.fg & GR_ATTRB_MASK) )
    *out++ = ENC_ATTRB, *out++ = gr_attrb(new);
  if( gr_fg_full(new)!=gr_fg_full(old) ) {
    switch(gr_fg_mode(new)) {
    case 0: f16=gr_fg(new); break;
    case 1: *out++ = ENC_FG_256, *out++ = gr_fg(new); break;
    case 2: *out++ = ENC_FG_24,
            *out++ = (gr_fg(new) >> 16) & 0xffu,
            *out++ = (gr_fg(new) >>  8) & 0xffu,
            *out++ = (gr_fg(new) >>  0) & 0xffu;
            break;
    }
  }
  if( gr_bg_full(new)!=gr_bg_full(old) ) {
    switch(gr_bg_mode(new)) {
    case 0: b16=gr_bg(new); break;
    case 1: *out++ = ENC_BG_256, *out++ = gr_bg(new); break;
    case 2: *out++ = ENC_BG_24,
            *out++ = (gr_bg(new) >> 16) & 0xffu,
            *out++ = (gr_bg(new) >>  8) & 0xffu,
            *out++ = (gr_bg(new) >>  0) & 0xffu;
            break;
    }
  }
  b16 = (b16<<4) | f16;
  if(b16 != ((SAME_COLOR<<4)|SAME_COLOR))
    *out++ = ENC_CLR_16, *out++ = b16;
  return out;
}

struct cells_encode_state {
  uchar *restrict pos, *restrict stop;
  struct gr gr;
};

static struct cells_encode_state cells_encode(
  struct cells_encode_state st,
  const struct cell *restrict c, unsigned n, const int step)
{
  while(n--) {
    unsigned gr_count = gr_encode_count(st.gr,c->gr);
    if(gr_count) {
      if(gr_count > st.stop-st.pos) break;
      st.pos = gr_encode(st.pos, st.gr, c->gr), st.gr = c->gr;
    }
    if(st.pos+utf8_bytes(c->code)>st.stop) break;
    st.pos = put_utf8(st.pos, c->code);
    c+=step;
  }
  return st;
}

static unsigned cells_encode_count(
  struct gr *gr_st, unsigned count, unsigned max,
  const struct cell *restrict c, unsigned n, const int step)
{
  struct gr gr = *gr_st;
  while(count<max && n--) {
    count += gr_encode_count(gr,c->gr), gr=c->gr;
    count += utf8_bytes(c->code);
    c+=step;
  }
  gr.bg &= GR_MD_CLR_MASK;
  *gr_st = gr;
  return count;
}


static void cells_extend_def(struct array *restrict const cells, unsigned n)
{
  unsigned cn = cells->n;
  struct cell *out = array_reserve(struct cell,cells,cn+n)+cn;
  struct cell c = default_cell;
  cells->n += n; while(n--) *out++ = c;
}

static void cells_extend(struct array *restrict const cells,
                         unsigned n, const struct gr gr)
{
  unsigned cn = cells->n;
  struct cell *out = array_reserve(struct cell,cells,cn+n)+cn;
  struct cell c = default_cell;
  c.gr = gr, set_cell_w(c,1);
  cells->n += n; while(n--) *out++ = c;
}

/*----------------------------------------------------------------------------
  Line
  ----------------------------------------------------------------------------*/

static inline void line_reset(struct line *restrict const l)
{ l->col=0, l->beg.n=0, l->end.n=0, l->nl_gr=default_gr; }

static inline void line_free(struct line *restrict const l)
{ array_free(&l->beg), array_free(&l->end); }

static inline void line_invariant(const struct line *restrict const line)
{
  #if TERM_DIAGNOSTICS>1
  unsigned c = cells_col(0,line->beg.ptr,line->beg.n,1);
  if(c!=line->col)
    fprintf(stderr,"line invariant broken, cells_col = %u != %u = line->col\n",
         c, line->col), abort();
  #endif
}

static inline unsigned line_width(const struct line *restrict const line)
{
  unsigned en = line->end.n;
  line_invariant(line);
  return en ? cells_col(line->col,array_data(struct cell,&line->end)+en-1,en,-1)
            : line->col;
}

static void line_copy(struct line *restrict const dst,
                      const struct line *restrict const src)
{
  line_invariant(src);
  array_copy(struct cell,&dst->beg,&src->beg);
  array_copy(struct cell,&dst->end,&src->end);
  dst->col=src->col, dst->nl_gr=src->nl_gr;
  line_invariant(dst);
}

static unsigned line_enc_count(const struct line *restrict const line,
  unsigned max)
{
  unsigned en = line->end.n;
  struct gr gr = default_gr;
  unsigned count = cells_encode_count(&gr,0,max, line->beg.ptr,line->beg.n,1);
  count = cells_encode_count(&gr,count,max,
    array_data(struct cell,&line->end)+en-1,en,-1);
  return count + gr_encode_bg_count(gr, line->nl_gr);
}

static void cells_decode(
  struct line *restrict const line,
  const uchar *restrict const in, unsigned i, unsigned max)
{
  struct gr gr = default_gr;
  struct cell *restrict out 
    = array_reserve(struct cell,&line->beg,max-i);
  struct cell *const start = out;
  struct read_utf8_fast r;
  unsigned col = 0;
  r.i=i;
  for(;;) {
    uchar c = in[r.i], w;
    if(c==ENC_NL) break;
    else if(is_gr_encoding(c)) r.i += gr_decode(&gr, in+r.i);
    else {
      out->gr = gr;
      r=read_utf8_fast(in,r.i),out->code=r.c,w=char_width(r.c,col);
      set_cell_w(*out,w);
      col+=w;
      ++out;
    }
  }
  line->beg.n = out-start;
  line->end.n = 0;
  line->col = col;
  line->nl_gr = gr;
  line_invariant(line);
}

static void line_extend(struct line *restrict const l, unsigned n)
{
  line_invariant(l);
  cells_extend(&l->beg,n,l->nl_gr), l->col += n;
  line_invariant(l);
}

/* next cell (top of end stack) is TAB;
   split it into spaces and move n of these onto beg stack */
static void line_split(struct line *restrict const l, unsigned n)
{
  struct cell *c = array_data(struct cell,&l->end)+(--l->end.n);
  unsigned w = cell_w(*c);
  struct gr gr; gr=c->gr;
  while(l->end.n && (--c)->code!=ENC_TAB && cell_w(*c)==0) --l->end.n;
  cells_extend(&l->end,w-n,gr);
  cells_extend(&l->beg,n,gr), l->col+=n;
  line_invariant(l);
}

static void line_moveto(struct line *restrict const l, const unsigned col,
                        int hard)
{
  /* even if l->col==col, we still make sure
     all zero-width combining chars are to the left, in l->beg */
  unsigned total=l->beg.n+l->end.n;
  struct cell *const bs = array_reserve(struct cell, &l->beg, total),
              *const es = array_reserve(struct cell, &l->end, total),
              *restrict b = bs+l->beg.n, *restrict e = es+l->end.n;
  line_invariant(l);
  if(l->col<=col) for(;;) {
      if(e==es) break; else --e;
      if(e->code == ENC_TAB) set_cell_w(*e, 8-(l->col&7) );
      if(l->col+cell_w(*e)>col) break;
      l->col+=cell_w(*e), bs[l->beg.n++]=*e, --l->end.n;
      line_invariant(l);
  } else while(l->beg.n && col<l->col)
      --b, l->col-=cell_w(*b), es[l->end.n++]=*b, --l->beg.n,
      line_invariant(l);
  if(l->col!=col && hard) {
    if(l->end.n==0) line_extend(l,col-l->col);
    else line_split(l,col-l->col);
  }
  line_invariant(l);
}

/* deletes w cols from line->end, or as many as there are, if < w
   (may turn a TAB into spaces to accomplish this)
   returns actual number of columns deleted */ 
static int line_del_right(struct line *restrict const line, int w)
{
  unsigned en = line->end.n, col = line->col;
  int dw = 0;
  line_invariant(line);
  if(en) {
    struct cell *restrict const e = array_data(struct cell,&line->end);
    struct gr gr;
    while(en && w>0) { 
      int cw = cell_w(e[--en]);
      if(e[en].code==ENC_TAB) cw = 8 - (col&7u);
      col += cw, w -= cw, dw += cw;
    }
    gr = e[en].gr;
    while(en && cell_w(e[en-1])==0 && e[en-1].code!=ENC_TAB) --en;
    line->end.n=en;
    if(w<0) cells_extend(&line->end,-w,gr), dw+=w;
  }
  line_invariant(line);
  return dw;
}

static inline void line_erase_right(struct line *restrict const line, int w,
                                    struct gr gr, int max)
{
  max -= line->col;
  if(w>=max) {
    line->end.n = 0;
    line->nl_gr = gr;
  } else {
    line_del_right(line,w);
    if(line->end.n || gr_eff_bg(line->nl_gr) != gr_eff_bg(gr)) {
      cells_extend(&line->end,w,gr);
    }
  }
  line_invariant(line);
}

static inline void line_erase_left(struct line *restrict const line,
                                   struct gr gr)
{
  line_del_right(line,0); /* remove any combining characters */
  line->beg.n = 0;
  cells_extend(&line->beg,line->col,gr);
  line_invariant(line);
}

static inline void line_clear(struct line *restrict const line, struct gr gr)
{
  line_reset(line); line->nl_gr = gr;
  line_invariant(line);
}

/*----------------------------------------------------------------------------
  Half-buffer
  ----------------------------------------------------------------------------*/

#define line_off half_buffer_line_off /* defined in term.h */

#define line_data_ilzr {0}

static void half_buffer_clear(struct half_buffer *restrict const hb)
{
  sysbuf_reset(&hb->data,1);
  sysbuf_reset(&hb->lines,sizeof(struct line_data));
  hb->base=0;
}

static int half_buffer_reinit(struct half_buffer *restrict const hb, unsigned n)
{
  half_buffer_clear(hb);
  if(n<hb->data.max) sysbuf_shrink_dn(&hb->data,n,1);
  else if(n>hb->data.max) return sysbuf_reserve(&hb->data,n,1);
  return 0;
}

static void half_buffer_remove(
  struct half_buffer *restrict const hb, unsigned min)
{
  unsigned lo=0, hi=hb->lines.n;
  if(min==0) return;
  while(lo<hi) {
    unsigned m = lo + (hi-lo)/2, off = line_off(hb,m);
    if(off==min) { lo=m; break; }
    else if(off<min) lo=m+1;
    else hi=m;
  }
  /* lo == hb->lines.n || line_off(hb,lo) >= min */
  if(lo == hb->lines.n) half_buffer_clear(hb);
  else {
    unsigned off = line_off(hb,lo);
    sysbuf_shrink_up(&hb->data,off,1); hb->base+=off;
    if(lo>0) sysbuf_shrink_up(&hb->lines,lo,sizeof(struct line_data));
  }
}

/* include 3 extra bytes, so that the UTF-8 decoder may always read 4 bytes */
static int half_buffer_grow_try(
  struct half_buffer *restrict const hb, unsigned m)
{
  size_t desired = hb->data.n+m+3;
  return (desired<hb->limit && sysbuf_reserve(&hb->data,desired,1)==0) ? 0 : -1;
}

/* include 3 extra bytes, so that the UTF-8 decoder may always read 4 bytes */
static int half_buffer_grow(struct half_buffer *restrict const hb, unsigned m)
{
  size_t desired = hb->data.n+m+3;
  if(desired>=hb->limit && (m+3)<hb->limit/2) {
    unsigned keep = hb->limit/2 - (m+3);
    /* data.n + (m+3) >= hb->limit, so
       data.n >= hb->limit - (m+3), and data.n-keep > 0 */
    half_buffer_remove(hb,hb->data.n-keep);
    desired = hb->data.n+m+3;
  }
  if(desired<hb->limit) {
    if(sysbuf_reserve(&hb->data,desired,1)==0) return 0;
    else fprintf(stderr,"short on memory: %s\n",strerror(errno)), half_buffer_clear(hb);
  } else if(m+3>=hb->limit/2)
    half_buffer_reinit(hb,hb->limit/2);
  return hb->data.max>=m+3 ? 0 : -1;
}

static int lines_grow(struct half_buffer *restrict const hb, unsigned m)
{
  if(m==0) return 0;
  if(sysbuf_reserve(&hb->lines,hb->lines.n+m,sizeof(struct line_data))) {
    fprintf(stderr,"short on memory: %s\n",strerror(errno)), half_buffer_clear(hb);
    return hb->lines.max>=m ? 0 : -1;
  }
  return 0;
}

static void half_buffer_free(struct half_buffer *restrict const hb)
{ sysbuf_free(&hb->data), sysbuf_free(&hb->lines); }

static void push_empty(struct half_buffer *restrict const hb, unsigned n)
{
  /* if either grow function fails, the buffer is reset,
     and we push however many lines fit */
  if(half_buffer_grow(hb,n)) n = hb->data.max<3 ? 0 : hb->data.max-3;
  if(lines_grow(hb,n)) n = hb->lines.max;
  {
  unsigned dn = hb->data.n;
  const unsigned ln = hb->lines.n, base = hb->base;
  struct line_data ld = line_data_ilzr,
    *restrict pld = (struct line_data*)hb->lines.ptr + ln;
  uchar *restrict const p = hb->data.ptr;
  hb->data.n = dn+n, hb->lines.n = ln+n;
  while(n--) *pld=ld, pld->off=base+dn, ++pld, p[dn++]=ENC_NL;
  }
}

static void push_clear(struct half_buffer *restrict const hb, unsigned n,
                       struct gr gr)
{
  if(GR_BG_IS_DEF(gr)) push_empty(hb,n);
  else if(n) {
    unsigned grc = gr_encode_bg_count(default_gr, gr);
    unsigned tw = grc+1; /* set bg, 1 new line */ 
    /* if either grow function fails, the buffer is reset,
       and we push however many lines fit */
    if(half_buffer_grow(hb,tw*n)) n=hb->data.max<3?0:(hb->data.max-3)/tw;
    if(lines_grow(hb,n)) n=hb->lines.max;
    {
    unsigned dn = hb->data.n;
    const unsigned ln = hb->lines.n, len = tw*n, base = hb->base;
    struct line_data ld = line_data_ilzr,
      *restrict pld = (struct line_data*)hb->lines.ptr + ln;
    uchar *restrict const p = hb->data.ptr;
    hb->data.n = dn+len, hb->lines.n = ln+n;
    *pld=ld, pld->off=base+dn, ++pld;
    gr_encode_bg(p+dn, default_gr, gr);
    p[dn+grc]=ENC_NL;
    while(--n) {
      memcpy(p+dn+tw,p+dn,tw), dn+=tw;
      *pld=ld, pld->off=base+dn, ++pld;
    }
    }
  }
}

static inline void half_buffer_delete(
  struct half_buffer* restrict const hb, int n)
{
  if(n<=0 || hb->lines.n==0) return;
  hb->lines.n = (int)hb->lines.n>n ? hb->lines.n-n : 0;
  hb->data.n=line_off(hb,hb->lines.n);
}

static inline void half_buffer_add_blank(
  struct half_buffer* restrict const hb, int n,
  struct gr gr)
{
  if(hb->lines.n || !GR_BG_IS_DEF(gr)) push_clear(hb,n,gr);
}

static inline void half_buffer_erase(
  struct half_buffer* restrict const hb, int n,
  struct gr gr)
{
  half_buffer_delete(hb,n);
  half_buffer_add_blank(hb,n,gr);
}

static void push_line(struct half_buffer *restrict const hb,
                      const struct line *restrict const line)
{
  unsigned cn0 = line->beg.n, cn1 = line->end.n,
           max_len = 4+(4+9)*(cn0+cn1);
                     /* 4 bytes for final SGR,
                        4 bytes UTF-8 possible per cell,
                        9 bytes possible SGR per cell */
  if(half_buffer_grow_try(hb,max_len+1)) {
    unsigned count = line_enc_count(line,hb->limit/2);
    half_buffer_grow(hb,count+1);
    max_len = hb->data.max<4+hb->data.n ? 0 : (hb->data.max-4) - hb->data.n;
    if(hb->data.max<1+hb->data.n) return;
  }
  if(lines_grow(hb,1)) return;
  {
  unsigned dn = hb->data.n, ln = hb->lines.n++;
  struct line_data ld = line_data_ilzr,
    *restrict const pld =  (struct line_data*)hb->lines.ptr+ln;
  uchar *const start = (unsigned char*)hb->data.ptr+dn,
        *const stop  = start + max_len;
  struct cells_encode_state st = { 0, 0, default_gr };
  st.pos = start, st.stop = stop;
  ld.off=dn+hb->base, *pld = ld;
  st = cells_encode(st,array_data(struct cell,&line->beg),cn0,1);
  if(cn1) st=cells_encode(st,array_data(struct cell,&line->end)+cn1-1,cn1,-1);
  st.pos = gr_encode_bg(st.pos, st.gr, line->nl_gr);
  *st.pos++ = ENC_NL;
  hb->data.n=dn+(st.pos-start);
  }  
}

static void pop_line(struct line *restrict const line,
                     struct half_buffer *restrict const hb)
{
  unsigned off = line_off(hb,--hb->lines.n);
  cells_decode(line, hb->data.ptr,off,hb->data.n);
  hb->data.n = off;
}

static void transfer_lines(struct half_buffer *restrict const dst,
                           struct half_buffer *restrict const src,
                           unsigned n)
{
  unsigned max;
  if(n==0) return;
  if(n>src->lines.n) fprintf(stderr,"invalid call to transfer_lines\n"), abort();
  half_buffer_grow(dst,src->data.n-line_off(src,src->lines.n-n));
  if(lines_grow(dst,n)) {
    half_buffer_delete(src,(dst->lines.max-dst->lines.n)-n);
    n = dst->lines.max-dst->lines.n;
  }
  max = dst->data.max - dst->data.n;
  if(max<=3) { half_buffer_delete(src,n); return; }
  else max-=3;
  while(n>1 && (src->data.n-line_off(src,src->lines.n-n)) > max) {
    half_buffer_delete(src,1); --n;
  }
  if(n==1 && (src->data.n-line_off(src,src->lines.n-n)) > max) {
    struct line l = { null_array, null_array, 0, default_gr_ilzr };
    pop_line(&l, src);
    push_line(dst,&l);
    line_free(&l);
  } else {
    const unsigned sb = src->base;
    unsigned snl = src->lines.n, snb = src->data.n;
    const struct line_data *restrict const lds = src->lines.ptr;
    const uchar *restrict const s = src->data.ptr;
    struct line_data *restrict const ldd = dst->lines.ptr;
    unsigned dnl = dst->lines.n, dnb = dst->data.n;
    uchar *restrict d = dst->data.ptr;
    const unsigned db = dst->base;
    do {
      unsigned so,len;
      so = lds[--snl].off-sb, len = snb-so;
      ldd[dnl]=lds[snl], ldd[dnl].off = db+dnb;
      memcpy(d+dnb, s+so, len);
      dnb += len, snb -= len, ++dnl;
    } while(--n);
    src->lines.n=snl, dst->lines.n=dnl;
    src->data.n=snb, dst->data.n=dnb;
  }
}

/*----------------------------------------------------------------------------
  Term
  ----------------------------------------------------------------------------*/

static void term_buffer_free(struct term_buffer *restrict const tb)
{ half_buffer_free(&tb->beg), half_buffer_free(&tb->end); }

void term_init(struct term *restrict const t, unsigned blim, unsigned elim)
{
  memset(t,0,sizeof(struct term));
  t->w=t->h=1;
  t->mode = MODE_SHOW_CURSOR;
  t->mouse_flags = MOUSE_ALT_SCROLL;
  t->cursor.gr = default_gr, t->saved_cursor.gr = default_gr;
  t->state = STATE_NORMAL;
  array_init(struct line,&t->margin,1);
  memset(t->margin.ptr,0,sizeof(struct line));
  line_reset(t->margin.ptr);
  t->margin.n=1;
  buffer_init(&t->escape_buf, MAX_ESCAPE+1);
  t->buf.beg.limit = blim, t->buf.end.limit = elim;
}

void term_done(struct term *restrict const t)
{
  unsigned n = t->margin.n;
  struct line *restrict line = t->margin.ptr;
  do line_free(line++); while(--n);
  array_free(&t->margin);
  term_buffer_free(&t->buf);
  term_buffer_free(&t->primary.buf);
  buffer_free(&t->escape_buf);
  free(t->osc52_data), t->osc52_data=0;
}

/* conceptual layout of rows:

     (wrap mode plays no role, each line is a row)

   ---- 0
   margin 1,3,5,....     rel rows : -1,-3,-5, ...
   ---- mt
   buf.beg
   ---- mt + line_row   (may be off-screen above or below)
   line     ( margin [0] )
   buf.end
   blank 
   ---- h - mb
   margin ...,6,4,2      rel rows : ..., -6, -4, -2
   ---- h

*/

#define HIGH_BIT 1u << (UINT_BITS-1)
#define HAS_HIGH_BIT(x) (( (x)>>(UINT_BITS-1) )&1u)

#define IN_MARGIN(t) HAS_HIGH_BIT((t)->cursor.row)

static inline unsigned abs_row(
  const struct term *restrict const t, unsigned rel_row)
{
  const unsigned marg_mask = - HAS_HIGH_BIT(rel_row),
                 neg = -1u-rel_row, odd_mask = -(neg&1u), m = neg>>1;
  return   ~marg_mask & rel_row + t->mt
         |  marg_mask & ( ~odd_mask & m | odd_mask & t->h-1-m );
}

static inline unsigned rel_row(
  const struct term *restrict const t, unsigned abs_row)
{
  if(abs_row < t->mt)
    return -(2u*abs_row+1);
  else if(abs_row < (unsigned)t->h-(unsigned)t->mb)
    return abs_row - t->mt;
  else
    return -(2u*(t->h-abs_row));
}

static void fix_cursor(struct term *restrict const t)
{
  if(IN_MARGIN(t)) {
    const unsigned neg = -1u-t->cursor.row, mr = neg>>1;
    if(neg&1)
      t->cursor.row = t->mb==0 ? (unsigned)(t->h-1-t->mt) : -(2u*(
                      mr>=t->mb ? (unsigned)t->mb : mr+1));
    else
      t->cursor.row = t->mt==0 ? 0u : -(1u+2u*(
                      mr>=t->mt ? (unsigned)t->mt-1u : mr));
  } else {
    unsigned s = t->h-(t->mt+t->mb);
    if(t->cursor.row > s) t->cursor.row = s;
  }
}

static void set_cursor_pos(
  struct term *restrict const t, int row, int col, int allow_margin)
{
  if(col>=(int)t->w) col=t->w-1; if(col<0) col=0;
  t->cursor.col=col;
  if(allow_margin) {
    if(row>=(int)t->h) row=t->h-1; if(row<0) row=0;
  } else {
    if(row>=(int)(t->h-t->mb)) row=t->h-t->mb-1;
    if(row<(int)t->mt) row=t->mt;
  }
  t->cursor.row=rel_row(t,row);
}

void term_move_line_row(struct term *restrict const t, int row)
{
  struct line *restrict const line = array_data(struct line, &t->margin);
  int gap = row - t->line_row;
  struct half_buffer *restrict src, *restrict dst;
  if(gap!=0) {
    if(gap<0) src=&t->buf.beg, dst=&t->buf.end, gap = -gap;
         else src=&t->buf.end, dst=&t->buf.beg;
    push_line(dst,line);
    if(src->lines.n>=(unsigned)gap)
      transfer_lines(dst,src,gap-1), pop_line(line,src);
    else {
      gap = gap-1 - src->lines.n;
      transfer_lines(dst,src,src->lines.n);
      if(gap) push_empty(dst,gap);
      line_reset(line);
    }
    t->line_row = row;
  }
  if(row>=(int)(t->h-(t->mt+t->mb))-1)
    sysbuf_reset(&t->buf.end.data,1),
    sysbuf_reset(&t->buf.end.lines,sizeof(struct line_data));
}

static inline void truncate_end(struct term *restrict const t)
{
  term_move_line_row(t,(int)(t->h-(t->mt+t->mb))-1);
}

static inline void truncate_beg(struct term *restrict const t)
{
  term_move_line_row(t,0);
  sysbuf_reset(&t->buf.beg.data,1);
  sysbuf_reset(&t->buf.beg.lines,sizeof(struct line_data));
}

static struct line *synch_row(struct term *restrict const t)
{
  struct line *restrict const line = array_data(struct line, &t->margin);
  if(HAS_HIGH_BIT(t->cursor.row)) return &line[-t->cursor.row];
  else { term_move_line_row(t,t->cursor.row); return line; }
}

static struct line *synch_pos(struct term *restrict const t, int hard)
{
  struct line *restrict const line = synch_row(t);
  line_moveto(line,t->cursor.col,hard);
  return line;
}

static struct line *margin_reserve(
  struct array *restrict const marg, int mt, int mb)
{
  int max = mt*2>mb*2+1 ? mt*2 : mb*2+1;
  struct line *restrict const line = array_reserve(struct line,marg,max);
  if(max>(int)marg->n) {
    int i;
    memset(line+marg->n,0,(max-marg->n)*sizeof(struct line));
    for(i=marg->n;i<(int)max;i++) line_reset(line+i);
    marg->n=max;
  }
  return line;
}

static void set_margins(struct term *restrict const t, int mt, int mb)
{
  int i; unsigned cur = abs_row(t,t->cursor.row);
  struct line *restrict const line = margin_reserve(&t->margin,mt,mb);
  #define TMARG(i) (line+1+2*(i))
  #define BMARG(i) (line+2+2*(i))
  if(mt+mb>t->h)
    fprintf(stderr,"term.c: set_margins: invalid args\n"), abort();
  if(mt<t->mt) {
    term_move_line_row(t,0);
    for(i=mt;i<t->mt;++i) push_line(&t->buf.beg,TMARG(i));
    t->line_row+=(int)t->mt-mt, t->mt=mt;
  }
  if(mb<t->mb) {
    term_move_line_row(t,(int)t->h-(int)(t->mt+t->mb)-1);
    for(i=mb;i<t->mb;++i) push_line(&t->buf.end,BMARG(i));
    t->mb=mb;
  }
  if(mt>t->mt) {
    term_move_line_row(t,-1);
    for(i=t->mt;i<mt;++i)
      if(t->buf.end.lines.n) pop_line(TMARG(i),&t->buf.end);
      else line_reset(TMARG(i));
    t->mt=mt;
  }
  if(mb>t->mb) {
    term_move_line_row(t,(int)t->h-(int)(t->mt+t->mb));
    for(i=t->mb;i<mb;++i)
      if(t->buf.beg.lines.n) pop_line(BMARG(i),&t->buf.beg);
      else line_reset(BMARG(i));
    t->line_row-=(int)mb-t->mb, t->mb=mb;
  }
  t->cursor.row=rel_row(t,cur);
  #undef BMARG
  #undef TMARG
}

void term_resize(struct term *restrict const t,
                 unsigned short w, unsigned short h)
{
  if(!w) w=1; if(!h) h=1;
  t->w = w;
  if(TERM_DIAGNOSTICS) printf("resizing term to %u x %u\n",w,h);
  if(h==t->h) return;
  set_margins(t,0,0);
  if(h>t->h) {
    int backlog = (int)t->buf.beg.lines.n - t->line_row;
    if(backlog<0) backlog=0;
    if((int)(h-t->h) < backlog) backlog = h-t->h;
    t->line_row += backlog;
    if(!IN_MARGIN(t)) t->cursor.row += backlog;
    t->h=h;
  } else {
    int blank = (t->h - (t->mt+t->mb)) - (t->line_row+1) 
                - (int)t->buf.end.lines.n;
    int move = t->h - h - (blank>0?blank:0);
    if(move>0) {
      t->line_row -= move;
      if(!IN_MARGIN(t)) {
        if(t->cursor.row > (unsigned)move) t->cursor.row -= move;
        else t->cursor.row = 0;
      }
    }
    t->h=h;
    if(t->mt+t->mb > h) {
      unsigned gap = (unsigned)h - (unsigned)(t->mt+t->mb);
      fprintf(stderr,"shrinking margins in term_resize\n"), abort();
      if(gap<=t->mb) t->mb-=gap;
      else t->mt-=(gap-t->mb), t->mb=0;
      if(IN_MARGIN(t)) fix_cursor(t);
    }
  }
}

static void term_restore_screen(struct term *restrict const t);

static void soft_reset(struct term *restrict const t)
{
  if(t->alt_screen) term_restore_screen(t);
  set_margins(t,0,0);
  t->mode = MODE_SHOW_CURSOR;
  t->cursor.gr = default_gr, t->saved_cursor.gr = default_gr;
  memset(t->G,0,4);
  t->curG=0, t->linedraw=0;
  t->kitty_kb_flags=0, t->kitty_kb_stack_n=0;
  t->mouse_mode=MOUSE_MODE_OFF, t->mouse_change=1;
  t->mouse_flags=MOUSE_ALT_SCROLL;
  t->bracketed_paste=0;
}

static void term_save_screen(struct term *restrict const t)
{
  struct term_screen *restrict const p = &t->primary;
  struct line *restrict const line = array_data(struct line, &t->margin);
  if(t->alt_screen) return;
  set_margins(t,0,0);
  p->cursor_row = abs_row(t,t->cursor.row);
  p->cursor_col = t->cursor.col;
  p->cursor_gr  = t->cursor.gr;
  p->saved_cursor = t->saved_cursor;
  p->mode = t->mode, p->saved_mode = t->saved_mode;
  memcpy(p->G,t->G,4);
  p->curG = t->curG, p->linedraw = t->linedraw;
  p->w = t->w, p->h = t->h;
  push_line(&t->buf.beg, line);
  p->line_row = t->line_row;
  p->buf = t->buf;
  memset(&t->buf,0,sizeof(struct term_buffer));
  t->buf.beg.limit = p->buf.beg.limit;
  t->buf.end.limit = p->buf.end.limit;
  line_reset(line);
  t->line_row = 0;
  t->cursor.row = 0, t->cursor.col = 0, t->cursor.gr = default_gr;
  t->mode = MODE_SHOW_CURSOR, t->saved_mode = 0;
  t->saved_cursor.row = 0, t->saved_cursor.col = 0;
  t->saved_cursor.gr = default_gr;
  memset(t->G,0,4);
  t->curG = 0, t->linedraw = 0;
  t->alt_screen = 1;
}

static void term_restore_screen(struct term *restrict const t)
{
  struct term_screen *restrict const p = &t->primary;
  struct line *restrict const line = array_data(struct line, &t->margin);
  if(!t->alt_screen) return;
  set_margins(t,0,0);
  line_reset(line);
  term_buffer_free(&t->buf);
  t->buf = p->buf;
  memset(&p->buf,0,sizeof(struct term_buffer));
  t->line_row = p->line_row;
  pop_line(line, &t->buf.beg);
  t->cursor.col = p->cursor_col;
  t->cursor.gr  = p->cursor_gr;
  t->saved_cursor = p->saved_cursor;
  t->mode = p->mode, t->saved_mode = p->saved_mode;
  memcpy(t->G,p->G,4);
  t->curG = p->curG, t->linedraw = p->linedraw;
  t->alt_screen = 0;
  t->cursor.row = rel_row(t, p->cursor_row);
  if(p->w != t->w || p->h != t->h)
    term_resize(t, t->w, t->h);
}

/*----------------------------------------------------------------------------
  Control Functions
  ----------------------------------------------------------------------------*/

/* Linefeed (LF) : LF */
static void cf_LF(struct term *restrict const t)
{
  if(IN_MARGIN(t)) {
    unsigned ra = abs_row(t,t->cursor.row);
    if(ra+1<t->h) t->cursor.row = rel_row(t,ra+1);
  } else if(t->cursor.row+1==(unsigned)t->h-(t->mt+t->mb)) {
    struct line *line;
    --t->line_row, line = synch_row(t);
    line_reset(line); line->nl_gr = t->cursor.gr;
    if(t->alt_screen && (int)t->buf.beg.lines.n > 2*t->h)
      truncate_beg(t);
  } else
    ++t->cursor.row;
}

/* Reverse Index (RI) : ESC M */
static void cf_RI(struct term *restrict const t)
{
  if(IN_MARGIN(t)) {
    unsigned ra = abs_row(t,t->cursor.row);
    if(ra) t->cursor.row = rel_row(t,ra-1);
  } else if(t->cursor.row==0) {
    struct line *line;
    ++t->line_row, line = synch_row(t);
    line_reset(line); line->nl_gr = t->cursor.gr;
  } else
    --t->cursor.row;
}

/* Backspace (BS) : BS */
static void cf_BS(struct term *restrict const t)
{
  if(t->cursor.col) --t->cursor.col;
}

/* Horizontal Tab (HT) : HT */
static void cf_HT(struct term *restrict const t)
{
  int w = 8-(t->cursor.col&7u);
  struct line *restrict const line = synch_pos(t,1);
  unsigned n = ++line->beg.n;
  struct cell *restrict const c = array_reserve(struct cell,&line->beg,n)+n-1;
  c->code = ENC_TAB, c->gr = t->cursor.gr, set_cell_w(*c,w);
  line->col += w, t->cursor.col += w;
  if(!(t->mode&MODE_INSERT)) line_del_right(line,w);
}

/* Carriage Return (CR) : CR */
static void cf_CR(struct term *restrict const t)
{
  t->cursor.col=0;
}

/* Shift Out (SO) : SO */
static void cf_SO(struct term *restrict const t)
{
  t->curG=1;
  t->linedraw=t->G[(int)t->curG];
}

/* Shift In (SI) : SI */
static void cf_SI(struct term *restrict const t)
{
  t->curG=0;
  t->linedraw=t->G[(int)t->curG];
}

/* Save Cursor (DECSC) : ESC 7 */
static void cf_DECSC(struct term *restrict const t)
{
  t->saved_cursor.row = abs_row(t,t->cursor.row);
  t->saved_cursor.col = t->cursor.col;
  t->saved_cursor.gr = t->cursor.gr;
  t->saved_mode = t->mode&MODE_ORIGIN;
}

/* Restore Cursor (DECRC) : ESC 8 */
static void cf_DECRC(struct term *restrict const t)
{
  set_cursor_pos(t,t->saved_cursor.row,t->saved_cursor.col,1);
  t->cursor.gr = t->saved_cursor.gr;
  t->mode=(t->mode&~MODE_ORIGIN)|t->saved_mode;
}

/* Keypad Application Mode (DECKPAM) : ESC = */
static void cf_DECKPAM(struct term *restrict const t)
{
  t->mode|=MODE_APP_KEYPAD;
}

/* Keypad Numeric Mode (DECKPNM) : ESC > */
static void cf_DECKPNM(struct term *restrict const t)
{
  t->mode&=~MODE_APP_KEYPAD;
}

/* (CUU) : ESC [ Pn A       Cursor Up                  
   (CUD) : ESC [ Pn B       Cursor Down                
   (CUF) : ESC [ Pn C       Cursor Forward             
   (CUB) : ESC [ Pn D       Cursor Backward            
   (CNL) : ESC [ Pn E       Cursor Next Line           
   (CPL) : ESC [ Pn F       Cursor Preceding Line      
   (CHA) : ESC [ Pn G       Cursor Horizontal Absolute 
   (CUP) : ESC [ Pn1;Pn2 H  Cursor Position
   (HPA) : ESC [ Pn `       Horizontal Position Absolute
   (HPR) : ESC [ Pn a       Horizontal Position Relative
   (VPA) : ESC [ Pn d       Vertical Position Absolute
   (VPR) : ESC [ Pn e       Vertical Position Relative
   (HVP) : ESC [ Pn1;Pn2 f  Horizontal Vertical Position
   all parameters default to 1 */
static void cf_cursor_move(struct term *restrict const t,
  const int *restrict param, const int n, const uchar c)
{
  int p1=-1, p2=-1, row=t->cursor.row, col=t->cursor.col;
  if(n>0) { p1=param[0]; if(n>1) p2=param[1]; }
  if(p1==-1) p1=1; if(p2==-1) p2=1;
  switch(c) {
    case 'A': case 'e': set_cursor_pos(t,row-p1,col,0); return;
    case 'B':           set_cursor_pos(t,row+p1,col,0); return;
    case 'C': case 'a': set_cursor_pos(t,row,col+p1,1); return;
    case 'D':           set_cursor_pos(t,row,col-p1,1); return;
    case 'E':           set_cursor_pos(t,row+p1,0,0); return;
    case 'F':           set_cursor_pos(t,row-p1,0,0); return;
    case 'G': case '`': set_cursor_pos(t,row,p1-1,1); return;
    case 'H': case 'f':
      if(t->mode&MODE_ORIGIN) set_cursor_pos(t,t->mt+p1-1,p2-1,0);
                         else set_cursor_pos(t,p1-1,p2-1,1);
      return;
    case 'd':
      if(t->mode&MODE_ORIGIN) set_cursor_pos(t,t->mt+p1-1,col,0);
                         else set_cursor_pos(t,p1-1,col,1);
      return;
  }
}

/* Select Graphic Rendition (SGR) : ESC [ Ps... m    (Ps=0) */
static void cf_SGR(struct term *restrict const t,
  const int *restrict p, unsigned n)
{
  const struct gr def = default_gr;
  if(n==0) { t->cursor.gr = def; return; }
  do {
    switch(*p) {
    case -1:
    case 0 : t->cursor.gr=def;             break;
    case 1 : add_gr_attrb(t->cursor.gr, ATTRB_BD); break;
    case 2 : add_gr_attrb(t->cursor.gr, ATTRB_DM); break;
    case 4 : add_gr_attrb(t->cursor.gr, ATTRB_UL); break;
    case 5 : add_gr_attrb(t->cursor.gr, ATTRB_BL); break;
    case 7 : add_gr_attrb(t->cursor.gr, ATTRB_IN); break;
    case 22: del_gr_attrb(t->cursor.gr, ATTRB_BD|ATTRB_DM); break;
    case 24: del_gr_attrb(t->cursor.gr, ATTRB_UL); break;
    case 25: del_gr_attrb(t->cursor.gr, ATTRB_BL); break;
    case 27: del_gr_attrb(t->cursor.gr, ATTRB_IN); break;
    case 30: case 31: case 32: case 33: case 34: case 35: case 36: case 37:
    case 39:
      t->cursor.gr.fg = (t->cursor.gr.fg & ~(uint32)GR_MD_CLR_MASK) | (*p-30);
      break;
    case 90: case 91: case 92: case 93: case 94: case 95: case 96: case 97:
      t->cursor.gr.fg = (t->cursor.gr.fg & ~(uint32)GR_MD_CLR_MASK)
                      | GR_MD_256 | 8 | (*p-90);
      break;
    case 40: case 41: case 42: case 43: case 44: case 45:
    case 46: case 47: case 49:
      t->cursor.gr.bg = (*p-40);
      break;
    case 100: case 101: case 102: case 103:
    case 104: case 105: case 106: case 107:
      t->cursor.gr.bg = GR_MD_256 | 8 | (*p-100);
      break;
    case 38: case 48: {
        uint32 *clr = *p==38 ? &t->cursor.gr.fg : &t->cursor.gr.bg;
        uint32 at = (*clr & ~(uint32)GR_MD_CLR_MASK);
        ++p, --n; if(n<2) return;
        switch(*p) {
        case 5: ++p, --n; if(*p < 0 || 255 < *p) return;
          *clr = at | GR_MD_256 | *p ;
          break;
        case 2: ++p, --n;
          if(n<3 || p[0]<0 || 255<p[0]
                 || p[1]<0 || 255<p[1]
                 || p[2]<0 || 255<p[2]) return;
          *clr = at | GR_MD_24 | (uint32)p[0]<<16 | (uint32)p[1]<<8 | p[2];
          p+=2, n-=2;
          break;
        }
      }  
    }
    ++p;
  } while(--n);
}

/* Erase in Line (EL) : ESC [ Ps K    (Ps=0) */
static void cf_EL(struct term *restrict const t, int *param, int n)
{
  int p = n?param[0]:0;
  struct line *restrict line;
  switch(p) {
    case 0:
      line=synch_pos(t,1); line->end.n=0; line->nl_gr = t->cursor.gr;
      break;
    case 1:
      line=synch_pos(t,1);
      line_erase_left(line,t->cursor.gr);
      line_erase_right(line,1,t->cursor.gr,t->w);
      break;
    case 2:
      line_clear(synch_row(t),t->cursor.gr);
      break;
  }
}

/* Erase in Display (ED) : ESC [ Ps J    (Ps=0) */
static void cf_ED(struct term *restrict const t, int *param, int n)
{
  int p = n?param[0]:0;
  cf_EL(t,param,n);
  if(IN_MARGIN(t)) {
    #if PRINT_UNHANDLED
    printf("unhandled: ED in margin\n");
    #endif
    return;
  }
  if(p==1|p==2)
    half_buffer_erase(&t->buf.beg,t->line_row,t->cursor.gr);
  if(p==0|p==2)
    half_buffer_erase(&t->buf.end,(int)(t->h-(t->mt+t->mb))-(t->line_row+1),
                      t->cursor.gr);
}

/* Reset to Initial State (RIS) : ESC c */
static void cf_RIS(struct term *restrict const t)
{
  soft_reset(t);
  t->state = STATE_NORMAL;
  t->escape_buf.n = 0;
  set_cursor_pos(t,0,0,1);
  { int p=2; cf_ED(t,&p,1); }
}

/* Insert Characters (ICH) : ESC [ Pn @    (Pn=1) */
static void cf_ICH(struct term *restrict const t, int *param, int n)
{
  int p = n?param[0]:1;
  struct line *restrict line = synch_pos(t,1);
  if(p<=0) return; if(p>(int)t->w) p=t->w;
  cells_extend(&line->end,p,t->cursor.gr);
}

/* Delete Characters (DCH) : ESC [ Pn P    (Pn=1) */
static void cf_DCH(struct term *restrict const t, int *param, int n)
{
  int p = n?param[0]:1;
  struct line *restrict line = synch_pos(t,1);
  if(p<=0) return;
  line_del_right(line,p);
}

/* Erase Characters (ECH) : ESC [ Pn X    (Pn=1) */
static void cf_ECH(struct term *restrict const t, int *param, int n)
{
  int p = n?param[0]:1;
  struct line *restrict line = synch_pos(t,1);
  if(p<=0) return;
  line_erase_right(line,p,t->cursor.gr,t->w);
}

/* Insert Lines (IL) : ESC [ Pn L    (Pn=1) */
static void cf_IL(struct term *restrict const t, int *param, int n)
{
  int p = n?param[0]:1;
  struct line *restrict line = synch_row(t);
  if(p<=0) return; if(p>(int)t->h) p=t->h;
  if(IN_MARGIN(t)) {
    #if PRINT_UNHANDLED
    printf("unhandled: IL in margin\n");
    #endif
    return;
  }
  push_line(&t->buf.end,line);
  if(p>1) half_buffer_add_blank(&t->buf.end,p-1,t->cursor.gr);
  line_clear(line,t->cursor.gr);
}

/* Delete Lines (DL) : ESC [ Pn M    (Pn=1) */
static void cf_DL(struct term *restrict const t, int *param, int n)
{
  int p = n?param[0]:1;
  struct line *restrict line;
  if(p<=0) return; if(p>(int)t->h) p=t->h;
  truncate_end(t);
  line=synch_row(t);
  if(IN_MARGIN(t)) {
    #if PRINT_UNHANDLED
    printf("unhandled: DL in margin\n");
    #endif
    return;
  }
  half_buffer_delete(&t->buf.end,p-1);
  if(t->buf.end.lines.n==0)
    line_clear(line,t->cursor.gr);
  else
    pop_line(line,&t->buf.end);
}

/* Scroll Up (SU) : ESC [ Pn S    (Pn=1) */
static void cf_SU(struct term *restrict const t, int *param, int n)
{
  int p = n?param[0]:1;
  if(p<=0) return;
  truncate_end(t);
  t->line_row -= p;
  if(t->alt_screen && (int)t->buf.beg.lines.n > 2*t->h)
    truncate_beg(t);
}

/* Scroll Down (SD) : ESC [ Pn T    (Pn=1) */
static void cf_SD(struct term *restrict const t, int *param, int n)
{
  struct gr gr = default_gr;
  int p = n?param[0]:1, scr=t->h-(t->mt+t->mb);
  if(p<=0) return;
  t->line_row += p;
  if(p>scr) p=scr;
  term_move_line_row(t,-1);
  half_buffer_erase(&t->buf.end,p,gr);
}

/* DEC Set Top and Bottom Margins (DECSTBM) : ESC [ Pn1;Pn2 r    */
static void cf_DECSTBM(struct term *restrict const t, int *param, int n)
{
  int top=-1, bot=-1;
  if(n>0) { top=param[0]; if(n>1) bot=param[1]; }
  if(top==-1) top=1; if(bot==-1) bot=t->h;
  if(top<1 || top>(int)t->h || bot<=top || bot>(int)t->h
     || (top-1)+((int)t->h-bot)>t->h) return;
  set_margins(t,top-1,t->h-bot);
}

/* Set Mode (SM) : ESC [ Ps... h */
static void cf_SM(struct term *restrict const t, int *p, int n)
{
  int *end=p+n;
  for(;p!=end;++p) {
    switch(*p) {
    case  4: t->mode|=MODE_INSERT; break;
#if PRINT_UNHANDLED
    default: printf("unhandled: mode %d\n",*p); break;
#endif    
    }
  }
}

/* Reset Mode (RM) : ESC [ Ps... l */
static void cf_RM(struct term *restrict const t, int *p, int n)
{
  int *end=p+n;
  for(;p!=end;++p) {
    switch(*p) {
    case  4: t->mode&=~MODE_INSERT; break;
#if PRINT_UNHANDLED
    default: printf("unhandled: mode %d\n",*p); break;
#endif    
    }
  }
}

/* DEC Private Mode Set (DECSET) : ESC [ ? Ps... h */
static void cf_DECSET(struct term *restrict const t,
  const int *restrict p, int n)
{
  const int *end=p+n;
  for(;p!=end;++p) {
    switch(*p) {
    case  1:   t->mode|=MODE_APP_CURSOR; break;
    case  6:   t->mode|=MODE_ORIGIN; break;
    case  7: /*t->mode|=MODE_AUTOWRAP;*/ break;
    case 25:   t->mode|=MODE_SHOW_CURSOR; break;
    case 1034: t->mode|=MODE_META; break;
    case    9: t->mouse_mode=MOUSE_MODE_X10,  t->mouse_change=1; break;
    case 1000: t->mouse_mode=MOUSE_MODE_NORM, t->mouse_change=1; break;
    case 1002: t->mouse_mode=MOUSE_MODE_BTN,  t->mouse_change=1; break;
    case 1003: t->mouse_mode=MOUSE_MODE_ANY,  t->mouse_change=1; break;
    case 1004: t->mouse_flags|= MOUSE_FOCUS; break;
    case 1006: t->mouse_flags|= MOUSE_SGR; break;
    case 1007: t->mouse_flags|= MOUSE_ALT_SCROLL; break;
    case 2004: t->bracketed_paste=1; break;
    case   47: case 1047: term_save_screen(t); break;
    case 1048: cf_DECSC(t); break;
    case 1049: cf_DECSC(t); term_save_screen(t); break;
#if PRINT_UNHANDLED
    default: printf("unhandled: DECSET mode %d\n",*p); break;
#endif
    }
  }
}

/* DEC Private Mode Set (DECRST) : ESC [ ? Ps... l */
static void cf_DECRST(struct term *restrict const t,
  const int *restrict p, int n)
{
  const int *end=p+n;
  for(;p!=end;++p) {
    switch(*p) {
    case  1:   t->mode&=~MODE_APP_CURSOR; break;
    case  6:   t->mode&=~MODE_ORIGIN; break;
    case  7: /*t->mode&=~MODE_AUTOWRAP;*/ break;
    case 25:   t->mode&=~MODE_SHOW_CURSOR; break;
    case 1034: t->mode&=~MODE_META; break;
    case    9: case 1000: case 1002: case 1003:
      if(t->mouse_mode==(*p==9?MOUSE_MODE_X10:
                          *p==1000?MOUSE_MODE_NORM:
                          *p==1002?MOUSE_MODE_BTN:MOUSE_MODE_ANY))
        t->mouse_mode=MOUSE_MODE_OFF, t->mouse_change=1;
      break;
    case 1004: t->mouse_flags&=~MOUSE_FOCUS; break;
    case 1006: t->mouse_flags&=~MOUSE_SGR; break;
    case 1007: t->mouse_flags&=~MOUSE_ALT_SCROLL; break;
    case 2004: t->bracketed_paste=0; break;
    case   47: term_restore_screen(t); break;
    case 1047: term_restore_screen(t); break;
    case 1048: cf_DECRC(t); break;
    case 1049: term_restore_screen(t); cf_DECRC(t); break;
#if PRINT_UNHANDLED
    default: printf("unhandled: DECRST mode %d\n",*p); break;
#endif
    }
  }
}

/* Device Status Report (DSR) : ESC [ Ps... n */
static void cf_DSR(struct term *restrict const t,
  const int *restrict p, int n)
{
  #define BUF (char*)t->feedback_buffer+t->feedback_len, \
                     MAX_ESCAPE-t->feedback_len

  const int *end=p+n;
  for(;p!=end;++p) {
    int len = 0;
    switch(*p) {
    case  5: /* Status Report */
      len = snprintf(BUF,"%s","\033[0n");  /* "OK" */
      break;
    case 6: /* Report Cursor Position */
      len = snprintf(BUF,"\033[%d;%dR",
        abs_row(t,t->cursor.row)+1, t->cursor.col+1);
      break;
#if PRINT_UNHANDLED
    default: printf("unhandled: DSR %d\n",*p); break;
#endif
    }
    if(len) t->feedback_len = t->feedback_len+len > MAX_ESCAPE ? MAX_ESCAPE
                            : t->feedback_len+len;
  }
  #undef BUF
}

/*----------------------------------------------------------------------------
  Character Processing
  ----------------------------------------------------------------------------*/

static unsigned count_graphic(
  const uchar *restrict const start,
  const uchar *restrict const end)
{
  const uchar *p=start;
  while(p!=end && *p>=0x20u) ++p;
  return p-start;
}

/* start!=end && *start>=' ' */
static const uchar *proc_graphic(
  struct term *restrict const t,
  const uchar *restrict const start,
  const uchar *restrict const end)
{
  struct read_utf8_state r = { 0, utf8_state_ilzr, 0 };
  r.s = t->utf8_state;
  r.pos = start;
  r = read_utf8(r,end);
  if(r.s.n!=0 || r.c<0x20u) goto proc_graphic_end;
  {
  const struct gr *restrict const gr = &t->cursor.gr;
  struct line *restrict const line = synch_pos(t,1);
  struct cell *restrict cell =
    array_reserve(struct cell,&line->beg,line->beg.n+(end-start))
      + line->beg.n;
  int w = 0;
  if(!t->linedraw) {
    for(;;) {
      int cw = char_width(r.c,0);
      cell->code = r.c, cell->gr = *gr, set_cell_w(*cell, cw);
      w += cw, ++cell;
      if(r.pos==end || *r.pos<0x20u) break;
      r = read_utf8(r,end);
      if(r.s.n!=0 || r.c<0x20u) break;
    }
  } else {
    for(;;) {
      int cw;
      if(r.c>=ACS_MAP_HIGH_START && r.c<ACS_MAP_HIGH_START+ACS_MAP_HIGH_N)
        cell->code = acs_map_high[r.c-ACS_MAP_HIGH_START], cw=1;
      else if(r.c>=ACS_MAP_LOW_START && r.c<ACS_MAP_LOW_START+ACS_MAP_LOW_N)
        cell->code = acs_map_low[r.c-ACS_MAP_LOW_START], cw=1;
      else
        cell->code = r.c, cw = char_width(r.c,0);
      cell->gr = *gr, set_cell_w(*cell, cw);
      w += cw, ++cell;
      if(r.pos==end || *r.pos<0x20u) break;
      r = read_utf8(r,end);
      if(r.s.n!=0 || r.c<0x20u) break;
    }
  }
#if PRINT_ESC
  fputs("graphic: ",stdout);
  fwrite(start,1,r.pos-start,stdout);
  fputc('\n',stdout);
#endif
  line->beg.n = cell - (struct cell*)line->beg.ptr;
  line->col += w, t->cursor.col += w;
  if(!(t->mode&MODE_INSERT)) line_del_right(line,w);
  }
  proc_graphic_end: t->utf8_state = r.s; return r.pos;
}

static const uchar *proc_normal(
  struct term *restrict const t,
  const uchar *restrict start,
  const uchar *restrict const end)
{
  const uchar c = *start;
  if(t->utf8_state.n || c>=0x20u) return proc_graphic(t,start,end);
#if PRINT_ESC
  if(c!=033) printf("control char %o\n",(unsigned)c);
#endif
  switch(c) {
    case 007: /* BEL */ break;
    case 010: cf_BS(t); break;
    case 011: cf_HT(t); break;
    case 012: cf_LF(t); break;
    case 015: cf_CR(t); break;
    case 016: cf_SO(t); break;
    case 017: cf_SI(t); break;
    case 033: t->state=STATE_ESC; break;
#if PRINT_UNHANDLED
    default: printf("unhandled: \\%03o \n",(unsigned char)c); break;
#endif
  }
  return ++start;
}

/* Escape (ESC) : ESC */
static const uchar *proc_ESC(
  struct term *restrict const t,
  const uchar *restrict start,
  const uchar *restrict const end)
{
  t->state=STATE_NORMAL;
#if PRINT_ESC
  if(*start!='[' && *start!=']') printf("ESC %c\n", *start);
#endif
  switch(*start) {
    case '7': cf_DECSC(t); break;
    case '8': cf_DECRC(t); break;
    case '=': cf_DECKPAM(t); break;
    case '>': cf_DECKPNM(t); break;
    case '(': case ')': case '*': case '+': case '$':
      t->state=STATE_CHAR_SET, esc_buf(t)[0]=*start; break;
    case 'M': cf_RI(t); break;
    case 'c': cf_RIS(t); break;
    case '[': t->state=STATE_CSI, t->escape_buf.n=0; break;
    case ']': t->state=STATE_XTERM, t->escape_buf.n=t->escape_escape=0; break;
#if PRINT_UNHANDLED
    default: printf("unhandled: ESC %x\n",*start); break;
#endif
  }
  return ++start;
}

/* Kitty keyboard protocol : CSI = flags ; mode u */
static void cf_kitty_kb_set(struct term *restrict const t,
  const int *restrict p, int n)
{
  int flags = n>=1 && p[0]>=0 ? p[0] : 0;
  int mode  = n>=2 && p[1]>=0 ? p[1] : 1;
  switch(mode) {
  case 1: t->kitty_kb_flags =   flags & 0x1f;  break;
  case 2: t->kitty_kb_flags |=  flags & 0x1f;  break;
  case 3: t->kitty_kb_flags &= ~(flags & 0x1f); break;
  }
}

/* Kitty keyboard protocol : CSI ? u */
static void cf_kitty_kb_query(struct term *restrict const t)
{
  int len = snprintf((char*)t->feedback_buffer+t->feedback_len,
                     MAX_ESCAPE-t->feedback_len,
                     "\033[?%uu", t->kitty_kb_flags);
  if(len>0) t->feedback_len = t->feedback_len+len > MAX_ESCAPE ? MAX_ESCAPE
                             : t->feedback_len+len;
}

/* Kitty keyboard protocol : CSI > flags u */
static void cf_kitty_kb_push(struct term *restrict const t,
  const int *restrict p, int n)
{
  int flags = n>=1 && p[0]>=0 ? p[0] : 0;
  if(t->kitty_kb_stack_n>=KITTY_KB_STACK_MAX)
    memmove(t->kitty_kb_stack, t->kitty_kb_stack+1, KITTY_KB_STACK_MAX-1),
    --t->kitty_kb_stack_n;
  t->kitty_kb_stack[t->kitty_kb_stack_n++] = t->kitty_kb_flags;
  t->kitty_kb_flags = flags & 0x1f;
}

/* Kitty keyboard protocol : CSI < number u */
static void cf_kitty_kb_pop(struct term *restrict const t,
  const int *restrict p, int n)
{
  int count = n>=1 && p[0]>=0 ? p[0] : 1;
  if(count>(int)t->kitty_kb_stack_n) count=t->kitty_kb_stack_n;
  if(count>0) {
    t->kitty_kb_stack_n -= count;
    t->kitty_kb_flags = t->kitty_kb_stack_n
      ? t->kitty_kb_stack[t->kitty_kb_stack_n-1] : 0;
  }
}

static int parse_CSI(const uchar *restrict str, int *restrict param)
{
  int n=0;
  param[0]=-1;
  for(;;) {
    uchar c=*str++;
    switch(c) {
    case 0: return n+(param[n]==-1?0:1);
    case ';': ++n, param[n]=-1; break;
    default: param[n]=param[n]==-1?(c-'0'):param[n]*10+(c-'0'); break;
    }
  }
}

static void proc_CSI_final(struct term *restrict const t, const uchar c)
{
  static int param[MAX_ESCAPE/2];
  int dec=0, n;
  const uchar *restrict str = esc_buf(t);
       if(*str=='?') dec=1,++str;
  else if(*str=='!') dec=2,++str;
  else if(*str=='=') dec=3,++str;
  else if(*str=='>') dec=4,++str;
  else if(*str=='<') dec=5,++str;
  n=parse_CSI(str,param);
#if PRINT_ESC
  printf("ESC [ %s %c\n",esc_buf(t),c);
#endif
  if(!dec) {
    switch(c) {
      case '@': cf_ICH(t,param,n); break;
      case 'A': case 'B': case 'C': case 'D': case 'E':
      case 'F': case 'G': case 'H':
      case '`': case 'a': case 'd': case 'e': case 'f':
        cf_cursor_move(t,param,n,c); break;
      case 'J': cf_ED (t,param,n); break;
      case 'K': cf_EL (t,param,n); break;
      case 'L': cf_IL (t,param,n); break;
      case 'M': cf_DL (t,param,n); break;
      case 'P': cf_DCH(t,param,n); break;
      case 'S': cf_SU (t,param,n); break;
      case 'T': cf_SD (t,param,n); break;
      case 'X': cf_ECH(t,param,n); break;
      case 'h': cf_SM (t,param,n); break;
      case 'l': cf_RM (t,param,n); break;
      case 'm': cf_SGR(t,param,n); break;
      case 'n': cf_DSR(t,param,n); break;
      case 'r': cf_DECSTBM(t,param,n); break;
      case 's': cf_DECSC(t); break;
      case 'u': cf_DECRC(t); break;
#if PRINT_UNHANDLED
      default:
        printf("ESC [ %s\n  f=%c\n",esc_buf(t),c);
        printf("unhandled: ESC [ ");
        { int i; for(i=0;i<n;++i) printf("%d ",param[i]); }
        printf("%c \n",c);
#endif
    }
  } else if(dec==1) {
    switch(c) {
      case 'h': cf_DECSET(t,param,n); break;
      case 'l': cf_DECRST(t,param,n); break;
      case 'u': cf_kitty_kb_query(t); break;
#if PRINT_UNHANDLED
      default:
        printf("unhandled: ESC [? ");
        { int i; for(i=0;i<n;++i) printf("%d ",param[i]); }
        printf("%c \n",c);
#endif
    }
  } else if(dec==2) {
    switch(c) {
      case 'p': soft_reset(t); break;
#if PRINT_UNHANDLED
      default:
        printf("unhandled: ESC [! ");
        { int i; for(i=0;i<n;++i) printf("%d ",param[i]); }
        printf("%c \n",c);
#endif
    }
  } else if(dec==3) {
    switch(c) {
      case 'u': cf_kitty_kb_set(t,param,n); break;
    }
  } else if(dec==4) {
    switch(c) {
      case 'u': cf_kitty_kb_push(t,param,n); break;
    }
  } else if(dec==5) {
    switch(c) {
      case 'u': cf_kitty_kb_pop(t,param,n); break;
    }
  }
}

/* Control Sequence Introducer (CSI) : ESC [ */
static const uchar *proc_CSI(
  struct term *restrict const t,
  const uchar *restrict start,
  const uchar *restrict const end)
{
  #define PUT_IN_ESC_BUFFER(cond) do { \
  if(cond) { \
    unsigned el=t->escape_buf.n, len=end-start, max=MAX_ESCAPE-el; \
    const uchar *const stop = start+(len>max?max:len); \
    while(start!=stop && cond) esc_buf(t)[el++]=*start++; \
    t->escape_buf.n=el; \
    if(start==end) return start; \
    while(cond) if(++start==end) return start; \
  } } while(0)
  PUT_IN_ESC_BUFFER((*start&0x40u)==0);
  t->state=STATE_NORMAL;
  if(t->escape_buf.n!=MAX_ESCAPE) {
    esc_buf(t)[t->escape_buf.n]=0;
    proc_CSI_final(t,*start);
  }
#if PRINT_UNHANDLED
  else printf("unhandled CSI sequence (length > %d)\n",MAX_ESCAPE);
#endif
  return ++start;
}

static int b64_val(uchar c)
{
  if(c>='A' && c<='Z') return c-'A';
  if(c>='a' && c<='z') return c-'a'+26;
  if(c>='0' && c<='9') return c-'0'+52;
  if(c=='+') return 62;
  if(c=='/') return 63;
  return -1;
}

/* decode base64; returns decoded length */
static unsigned b64_decode(uchar *restrict out,
  const uchar *restrict src, unsigned len)
{
  uchar *p = out;
  unsigned i;
  for(i=0; i+3<len; i+=4) {
    int a=b64_val(src[i]), b=b64_val(src[i+1]);
    if(a<0||b<0) break;
    *p++ = (a<<2)|(b>>4);
    if(src[i+2]!='=') {
      int c=b64_val(src[i+2]); if(c<0) break;
      *p++ = (b<<4)|(c>>2);
      if(src[i+3]!='=') {
        int d=b64_val(src[i+3]); if(d<0) break;
        *p++ = (c<<6)|d;
      }
    }
  }
  return (unsigned)(p - out);
}

/* xterm sequence : ESC ] */
static const uchar *proc_xterm(
  struct term *restrict const t,
  const uchar *restrict start,
  const uchar *restrict const end)
{
  unsigned el=t->escape_buf.n;
  unsigned seen_esc=t->escape_escape;
  for(;;) {
    const uchar c = *start;
    if(c==7 || (seen_esc && c=='\\')) break;
    seen_esc = c==033;
    if(!seen_esc) { buffer_reserve(&t->escape_buf,el+1); esc_buf(t)[el++]=c; }
    if(++start==end) {
      t->escape_buf.n=el;
      t->escape_escape=seen_esc;
      return start;
    }
  }
  t->state=STATE_NORMAL;
  { int p; uchar *restrict str;
    buffer_reserve(&t->escape_buf,el+1);
    str=esc_buf(t);
    str[el]=0;
    p = atoi((char*)str);
    while(*str && *str!=';') ++str;
    if(*str) ++str;
    switch(p) {
      case 0: case 1: case 2:
        if(el-(unsigned)(str-esc_buf(t)) < MAX_ESCAPE)
          strcpy((char*)t->name,(const char*)str), t->name_change=1;
        break;
      case 52: {
        /* OSC 52 ; Ps ; Pd ST — clipboard set
           Ps = selection: c=clipboard, p=primary, s=select, or combo
           Pd = base64-encoded data */
        uchar sel = 1; /* default to clipboard */
        uchar *data; unsigned dlen;
        while(*str && *str!=';') {
          if(*str=='p') sel=0;
          else if(*str=='c') sel=1;
          ++str;
        }
        if(*str) ++str;
        dlen = el-(unsigned)(str-esc_buf(t));
        data = tmalloc(uchar, (dlen*3)/4+3);
        dlen = b64_decode(data, str, dlen);
        free(t->osc52_data);
        t->osc52_data = data;
        t->osc52_len = dlen;
        t->osc52_sel = sel;
      } break;
#if PRINT_UNHANDLED
      default: printf("xterm sequence %d \"%s\" ignored\n", p, str); break;
#endif
    }
  }
  return ++start;
}

/* ISO 2022 character set selection : ESC (,),*,+,$ c */
static const uchar *proc_char_set(
  struct term *restrict const t,
  const uchar *restrict start,
  const uchar *restrict const end)
{
  int g=0;
  t->state=STATE_NORMAL;
  switch(esc_buf(t)[0]) {
  case '(': g=0; break;
  case ')': g=1; break;
  case '*': g=2; break;
  case '+': g=3; break;
  default:
#if PRINT_UNHANDLED
    printf("unhandled: ESC %c %c\n",esc_buf(t)[0],*start);
#endif
    return ++start;
  }
  switch(*start) {
  case '0': t->G[g]=1; break;
  case 'A': case 'B': t->G[g]=0; break;
  }
  t->linedraw=t->G[(int)t->curG];
  return ++start;
}

void term_proc(
  struct term *restrict const t,
  const uchar *restrict start,
  const uchar *restrict const end)
{
  do {
    switch(t->state) {
    case STATE_NORMAL:   start=proc_normal  (t,start,end); break;
    case STATE_ESC:      start=proc_ESC     (t,start,end); break;
    case STATE_CSI:      start=proc_CSI     (t,start,end); break;
    case STATE_XTERM:    start=proc_xterm   (t,start,end); break;
    case STATE_CHAR_SET: start=proc_char_set(t,start,end); break;
    }
  } while(start!=end);
}
