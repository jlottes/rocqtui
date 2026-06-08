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
  int w;
  if(c & CLUSTER_BIT) return (c & CLUSTER_NARROW_BIT) ? 1u : 2u;
  if(c==ENC_TAB) return 8-(col&7);
  w = wcwidth((wchar_t)c);
  if(w<0) w = 1;
  /* wcwidth's tables predate modern emoji width conventions: many
     pictographic codepoints get reported as 1 even though every modern
     terminal renders them at width 2. Widen any width-1 codepoint in the
     main pictographic blocks. Matches kitty/wezterm/foot behavior. */
  if(w==1 && ((c >= 0x1F300u && c <= 0x1FAFFu)
           || (c >= 0x2600u  && c <= 0x27BFu)))
    w = 2;
  return (unsigned)w;
}
