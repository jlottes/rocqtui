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
     main pictographic blocks, plus the scattered Emoji_Presentation=Yes
     codepoints living in symbol blocks. Matches kitty/wezterm/foot
     behavior. Keep aligned with font.c's color-preference range. */
  if(w==1 && (
       (c >= 0x1F300u && c <= 0x1FAFFu)
    || (c >= 0x2600u  && c <= 0x27BFu)
    || c == 0x231Au || c == 0x231Bu       /* watch, hourglass */
    || (c >= 0x23E9u && c <= 0x23ECu)     /* media fast-fwd, etc. */
    || c == 0x23F0u || c == 0x23F3u       /* alarm clock, hourglass-flowing */
    || c == 0x25FDu || c == 0x25FEu       /* medium squares */
    || c == 0x2B1Bu || c == 0x2B1Cu       /* large squares */
    || c == 0x2B50u || c == 0x2B55u       /* star, hollow red circle */
    ))
    w = 2;
  return (unsigned)w;
}
