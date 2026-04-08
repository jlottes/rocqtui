#include <X11/keysym.h>
#include <stdio.h>
#include <string.h>
#include "c99.h"
#include "utf-8.h"
#include "keyseq.h"

/* XGL_SHIFT=1, XGL_ALT=2, XGL_CTRL=4 match kitty shift=1, alt=2, ctrl=4.
   XGL_NUM_LOCK=8 is stripped; kitty super/hyper/meta/caps/num not yet supported. */
#define xgl_to_kitty_mod(m) ((m) & 7u)

static char buf[64];

/* Convert keysym to Unicode codepoint.
   Returns 0 if the keysym is not a text-producing key. */
static uint32 keysym_to_codepoint(unsigned long ks)
{
  if(ks >= 0x20 && ks <= 0x7e) return ks;
  if(ks >= 0xa0 && ks <= 0xff) return ks;
  if((ks & 0xff000000u) == 0x01000000u) return ks & 0x00ffffffu;
  return 0;
}

/* Format: CSI code[:shifted] ; modifier[:event_type] [; text] u
   shifted: included when non-zero and differs from code (flag bit 2).
   modifier: 1+bits, omitted (along with semicolon) if 1 and no evt/text.
   event_type: 1=press (omitted), 2=repeat, 3=release.
   text: UTF-8 decoded to colon-separated decimal codepoints (flag bit 4). */
static const uchar *fmt_csi_u(uint32 code, uint32 shifted,
                               unsigned mod, int evt,
                               const uchar *text, unsigned text_len)
{
  unsigned m = 1 + mod;
  int has_text = text && text_len;
  char *p = buf;
  p += sprintf(p, "\033[%u", (unsigned)code);
  if(shifted && shifted != code)
    p += sprintf(p, ":%u", (unsigned)shifted);
  if(evt > 1)
    p += sprintf(p, ";%u:%d", m, evt);
  else if(m > 1)
    p += sprintf(p, ";%u", m);
  else if(has_text)
    *p++ = ';';
  if(has_text) {
    struct read_utf8_fast r;
    unsigned i = 0;
    *p++ = ';';
    while(i < text_len) {
      if(i) *p++ = ':';
      r = read_utf8_fast(text, i);
      p += sprintf(p, "%u", (unsigned)r.c);
      i = r.i;
    }
  }
  *p++ = 'u'; *p = 0;
  return (const uchar *)buf;
}

/*
   Kitty keyboard protocol key sequence lookup.
   Returns escape sequence string, or falls through to keyseq_lookup.
*/
const uchar *kitty_keyseq_lookup(
    unsigned long keysym, unsigned long base_keysym,
    uchar xgl_mod, uchar mode,
    uchar kitty_flags, int event_type,
    const uchar *text, unsigned text_len)
{
  unsigned mod;
  uint32 cp;
  int evt; /* event_type to encode: 0 means omit */
  int all; /* flag bit 3: report all keys as escape codes */

  if(!kitty_flags)
    return keyseq_lookup(keysym, xgl_mod, mode, 0);

  mod = xgl_to_kitty_mod(xgl_mod);
  evt = (kitty_flags & 2) ? event_type : 0;
  all = kitty_flags & 8;

  /* Modifier-only keys: report only when flag bit 3 is set.
     X11 reports ev->state BEFORE the key event takes effect, so
     on press the modifier isn't in state yet, on release it still is.
     Compensate: press adds the modifier, release removes it. */
  if(all) { unsigned mbit=0; uint32 mcode=0;
    switch(keysym) {
    case XK_Shift_L:   mcode=57441, mbit=1; break;
    case XK_Shift_R:   mcode=57447, mbit=1; break;
    case XK_Control_L: mcode=57442, mbit=4; break;
    case XK_Control_R: mcode=57448, mbit=4; break;
    case XK_Alt_L:     mcode=57443, mbit=2; break;
    case XK_Alt_R:     mcode=57449, mbit=2; break;
    case XK_Super_L:   mcode=57444; break;
    case XK_Super_R:   mcode=57450; break;
    case XK_Caps_Lock: mcode=57358; break;
    case XK_Num_Lock:  mcode=57360; break;
    }
    if(mcode) {
      if(mbit) {
        if(event_type==3) mod &= ~mbit; /* release: remove */
        else              mod |=  mbit; /* press: add */
      }
      return fmt_csi_u(mcode,0,mod,evt,0,0);
    }
  }

  /* Escape: always disambiguate */
  if(base_keysym==XK_Escape) return fmt_csi_u(27,0,mod,evt,0,0);

  /* Enter, Tab, Backspace: CSI u when modified, or when flag bit 3.
     Use base_keysym so Shift+Tab (XK_ISO_Left_Tab) matches XK_Tab. */
  switch(base_keysym) {
  case XK_Return:         if(mod||all) return fmt_csi_u(13,0,mod,evt,0,0);    break;
  case XK_Tab:            if(mod||all) return fmt_csi_u(9,0,mod,evt,0,0);     break;
  case XK_BackSpace:      if(mod||all) return fmt_csi_u(127,0,mod,evt,0,0);   break;
  case XK_KP_Enter:       if(mod||all) return fmt_csi_u(57414,0,mod,evt,0,0); break;
  }

  /* F1-F4: kitty uses CSI encoding, not SS3 */
  if(evt<=1) switch(keysym) {
    case XK_F1: case XK_F2: case XK_F3: case XK_F4: {
      unsigned m = 1 + mod;
      char c = 'P' + (keysym - XK_F1);
      if(m > 1) sprintf(buf, "\033[1;%u%c", m, c);
      else      sprintf(buf, "\033[%c", c);
      return (const uchar *)buf;
    }
  }

  /* Text keys: CSI u when modified with ctrl/alt, non-press event,
     or flag bit 3 (report all keys).
     Flag bit 4: include associated text (press/repeat only). */
  cp = keysym_to_codepoint(base_keysym);
  if(cp && ((mod & (4|2)) || evt > 1 || all)) {
    uint32 shifted = (kitty_flags & 4) ? keysym_to_codepoint(keysym) : 0;
    const uchar *txt = 0; unsigned tlen = 0;
    if((kitty_flags & 16) && event_type != 3
       && text_len && text[0] >= 0x20 && !(mod & (4|2)))
      txt = text, tlen = text_len;
    return fmt_csi_u(cp, shifted, mod, evt, txt, tlen);
  }

  /* Functional keys and unmodified text: legacy path */
  return keyseq_lookup(keysym, xgl_mod, mode, evt);
}
