#ifndef EMOJI_PRESENTATION_H
#define EMOJI_PRESENTATION_H

#if !defined(C99_H)
#warning "emoji_presentation.h" requires "c99.h"
#endif

/* Emoji_Presentation=Yes codepoints below U+1F000, from Unicode
   emoji-data.txt (15.1). These default to emoji presentation: wide,
   color font. Everything else in the symbol/dingbat blocks (2600-27BF
   etc.) defaults to text presentation — narrow, mono, themed fg —
   unless VS-16 forces emoji. Shared by char_width.h (widening) and
   font.c (color-font preference); width and color must agree or a
   wide cell gets a mono glyph squished into half of it. */
static inline int emoji_presentation(uint32 c)
{
  if(c < 0x231Au || c > 0x2B55u) return 0;
  return (c >= 0x231Au && c <= 0x231Bu)  /* watch, hourglass */
      || (c >= 0x23E9u && c <= 0x23ECu)  /* media fast-fwd, etc. */
      ||  c == 0x23F0u || c == 0x23F3u   /* alarm clock, hourglass-flowing */
      || (c >= 0x25FDu && c <= 0x25FEu)  /* medium squares */
      || (c >= 0x2614u && c <= 0x2615u)  /* umbrella with rain, hot beverage */
      || (c >= 0x2648u && c <= 0x2653u)  /* zodiac */
      ||  c == 0x267Fu                   /* wheelchair */
      ||  c == 0x2693u                   /* anchor */
      ||  c == 0x26A1u                   /* high voltage */
      || (c >= 0x26AAu && c <= 0x26ABu)  /* white/black circle */
      || (c >= 0x26BDu && c <= 0x26BEu)  /* soccer ball, baseball */
      || (c >= 0x26C4u && c <= 0x26C5u)  /* snowman, sun behind cloud */
      ||  c == 0x26CEu                   /* Ophiuchus */
      ||  c == 0x26D4u                   /* no entry */
      ||  c == 0x26EAu                   /* church */
      || (c >= 0x26F2u && c <= 0x26F3u)  /* fountain, flag in hole */
      ||  c == 0x26F5u                   /* sailboat */
      ||  c == 0x26FAu                   /* tent */
      ||  c == 0x26FDu                   /* fuel pump */
      ||  c == 0x2705u                   /* check mark button */
      || (c >= 0x270Au && c <= 0x270Bu)  /* raised fist, raised hand */
      ||  c == 0x2728u                   /* sparkles */
      ||  c == 0x274Cu                   /* cross mark */
      ||  c == 0x274Eu                   /* cross mark button */
      || (c >= 0x2753u && c <= 0x2755u)  /* question/exclamation marks */
      ||  c == 0x2757u                   /* red exclamation mark */
      || (c >= 0x2795u && c <= 0x2797u)  /* plus, minus, divide */
      ||  c == 0x27B0u || c == 0x27BFu   /* curly loops */
      || (c >= 0x2B1Bu && c <= 0x2B1Cu)  /* large squares */
      ||  c == 0x2B50u || c == 0x2B55u;  /* star, hollow red circle */
}

#endif
