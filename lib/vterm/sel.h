#ifndef SEL_H
#define SEL_H

struct sel_pos { int line; struct wrap_break pos; };
struct sel_desc { struct sel_pos b,e; };

struct sel_desc sel_fix(
  const struct term *const restrict t,
  struct scroll_pos b, struct scroll_pos e);
struct sel_desc sel_word(
  const struct term *const restrict t, int r, float col);
uchar *sel_get(const struct term *const restrict t, const struct sel_desc sel);

#endif
