#define _XOPEN_SOURCE
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include "c99.h"
#include "mem.h"
#include "utf-8.h"
#include "sysbuf.h"
#include "term.h"
#include "emoji_props.h"
#include "char_width.h"
#include "cluster.h"

#define MAX_BREAK 128
/* offset in wrap_break is relative to half_buffer.data.ptr
   or the cell number of the line, starting at 0 */
struct wrap_break { unsigned off, col; struct gr gr; };

static inline int is_space(uint32 c) { return c==ENC_TAB||iswspace(c); }
static inline int is_alnum(uint32 c) { return c==95/*_*/||iswalnum(c); }

struct wrap_pos { unsigned scol; uint32 ch; struct wrap_break b; };

struct wrap_state {
  unsigned brkn;
  struct wrap_pos cur, last_br_sp, last_br_wd;
};
#define init_wrap_state {0,{0,0,{0,0,default_gr}}, \
                           {0,0,{0,0,default_gr}}, \
                           {0,0,{0,0,default_gr}}}

static struct wrap_state calc_enc(
  struct wrap_break *restrict const brk, const unsigned max,
  struct wrap_state st, const int wrap_mode,
  const unsigned minw, const unsigned maxw,
  const uchar *restrict pos)
{
  #define NOT_AT_END() *pos!=ENC_NL
  #define READ_CH() { \
     struct read_utf8_fast r; \
     if(is_gr_encoding(*pos)) { \
       unsigned n = gr_decode(&st.cur.b.gr, pos); \
       pos+=n, st.cur.b.off+=n; \
       continue; \
     } else if(*pos==ENC_CLUSTER_REF) { \
       unsigned consumed; unsigned idx; \
       idx = varint_decode(pos+1, &consumed); \
       st.cur.ch = CLUSTER_BIT | cluster_cell_bits(idx) | idx; \
       st.cur.b.off += 1 + consumed; \
       pos += 1 + consumed; \
     } else \
       r=read_utf8_fast(pos,0), st.cur.ch=r.c, st.cur.b.off+=r.i, pos+=r.i; \
  }
  #define WRAP_BODY(mode) do { \
    const unsigned hw = (maxw+1)/2; \
    struct wrap_pos prev = st.cur; \
    while(NOT_AT_END()) { \
      unsigned w; \
      READ_CH(); \
      w = char_width(st.cur.ch, st.cur.b.col); \
      if(w==0) { prev=st.cur; continue; } \
      st.cur.b.col+=w, st.cur.scol+=w; \
      if(mode) { \
        if(is_space(prev.ch)/*||is_space(st.cur.ch)*/) st.last_br_sp=prev; \
        if(!(is_alnum(prev.ch)&&is_alnum(st.cur.ch))) st.last_br_wd=prev; \
      } \
      if(mode==2) prev=st.last_br_wd; \
      if(prev.scol>=minw && st.cur.scol>maxw \
         && (mode!=1 || !is_space(st.cur.ch)) ) { \
        if(mode==1) { \
          if(st.last_br_wd.scol>=hw) { \
            prev = st.last_br_wd; \
            if(st.last_br_sp.scol>=hw \
               && (  prev.scol - st.last_br_sp.scol < maxw - prev.scol \
                   ||(maxw - st.last_br_sp.scol)*8 < maxw)) \
              prev = st.last_br_sp; \
          } \
        } \
        brk[st.brkn++] = prev.b; \
        if(st.brkn==max) return st; \
        st.cur.scol -= prev.scol; \
        st.last_br_wd.scol=st.last_br_sp.scol=0; \
      } \
      prev = st.cur; \
    } \
    brk[st.brkn] = st.cur.b; \
    return st; \
  } while(0)
  #define WRAP_CASE() do { \
    switch(wrap_mode) { \
    case 0: WRAP_BODY(0); break; \
    case 1: WRAP_BODY(1); break; \
    case 2: WRAP_BODY(2); break; \
    default: fprintf(stderr,"wrap_calc: unexpected\n"), abort(); \
    } \
  } while(0)
  WRAP_CASE();
  #undef READ_CH
  #undef NOT_AT_END
}

static struct wrap_state calc_cells(
  struct wrap_break *restrict const brk, const unsigned max,
  struct wrap_state st, const int wrap_mode,
  const unsigned minw, const unsigned maxw,
  const struct cell *restrict pos, unsigned cn, const int step)
{
  #define NOT_AT_END() cn
  #define READ_CH() st.cur.ch=pos->code, pos+=step, --cn, ++st.cur.b.off
  WRAP_CASE();
  #undef WRAP_CASE
  #undef WRAP_BODY
  #undef READ_CH
  #undef NOT_AT_END
}

