/* VT100-style Alternate Character Set Data */
#include "c99.h"

#define ACS_MAP_LOW_START 0x2b  /* '+' */
#define ACS_MAP_LOW_N     4
const uint32 acs_map_low[ACS_MAP_LOW_N] = {
  /* code    VT100 char    Unicode Name     */
    0x2192, /*  +      (→) RIGHTWARDS ARROW */
    0x2190, /*  ,      (←) LEFTWARDS ARROW  */
    0x2191, /*  -      (↑) UPWARDS ARROW    */
    0x2193  /*  .      (↓) DOWNWARDS ARROW  */
};

#define ACS_MAP_HIGH_START 0x60  /* '`' */
#define ACS_MAP_HIGH_N     0x20
const uint32 acs_map_high[ACS_MAP_HIGH_N] = {
  /* code    VT100 char    Unicode Name     */
    0x2666, /*  `      (♦) BLACK DIAMOND SUIT */
    0x2592, /*  a      (▒) MEDIUM SHADE       */
    0x62,   /*  b  */
    0x63,   /*  c  */
    0x64,   /*  d  */
    0x65,   /*  e  */
    0x00B0, /*  f      (°) DEGREE SIGN        */
    0x00B1, /*  g      (±) PLUS-MINUS SIGN    */
    0x68,   /*  h  */
    0x69,   /*  i  */
    0x2518, /*  j      (┘) (U+2518) */
    0x2510, /*  k      (┐) (U+2510) */
    0x250C, /*  l      (┌) (U+250C) */
    0x2514, /*  m      (└) (U+2514) */
    0x253C, /*  n      (┼) (U+253C) */
    0x75,   /*  o  */
    0x76,   /*  p  */
    0x2500, /*  q      (─) (U+2500) */
    0x78,   /*  r  */
    0x79,   /*  s  */
    0x251C, /*  t      (├) (U+251C) */
    0x2524, /*  u      (┤) (U+2524) */
    0x2534, /*  v      (┴) (U+2534) */
    0x252C, /*  w      (┬) (U+252C) */
    0x2502, /*  x      (│) (U+2502) */
    0x2264, /*  y      (≤) LESS-THAN OR EQUAL TO */
    0x2265, /*  z      (≥) GREATER-THAN OR EQUAL TO */
    0x03C0, /*  {      (π) GREEK SMALL LETTER PI */
    0x2260, /*  |      (≠) NOT EQUAL TO */
    0x00A3, /*  }      (£) POUND SIGN */
    0x2022, /*  ~      (•) BULLET */
    0x7f    /*  DEL  */
};
