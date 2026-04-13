#ifndef KEYS_H
#define KEYS_H

/* Key identity codes for the keyseq API.
   Text keys use their Unicode codepoint directly.
   Functional keys use codepoints from the Unicode Private Use Area,
   following the kitty keyboard protocol where defined.

   Keys that the kitty spec encodes via legacy CSI sequences
   (arrows, F1-F12, nav keys) don't have kitty-assigned PUA codes,
   so we assign our own in the 57344-57375 gap. */

/* basic control keys — ASCII/Unicode codepoints per kitty spec */
#define KEY_ESCAPE    27u
#define KEY_ENTER     13u
#define KEY_TAB        9u
#define KEY_BACKSPACE 127u

/* navigation and arrow keys — our PUA assignments (57344-57354) */
#define KEY_UP        57344u
#define KEY_DOWN      57345u
#define KEY_RIGHT     57346u
#define KEY_LEFT      57347u
#define KEY_HOME      57348u
#define KEY_END       57349u
#define KEY_INSERT    57350u
#define KEY_DELETE    57351u
#define KEY_PAGE_UP   57352u
#define KEY_PAGE_DOWN 57353u
#define KEY_BEGIN     57354u

/* F1-F12 — contiguous in the 57364-57375 gap (between kitty's
   lock/print/pause/menu at 57358-57363 and F13+ at 57376+) */
#define KEY_F1       57364u
#define KEY_F2       57365u
#define KEY_F3       57366u
#define KEY_F4       57367u
#define KEY_F5       57368u
#define KEY_F6       57369u
#define KEY_F7       57370u
#define KEY_F8       57371u
#define KEY_F9       57372u
#define KEY_F10      57373u
#define KEY_F11      57374u
#define KEY_F12      57375u

/* F13-F20 — kitty-assigned PUA codes */
#define KEY_F13      57376u
#define KEY_F14      57377u
#define KEY_F15      57378u
#define KEY_F16      57379u
#define KEY_F17      57380u
#define KEY_F18      57381u
#define KEY_F19      57382u
#define KEY_F20      57383u

/* lock keys — kitty-assigned PUA codes */
#define KEY_CAPS_LOCK  57358u
#define KEY_NUM_LOCK   57360u

/* keypad — kitty-assigned PUA codes */
#define KEY_KP_0         57399u
#define KEY_KP_1         57400u
#define KEY_KP_2         57401u
#define KEY_KP_3         57402u
#define KEY_KP_4         57403u
#define KEY_KP_5         57404u
#define KEY_KP_6         57405u
#define KEY_KP_7         57406u
#define KEY_KP_8         57407u
#define KEY_KP_9         57408u
#define KEY_KP_DECIMAL   57409u
#define KEY_KP_DIVIDE    57410u
#define KEY_KP_MULTIPLY  57411u
#define KEY_KP_SUBTRACT  57412u
#define KEY_KP_ADD       57413u
#define KEY_KP_ENTER     57414u
#define KEY_KP_EQUAL     57415u
#define KEY_KP_SEPARATOR 57416u
#define KEY_KP_LEFT      57417u
#define KEY_KP_RIGHT     57418u
#define KEY_KP_UP        57419u
#define KEY_KP_DOWN      57420u
#define KEY_KP_PAGE_UP   57421u
#define KEY_KP_PAGE_DOWN 57422u
#define KEY_KP_HOME      57423u
#define KEY_KP_END       57424u
#define KEY_KP_INSERT    57425u
#define KEY_KP_DELETE    57426u
#define KEY_KP_BEGIN     57427u
#define KEY_KP_SPACE     57355u
#define KEY_KP_TAB       57356u
#define KEY_KP_F1        57357u

/* modifier keys — kitty-assigned PUA codes */
#define KEY_SHIFT_L    57441u
#define KEY_SHIFT_R    57447u
#define KEY_CONTROL_L  57442u
#define KEY_CONTROL_R  57448u
#define KEY_ALT_L      57443u
#define KEY_ALT_R      57449u
#define KEY_SUPER_L    57444u
#define KEY_SUPER_R    57450u

/* modifier bits — kitty keyboard protocol layout */
#define MOD_SHIFT      0x01u
#define MOD_ALT        0x02u
#define MOD_CTRL       0x04u
#define MOD_SUPER      0x08u
#define MOD_HYPER      0x10u
#define MOD_META       0x20u
#define MOD_CAPS_LOCK  0x40u
#define MOD_NUM_LOCK   0x80u

#endif
