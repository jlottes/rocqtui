#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <sys/ioctl.h>
#include <unistd.h>

CAMLprim value caml_get_winsize(value v_fd) {
  CAMLparam1(v_fd);
  struct winsize ws;
  if (ioctl(Int_val(v_fd), TIOCGWINSZ, &ws) < 0)
    caml_failwith("TIOCGWINSZ");
  value tup = caml_alloc_tuple(2);
  Store_field(tup, 0, Val_int(ws.ws_row));
  Store_field(tup, 1, Val_int(ws.ws_col));
  CAMLreturn(tup);
}
