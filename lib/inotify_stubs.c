#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <sys/inotify.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/* Create an inotify fd (non-blocking, close-on-exec) */
CAMLprim value caml_inotify_init(value unit) {
  (void)unit;
  int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  if (fd < 0) caml_failwith("inotify_init1");
  return Val_int(fd);
}

/* Add a watch. Returns watch descriptor. */
CAMLprim value caml_inotify_add_watch(value v_fd, value v_path, value v_mask) {
  CAMLparam3(v_fd, v_path, v_mask);
  int wd = inotify_add_watch(Int_val(v_fd), String_val(v_path), Int_val(v_mask));
  if (wd < 0) caml_failwith("inotify_add_watch");
  CAMLreturn(Val_int(wd));
}

/* Remove a watch. */
CAMLprim value caml_inotify_rm_watch(value v_fd, value v_wd) {
  inotify_rm_watch(Int_val(v_fd), Int_val(v_wd));
  return Val_unit;
}

/* Read pending events. Returns list of (wd, mask, name) tuples. */
CAMLprim value caml_inotify_read(value v_fd) {
  CAMLparam1(v_fd);
  CAMLlocal4(result, cell, tup, str);

  char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
  ssize_t n = read(Int_val(v_fd), buf, sizeof(buf));

  result = Val_emptylist;

  if (n <= 0) CAMLreturn(result);

  /* Build list in reverse, then it ends up in event order
     since we prepend (cons) each event */
  const char *ptr = buf;
  /* First pass: count events to build list in order */
  int count = 0;
  const char *p = buf;
  while (p < buf + n) {
    const struct inotify_event *ev = (const struct inotify_event *)p;
    count++;
    p += sizeof(struct inotify_event) + ev->len;
  }

  /* Allocate array to reverse */
  /* Simple approach: build in reverse (last event first), then reverse */
  ptr = buf;
  while (ptr < buf + n) {
    const struct inotify_event *ev = (const struct inotify_event *)ptr;
    tup = caml_alloc_tuple(3);
    Store_field(tup, 0, Val_int(ev->wd));
    Store_field(tup, 1, Val_int(ev->mask));
    str = caml_copy_string(ev->len > 0 ? ev->name : "");
    Store_field(tup, 2, str);
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, tup);
    Store_field(cell, 1, result);
    result = cell;
    ptr += sizeof(struct inotify_event) + ev->len;
  }
  (void)count;

  CAMLreturn(result);
}

/* Mask constants */
CAMLprim value caml_inotify_in_modify(value unit) { (void)unit; return Val_int(IN_MODIFY); }
CAMLprim value caml_inotify_in_close_write(value unit) { (void)unit; return Val_int(IN_CLOSE_WRITE); }
CAMLprim value caml_inotify_in_move_self(value unit) { (void)unit; return Val_int(IN_MOVE_SELF); }
CAMLprim value caml_inotify_in_delete_self(value unit) { (void)unit; return Val_int(IN_DELETE_SELF); }
CAMLprim value caml_inotify_in_create(value unit) { (void)unit; return Val_int(IN_CREATE); }
CAMLprim value caml_inotify_in_delete(value unit) { (void)unit; return Val_int(IN_DELETE); }
CAMLprim value caml_inotify_in_moved_from(value unit) { (void)unit; return Val_int(IN_MOVED_FROM); }
CAMLprim value caml_inotify_in_moved_to(value unit) { (void)unit; return Val_int(IN_MOVED_TO); }
CAMLprim value caml_inotify_in_isdir(value unit) { (void)unit; return Val_int(IN_ISDIR); }
CAMLprim value caml_inotify_in_ignored(value unit) { (void)unit; return Val_int(IN_IGNORED); }
