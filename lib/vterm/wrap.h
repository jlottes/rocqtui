#ifndef WRAP_H
#define WRAP_H

#ifndef TERM_H
#warning "wrap.h" requires "term.h"
#endif

/* line==0 means the very first line of term->buf.beg */
struct scroll_pos { unsigned line, col; };

/* line==0 means the active line (term->margin.ptr) */
struct subline { int line; unsigned sub; };

/* offset in wrap_break is relative to half_buffer.data.ptr
   or the cell number of the line, starting at 0 */
struct wrap_line { unsigned short nsub, brki; };
struct wrap_break { unsigned off, col; struct gr gr; };
struct wrap_breaks {
  int dirty;
  struct subline vtop, vbot; /* displayed line range when not scrolled up */
  struct subline dtop, dbot; /* displayed line range */
  struct array /* of struct wrap_line  */ lines;
  struct array /* of struct wrap_break */ brks;
};

unsigned wrap_calc(
  struct wrap_break *restrict const brk, const unsigned max,
  const struct term *const restrict t, const int r,
  const int mode, const unsigned minw, const unsigned maxw);

void wrap_update(
  struct wrap_breaks *restrict const p,
  struct scroll_pos *restrict const scroll,
  const struct term *restrict const t,
  const unsigned wrap_mode,
  unsigned h);

int wrap_scroll(
  struct scroll_pos *restrict const scroll,
  struct wrap_breaks *restrict const p,
  const struct term *restrict const t,
  const unsigned wrap_mode,
  int n);

#endif