static unsigned calc_buf(
  struct wrap_break *restrict const brk, const unsigned max,
  const int mode, const unsigned minw, const unsigned maxw,
  const uchar *restrict const base, unsigned off)
{
  struct wrap_state st = init_wrap_state;
  st.cur.b.off = off;
  st=calc_enc(brk,max,st,mode,minw,maxw,base+off);
  return st.brkn;
}

static unsigned calc_line(
  struct wrap_break *restrict const brk, const unsigned max,
  const int mode, const unsigned minw, const unsigned maxw,
  const struct line *restrict const line)
{
  struct wrap_state st = init_wrap_state;
  st=calc_cells(brk,max,st,mode,minw,maxw,line->beg.ptr,line->beg.n,1);
  if(st.brkn!=max && line->end.n)
  st=calc_cells(brk,max,st,mode,minw,maxw,
                (const struct cell*)line->end.ptr+line->end.n-1,line->end.n,-1);
  return st.brkn;
}

unsigned wrap_calc(
  struct wrap_break *restrict const brk, const unsigned max,
  const struct term *const restrict t, const int r,
  const int mode, const unsigned minw, const unsigned maxw)
{
  if(r==0)
    return calc_line(brk,max, mode,minw,maxw,t->margin.ptr);
  else {
    unsigned ar; const struct half_buffer *restrict hb;
    if(r>0) ar= r,hb=&t->buf.end;
       else ar=-r,hb=&t->buf.beg;
    if(ar>hb->lines.n) {
      if(max) { const struct wrap_break db = {0,0,default_gr};
                *brk = db; }
      return 0;
    } else return
      calc_buf(brk,max, mode,minw,maxw, hb->data.ptr,
        half_buffer_line_off(hb,hb->lines.n-ar));
  }
}

static inline unsigned calc(
  struct wrap_break *restrict const brk,
  const struct term *const restrict t, const int r,
  const int mode)
{
  return wrap_calc(brk,MAX_BREAK,t,r,mode,1,t->w);
}

/* line==0 means the very first line of term->buf.beg */
struct scroll_pos { unsigned line, col; };

/* line==0 means the active line (term->margin.ptr) */
struct subline { int line; unsigned sub; };

struct wrap_line { unsigned short nsub, brki; };
struct wrap_breaks {
  int dirty;
  struct subline vtop, vbot; /* displayed line range when not scrolled up */
  struct subline dtop, dbot; /* displayed line range */
  struct array /* of struct wrap_line  */ lines;
  struct array /* of struct wrap_break */ brks;
};

static unsigned find_vtop(
  struct wrap_breaks *restrict const p,
  const struct term *restrict const t,
  const unsigned wrap_mode)
{
  int dh = t->h - (t->mt+t->mb);
  p->vtop.line =   -t->line_row, p->vtop.sub = 0;
  if(!wrap_mode || t->alt_screen) {
    int i;
    struct wrap_line *restrict const line =
      array_reserve(struct wrap_line, &p->lines, dh);
    p->vbot.line = dh-t->line_row, p->vbot.sub = 0;
    for(i=0;i<dh;++i) line[i].nsub=1;
    p->lines.n=dh;
    return 0;
  } else {
    const int mode = wrap_mode==2;
    struct wrap_line *restrict const line =
      array_reserve(struct wrap_line, &p->lines, dh);
    struct wrap_break *restrict const brk =
      array_reserve(struct wrap_break, &p->brks, dh+2*MAX_BREAK);
    unsigned li=0, bi=0;
    const int min = -t->line_row;
    int r, bot = dh - t->line_row;
    if(1+(int)t->buf.end.lines.n<bot) bot=1+(int)t->buf.end.lines.n;
    if(bot<min) bot=min;
    p->vbot.line=bot, p->vbot.sub=0;
    r=bot;
    while(dh>0 && r>min) {
      unsigned nbrk = calc(brk+bi, t,--r,mode);
      line[li].nsub=nbrk+1, line[li].brki=bi;
      dh-=nbrk+1, ++li, bi+=nbrk;
    }
    p->vtop.line=r, p->vtop.sub = dh<0 ? -dh : 0;
    p->lines.n = (bot-=r);
    for(r=0;r<bot/2;++r) {
      struct wrap_line tmp=line[r]; line[r]=line[bot-1-r]; line[bot-1-r]=tmp;
    }
    return p->vtop.sub>0 ? brk[line[0].brki+p->vtop.sub-1].col : 0;
  }
}

static unsigned sub_from_col(
  const struct wrap_break *restrict const brk, const int nsub,
  const unsigned col)
{
  unsigned lo=0,hi=nsub-1;
  while(lo<hi) {
    unsigned m = lo + (hi-lo)/2;
    if(col<brk[m].col) {
      if(m==0 || brk[m-1].col<=col) return m;
      else hi=m;
    } else lo=m+1;
  }
  return nsub-1;
}

