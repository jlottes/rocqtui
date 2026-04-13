#include <stdio.h>
#include <string.h>
#include "c99.h"
#include "utf-8.h"
#include "keys.h"
#include "keyseq.h"
#include "kitty_keyseq.h"

static char buf[64];

/* Is this key identity a functional key (not a text codepoint)?
   Used to decide whether to encode as CSI u with the codepoint. */
static int key_is_functional(unsigned key)
{
  /* C0 controls and DEL are non-text (Enter/Tab/Backspace/Escape),
     handled explicitly elsewhere. PUA range 57344+ is functional. */
  return key < 0x20u || key == 0x7fu || key >= 57344u;
}

/* Format: CSI code[:shifted] ; modifier[:event_type] [; text] u */
static const uchar *fmt_csi_u(unsigned code, unsigned shifted,
                               unsigned mod, int evt,
                               const uchar *text, unsigned text_len)
{
  unsigned m = 1 + mod;
  int has_text = text && text_len;
  char *p = buf;
  p += sprintf(p, "\033[%u", code);
  if(shifted && shifted != code)
    p += sprintf(p, ":%u", shifted);
  if(evt > 1)
    p += sprintf(p, ";%u:%d", m, evt);
  else if(m > 1)
    p += sprintf(p, ";%u", m);
  else if(has_text)
    *p++ = ';';
  if(has_text) {
    /* Use bounds-aware read_utf8 since caller's buffer may not have
       the 4-byte trailing slack that read_utf8_fast requires. */
    struct read_utf8_state st = { 0, utf8_state_ilzr, text };
    const uchar *end = text + text_len;
    int first = 1;
    *p++ = ';';
    while(st.pos != end) {
      st = read_utf8(st, end);
      if(st.s.n == 0) {
        if(!first) *p++ = ':';
        first = 0;
        p += sprintf(p, "%u", (unsigned)st.c);
      }
    }
  }
  *p++ = 'u'; *p = 0;
  return (const uchar *)buf;
}

const uchar *kitty_keyseq_lookup(
    unsigned key, unsigned shifted_key,
    unsigned mod, unsigned mode,
    unsigned kitty_flags, int event_type,
    const uchar *text, unsigned text_len)
{
  /* kitty protocol strips num_lock/caps_lock from reported mod for
     non-lock-key events — they're not "active modifiers" in the
     traditional sense. Keep only shift/alt/ctrl/super/hyper/meta. */
  unsigned kmod = mod & (MOD_SHIFT|MOD_ALT|MOD_CTRL
                        |MOD_SUPER|MOD_HYPER|MOD_META);
  int evt;
  int all;

  if(!kitty_flags)
    return keyseq_lookup(key, mod, mode, 0);

  evt = (kitty_flags & 2) ? event_type : 0;
  all = kitty_flags & 8;

  /* Modifier-only keys: reported only when flag bit 3 (report all) set */
  if(all) switch(key) {
    case KEY_SHIFT_L:    return fmt_csi_u(57441, 0, kmod, evt, 0, 0);
    case KEY_SHIFT_R:    return fmt_csi_u(57447, 0, kmod, evt, 0, 0);
    case KEY_CONTROL_L:  return fmt_csi_u(57442, 0, kmod, evt, 0, 0);
    case KEY_CONTROL_R:  return fmt_csi_u(57448, 0, kmod, evt, 0, 0);
    case KEY_ALT_L:      return fmt_csi_u(57443, 0, kmod, evt, 0, 0);
    case KEY_ALT_R:      return fmt_csi_u(57449, 0, kmod, evt, 0, 0);
    case KEY_SUPER_L:    return fmt_csi_u(57444, 0, kmod, evt, 0, 0);
    case KEY_SUPER_R:    return fmt_csi_u(57450, 0, kmod, evt, 0, 0);
    case KEY_CAPS_LOCK:  return fmt_csi_u(57358, 0, kmod, evt, 0, 0);
    case KEY_NUM_LOCK:   return fmt_csi_u(57360, 0, kmod, evt, 0, 0);
  }

  /* Escape: always disambiguate */
  if(key == KEY_ESCAPE) return fmt_csi_u(27, 0, kmod, evt, 0, 0);

  /* Enter, Tab, Backspace, KP_Enter: CSI u when modified or report-all */
  switch(key) {
  case KEY_ENTER:    if(kmod||all) return fmt_csi_u(13,  0, kmod, evt, 0, 0); break;
  case KEY_TAB:      if(kmod||all) return fmt_csi_u(9,   0, kmod, evt, 0, 0); break;
  case KEY_BACKSPACE:if(kmod||all) return fmt_csi_u(127, 0, kmod, evt, 0, 0); break;
  case KEY_KP_ENTER: if(kmod||all) return fmt_csi_u(57414, 0, kmod, evt, 0, 0); break;
  }

  /* F1-F4: kitty uses CSI encoding, not SS3 */
  if(evt<=1) switch(key) {
    case KEY_F1: case KEY_F2: case KEY_F3: case KEY_F4: {
      unsigned m = 1 + kmod;
      char c = 'P' + (key - KEY_F1);
      if(m > 1) sprintf(buf, "\033[1;%u%c", m, c);
      else      sprintf(buf, "\033[%c", c);
      return (const uchar *)buf;
    }
  }

  /* Text keys: CSI u when modified with ctrl/alt, non-press event,
     or report-all. Flag bit 4: include associated text (press/repeat). */
  if(!key_is_functional(key) && ((kmod & (MOD_CTRL|MOD_ALT)) || evt > 1 || all)) {
    unsigned shifted = (kitty_flags & 4) ? shifted_key : 0;
    const uchar *txt = 0; unsigned tlen = 0;
    if((kitty_flags & 16) && event_type != 3
       && text_len && text[0] >= 0x20 && !(kmod & (MOD_CTRL|MOD_ALT)))
      txt = text, tlen = text_len;
    return fmt_csi_u(key, shifted, kmod, evt, txt, tlen);
  }

  /* Functional keys and unmodified text: legacy path */
  return keyseq_lookup(key, mod, mode, evt);
}
