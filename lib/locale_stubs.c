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

/* Legacy stubs — no longer used but kept to avoid linker errors
   from any remaining external references */
CAMLprim value caml_all_mouse_events(value unit) {
  (void)unit;
  return Val_int(0);
}

CAMLprim value caml_getmouse(value unit) {
  CAMLparam1(unit);
  value tup = caml_alloc_tuple(4);
  Store_field(tup, 0, Val_int(0));
  Store_field(tup, 1, Val_int(0));
  Store_field(tup, 2, Val_int(0));
  Store_field(tup, 3, Val_int(0));
  CAMLreturn(tup);
}