static void find_dtop(
  struct wrap_breaks *restrict const p,
  struct scroll_pos *restrict const scroll,
  const struct term *restrict const t,
  const unsigned wrap_mode,
  int h)
{
  struct wrap_line *restrict const line =
    array_reserve(struct wrap_line, &p->lines, h);
  p->dtop.line = (int)scroll->line-(int)t->buf.beg.lines.n;
  if(!wrap_mode) {
    p->dtop.sub=0; p->dbot.sub=0;
    if(p->vtop.line - p->dtop.line >= h)
      p->dbot.line=p->dtop.line+h;
    else {
      p->dbot.line=p->vtop.line;
      h -= p->vtop.line-p->dtop.line;
      if(h>t->mt) p->dbot.line += h-t->mt;
    }
    p->lines.n = p->dbot.line-p->dtop.line;
    for(h=0;h<(int)p->lines.n;++h) line[h].nsub=1;
  } else {
    const int mode = wrap_mode==2;
    struct wrap_break *restrict const brk =
      array_reserve(struct wrap_break, &p->brks, t->h+2*MAX_BREAK);
    unsigned li=0, bi=0, nsub;
    int r = p->dtop.line;
    unsigned nbrk = calc(brk+bi, t,r,mode);
    line[li].nsub=nbrk+1, line[li].brki=bi;
    ++li, bi+=nbrk;
    p->dtop.sub = sub_from_col(brk,nbrk+1,scroll->col);
    scroll->col = p->dtop.sub>0 ? brk[p->dtop.sub-1].col : 0;
    nsub = (nbrk+1) - p->dtop.sub;
    while(h>=(int)nsub) {
      h-=nsub, ++r;
      if(r==p->vtop.line) h-=t->mt;
      if(h<=0) { h=0; break; }
      nbrk = calc(brk+bi, t,r,mode);
      line[li].nsub=nsub=nbrk+1, line[li].brki=bi;
      ++li, bi+=nbrk;
    }
    p->dbot.line=r, p->dbot.sub=h; p->lines.n=li;
    if(p->dbot.line==p->dtop.line) p->dbot.sub+=p->dtop.sub;
  }
}


void wrap_update(
  struct wrap_breaks *restrict const p,
  struct scroll_pos *restrict const scroll,
  const struct term *restrict const t,
  const unsigned wrap_mode,
  unsigned h)
{
  unsigned topcol = find_vtop(p,t,wrap_mode);
  if(scroll->line!=-1u) {
    int dif = (int)t->buf.beg.lines.n+p->vtop.line - (int)scroll->line;
    if(t->alt_screen || dif<0 || (dif==0 && scroll->col>=topcol))
      scroll->line=-1u, scroll->col=0;
  }
  if(scroll->line==-1u) p->dtop=p->vtop, p->dbot=p->vbot;
  else find_dtop(p,scroll,t,wrap_mode,h);
  p->dirty=0;
}

int wrap_scroll(
  struct scroll_pos *restrict const scroll,
  struct wrap_breaks *restrict const p,
  const struct term *restrict const t,
  const unsigned wrap_mode,
  int n)
{
  const int mode = wrap_mode==2;
  struct subline sl; unsigned nsub=0;
  struct wrap_break *restrict brk;
  if(n==0 || scroll->line==-1u && (n>0 || t->alt_screen)) return 0;
  if(t->alt_screen) {
    scroll->line=-1u, scroll->col=0;
    p->dirty=1;
    return 1;
  }
  if(p->dirty) wrap_update(p,scroll,t,wrap_mode,1);
  p->dirty=1;
  brk = p->brks.ptr;
  sl=p->dtop, nsub=1;
  if(wrap_mode) nsub+=calc(brk,t,sl.line,mode);
  if(!wrap_mode) sl.line+=n;
  else if(n<0) {
    unsigned m=-n;
    for(;;) if(sl.sub>=m) { sl.sub-=m; break; }
            else m-=sl.sub+1,nsub=1+(sl.sub=calc(brk,t,--sl.line,mode));
  } else {
    unsigned m=n;
    if(nsub==0) fprintf(stderr, "wrap_scroll: unexpected\n"), abort();
    for(;;) if(sl.sub+m<nsub) { sl.sub+=m; break; }
            else {
              m-=nsub-sl.sub,++sl.line,sl.sub=0;
              if(m==0) { nsub=0; break; }
              else nsub=1+calc(brk,t,sl.line,mode);
            }
  }
  if(sl.line + (int)t->buf.beg.lines.n >= 0) {
    scroll->line = sl.line + (int)t->buf.beg.lines.n;
    if(sl.sub && nsub==0) fprintf(stderr, "wrap_scroll: unexpected (2)\n"), abort();
    scroll->col = sl.sub==0 ? 0 : brk[sl.sub-1].col;
  } else
    scroll->line = 0, scroll->col = 0;
  return 1;
}
