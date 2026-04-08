#ifndef UTF_8_H
#define UTF_8_H

#ifndef C99_H
#warning "utf-8.h" requires "c99.h"
#endif

typedef unsigned char  uchar;

struct utf8_state { uchar c[4]; int n; };
#define utf8_state_ilzr { {0,0,0,0}, 0 }

static inline int utf8_bytes(const uint32 code)
{
  return code<0x00080u ? 1 : (
         code<0x00800u ? 2 : (
         code<0x10000u ? 3 : 4));
}

static uchar *put_utf8(uchar *out, const uint32 code)
{
  if(code<0x80u)
    *out++ = code;
  else if(code<0x800u)
    *out++ = 0xc0u | code>>6,
    *out++ = 0x80u | (code&0x3fu);
  else if(code<0x10000u)
    *out++ = 0xe0u | code>>12,
    *out++ = 0x80u | (code>>6 & 0x3fu),
    *out++ = 0x80u | (code    & 0x3fu);
  else
    *out++ = 0xf0u | (code>>18 & 0x07u),
    *out++ = 0x80u | (code>>12 & 0x3fu),
    *out++ = 0x80u | (code>>6  & 0x3fu),
    *out++ = 0x80u | (code     & 0x3fu);
  return out;
}

struct read_utf8_fast { uint32 c; unsigned i; };
static inline struct read_utf8_fast
  read_utf8_fast(const uchar *restrict const base, unsigned i)
{
  struct read_utf8_fast o;
  const uint32 b0 = base[i],
               b1 = base[i+1]&0x3fu,
               b2 = base[i+2]&0x3fu,
               b3 = base[i+3]&0x3fu;
  
       if(b0<0x80) o.i=i+1, o.c = b0;
  else if(b0<0xe0) o.i=i+2, o.c = (b0&0x1f)<<6  | b1;
  else if(b0<0xf0) o.i=i+3, o.c = (b0&0x0f)<<12 | b1<< 6 | b2;
  else             o.i=i+4, o.c = (b0&0x07)<<18 | b1<<12 | b2<<6 | b3;
  return o;
}

struct read_utf8_state { uint32 c; struct utf8_state s;
                         const uchar *restrict pos; };

/*
  read_utf8
  
  usage:
    struct read_utf8_state st = { 0, utf8_state_ilzr, start };
    while(st.pos!=end) { // this is a precondition to read_utf8
      st = read_utf8(st,end);
      if(st.s.n==0)
        // read code st.c
    }
*/
static struct read_utf8_state read_utf8(
  struct read_utf8_state in, const uchar *const end)
{
  struct read_utf8_fast t;
  struct read_utf8_state out = in;
  if(out.s.n==0) {
    const uchar c = *out.pos;
    if(c<0xc0u) { out.c=c, out.pos++; return out; }
    if(out.pos+4<=end) {
      t=read_utf8_fast(out.pos,0),out.c=t.c,out.pos+=t.i; return out;
    }
    out.s.c[0] = c; out.s.n = 1;
    if(++out.pos==end) return out;
  }
  
  {
    const int count = (out.s.c[0]>>4)<0xd ? 2 : (out.s.c[0]>>4)-0xb;
    for(;;) {
      out.s.c[out.s.n++] = *out.pos++;
      if(out.s.n==count) { out.c=read_utf8_fast(out.s.c,0).c;
                           out.s.n=0; return out; }
      if(out.pos==end) return out;
    }
  }
}

#endif
