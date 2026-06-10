#ifndef TERM_H
#warning "char_width.h" requires term.h
#endif

#ifndef EMOJI_PROPS_H
#warning "char_width.h" requires "emoji_props.h"
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
  /* Guarantee the Emoji_Presentation=Yes set is width 2. On a current
     glibc this is a no-op except for regional indicators (EAW=N, but
     deliberately wide here per kitty/foot: an unpaired flag half must
     not shift text when its partner arrives); it is insurance against
     stale libc tables (musl, pre-Unicode-9 glibc) and codepoints newer
     than the host's. Text-presentation symbols (check marks
     U+2713/2714, warning sign U+26A0, thermometer U+1F321, ...) stay
     narrow; VS-16 widens them via the cluster path. */
  if(w==1 && emoji_presentation(c)) w = 2;
  return (unsigned)w;
}
