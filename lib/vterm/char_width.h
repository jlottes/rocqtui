#ifndef TERM_H
#warning "char_width.h" requires term.h
#endif

#ifndef _XOPEN_SOURCE
#warning "char_width.h" requires _XOPEN_SOURCE
#endif

#include <wchar.h>    /* wcwidth  */
#include <wctype.h>   /* iswalnum */

static inline unsigned char_width(uint32 c, unsigned col)
{
  if(c==ENC_TAB) return 8-(col&7); else {
    int w = wcwidth((wchar_t)c); return w>=0?w:1; }
}
