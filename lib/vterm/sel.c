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
#include "wrap.h"
#include "sel.h"

struct sel_desc sel_fix(
  const struct term *const restrict t,
  struct scroll_pos b, struct scroll_pos e)
{
  struct sel_desc out;
  if(e.line<b.line || e.line==b.line&&e.col<b.col) {
    struct scroll_pos t=b; b=e; e=t;
  }
  out.b.line = (int)b.line-(int)t->buf.beg.lines.n;
  out.e.line = (int)e.line-(int)t->buf.beg.lines.n;
  wrap_calc(&out.b.pos,1, t,out.b.line, 0,0,b.col);
  wrap_calc(&out.e.pos,1, t,out.e.line, 0,e.col,0);
  return out;
}

struct sel_desc sel_word(
  const struct term *const restrict t, int r, float col)
{
  struct sel_desc out;
  out.b.line = out.e.line = r;
  wrap_calc(&out.b.pos,1, t,r, 2,0,floor(col));
  wrap_calc(&out.e.pos,1, t,r, 2,ceil(col),0);
  return out;
}

static uchar *copy_enc(uchar *restrict out, const uchar *restrict pos, int len)
{
  #define WRITE_CH(code) put_utf8(out,code)
  #define COPY_BODY() do { \
    struct gr gr = default_gr_ilzr; \
    while(len>0 && *pos!=ENC_NL) { \
      struct read_utf8_fast r; \
      if(is_gr_encoding(*pos)) { \
        int n = gr_decode(&gr, pos); \
        pos += n, len-= n; \
      } else if(*pos==ENC_TAB) ++pos, --len, out=WRITE_CH(9); \
      else r=read_utf8_fast(pos,0), out=WRITE_CH(r.c), len-=r.i, pos+=r.i; \
    } \
    return out; \
  } while(0)
  COPY_BODY();
  #undef WRITE_CH
}

static unsigned copy_enc_count(const uchar *restrict pos, int len)
{
  unsigned out=0;
  #define WRITE_CH(code) (out+utf8_bytes(code))
  COPY_BODY();
  #undef WRITE_CH
  #undef COPY_BODY
}

static uchar *copy_cells(uchar *restrict out,
  const struct cell *restrict pos, unsigned cn, const int step)
{
  while(cn) {
    if(pos->code==ENC_TAB) *out++=9; else out=put_utf8(out,pos->code);
    pos+=step, --cn;
  }
  return out;
}

static unsigned copy_cells_count(
  const struct cell *restrict pos, unsigned cn, const int step)
{
  unsigned out=0;
  while(cn) out+=utf8_bytes(pos->code), pos+=step, --cn;
  return out;
}

static uchar *copy_line(uchar *restrict out,
  const struct line *restrict const line, const unsigned b, const int ue)
{
  #define COPY_CELLS(p,n,s) out=copy_cells(out,p,n,s)
  #define END_CELL ((const struct cell*)line->end.ptr+line->end.n-1)
  #define COPY_LINE() do { \
    const unsigned e = (ue == -1) ? line->beg.n+line->end.n : (unsigned)ue; \
    if(line->beg.n > b) { \
      const struct cell *p = line->beg.ptr; p+=b; \
      if(line->beg.n >= e) \
        COPY_CELLS(p, e-b, 1); \
      else \
        COPY_CELLS(p, line->beg.n-b, 1), \
        COPY_CELLS(END_CELL, e-line->beg.n, -1); \
    } else \
      COPY_CELLS(END_CELL - (b-line->beg.n), e-b, -1); \
    return out; \
  } while(0)
  COPY_LINE();
  #undef COPY_CELLS
}

static unsigned copy_line_count(
  const struct line *restrict const line, const unsigned b, const int ue)
{
  unsigned out=0;
  #define COPY_CELLS(p,n,s) out+=copy_cells_count(p,n,s)
  COPY_LINE();
  #undef COPY_CELLS
  #undef COPY_LINE
  #undef END_CELL
}

static uchar *copy_tl(uchar *restrict out,
  const struct term *const restrict t, const int r,
  const int be, const int ue)
{
  #define COPY_LINE(l,b,e) copy_line(out, l,b,e)
  #define COPY_ENC(d,n) copy_enc(out, d,n)
  #define COPY_BODY() do { \
    if(r==0) \
      return COPY_LINE(t->margin.ptr, be==-1?0:(unsigned)be,ue); \
    else { \
      unsigned ar; const struct half_buffer *restrict hb; \
      if(r>0) ar= r,hb=&t->buf.end; \
         else ar=-r,hb=&t->buf.beg; \
      if(ar>hb->lines.n) return out; \
      else { \
        const unsigned b = be >= 0 ? (unsigned)be : \
          half_buffer_line_off(hb,hb->lines.n-ar);\
        return COPY_ENC(array_data(const uchar,&hb->data)+b, \
          ue==-1 ? hb->data.n-b : (unsigned)ue-b); \
      } \
    } \
  } while(0)
  COPY_BODY();
  #undef COPY_ENC
  #undef COPY_LINE
}

static unsigned copy_tl_count(
  const struct term *const restrict t, const int r,
  const int be, const int ue)
{
  unsigned out=0;
  #define COPY_LINE(l,b,e) copy_line_count(l,b,e)
  #define COPY_ENC(d,n) copy_enc_count(d,n)
  COPY_BODY();
  #undef COPY_ENC
  #undef COPY_LINE
  #undef COPY_BODY
}

/*struct sel_pos { int line; struct wrap_break pos; };
struct sel_desc { struct sel_pos b,e; };*/

static uchar *copy(uchar *restrict out,
  const struct term *const restrict t, const struct sel_desc sel)
{
  #define COPY_TL(r,b,e) out=copy_tl(out,t,r,b,e)
  #define COPY_NL() *out++ = 10
  #define COPY_BODY() do { \
    if(sel.b.line==sel.e.line) \
      COPY_TL(sel.b.line,sel.b.pos.off,sel.e.pos.off); \
    else { \
      int r; \
      COPY_TL(sel.b.line,sel.b.pos.off,-1), COPY_NL();\
      for(r=sel.b.line+1;r<sel.e.line;++r) COPY_TL(r,-1,-1), COPY_NL(); \
      COPY_TL(sel.e.line,-1,sel.e.pos.off); \
    } \
    return out; \
  } while(0)
  COPY_BODY();
  #undef COPY_NL
  #undef COPY_TL
}

static unsigned copy_count(
  const struct term *const restrict t, const struct sel_desc sel)
{
  unsigned out=0;
  #define COPY_TL(r,b,e) out+=copy_tl_count(t,r,b,e)
  #define COPY_NL() ++out
  COPY_BODY();
  #undef COPY_NL
  #undef COPY_TL
  #undef COPY_BODY
}

uchar *sel_get(const struct term *const restrict t, const struct sel_desc sel)
{
  unsigned count = copy_count(t,sel)+1;
  uchar *buffer = tmalloc(uchar, count);
  *copy(buffer, t,sel)=0;
  return buffer;
}
