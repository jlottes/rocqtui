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
