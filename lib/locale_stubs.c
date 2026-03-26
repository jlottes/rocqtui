#define _XOPEN_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <locale.h>
#include <wchar.h>

CAMLprim value caml_curses_setlocale(value cat, value loc) {
  CAMLparam2(cat, loc);
  const char *result = setlocale(Int_val(cat), String_val(loc));
  CAMLreturn(caml_copy_string(result ? result : ""));
}

CAMLprim value caml_wcwidth(value cp) {
  int w = wcwidth(Int_val(cp));
  return Val_int(w);
}

/* Mouse support — ncurses getmouse isn't in the OCaml curses bindings */
#include <ncurses.h>

CAMLprim value caml_all_mouse_events(value unit) {
  (void)unit;
  return Val_int(ALL_MOUSE_EVENTS | REPORT_MOUSE_POSITION);
}

CAMLprim value caml_getmouse(value unit) {
  CAMLparam1(unit);
  MEVENT event;
  int rc = getmouse(&event);
  value tup = caml_alloc_tuple(4);
  Store_field(tup, 0, Val_int(rc == OK ? 1 : 0));
  Store_field(tup, 1, Val_int(event.x));
  Store_field(tup, 2, Val_int(event.y));
  Store_field(tup, 3, Val_int((int)(event.bstate & 0x7FFFFFFF)));
  CAMLreturn(tup);
}
