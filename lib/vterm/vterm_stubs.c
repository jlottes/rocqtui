/* OCaml C stubs for the vterm terminal emulator library.
   Wraps vterm lifecycle, data flow, display, scroll, selection,
   key/mouse encoding, and state queries. */

#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <signal.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <caml/signals.h>

#include "c99.h"
#include "mem.h"
#include "utf-8.h"
#include "sysbuf.h"
#include "term.h"
#include "char_width.h"
#include "wrap.h"
#include "sel.h"
#include "vterm.h"
#include "keyseq.h"
#include "kitty_keyseq.h"
#include "mouseseq.h"

/* ============================================================
   Vterm custom block
   ============================================================ */

#define Vterm_val(v) (*((struct vterm **)Data_custom_val(v)))

static void vterm_finalize(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (vt) {
    vterm_done(vt);
    free(vt);
    Vterm_val(v) = NULL;
  }
}

static struct custom_operations vterm_ops = {
  "rocqtui.vterm",
  vterm_finalize,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

/* vterm_create : backlog:int -> fwdlog:int -> w:int -> h:int
                  -> wrap_mode:int -> t */
CAMLprim value caml_vterm_create(value v_backlog, value v_fwdlog,
    value v_w, value v_h, value v_wrap_mode)
{
  CAMLparam5(v_backlog, v_fwdlog, v_w, v_h, v_wrap_mode);
  CAMLlocal1(v_result);

  struct vterm *vt = malloc(sizeof(struct vterm));
  if (!vt) caml_failwith("vterm_create: out of memory");

  memset(vt, 0, sizeof(struct vterm));
  vterm_init(vt,
    Int_val(v_backlog), Int_val(v_fwdlog),
    Int_val(v_w), Int_val(v_h),
    0, 0,  /* scroll_dw=0, scroll_dh=0 */
    Int_val(v_wrap_mode));

  v_result = caml_alloc_custom(&vterm_ops, sizeof(struct vterm *), 0, 1);
  Vterm_val(v_result) = vt;
  CAMLreturn(v_result);
}

CAMLprim value caml_vterm_destroy(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (vt) {
    vterm_done(vt);
    free(vt);
    Vterm_val(v) = NULL;
  }
  return Val_unit;
}

/* ============================================================
   Processing PTY data
   ============================================================ */

/* vterm_proc : t -> bytes -> off:int -> len:int -> unit */
CAMLprim value caml_vterm_proc(value v, value v_buf, value v_off, value v_len)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_proc: vterm destroyed");
  const uchar *buf = Bytes_val(v_buf) + Int_val(v_off);
  int len = Int_val(v_len);
  term_proc(&vt->t, buf, buf + len);
  return Val_unit;
}

/* vterm_sync : t -> { feedback: bytes option; title: string option;
                        mouse_changed: bool; clipboard: string option } */
CAMLprim value caml_vterm_sync(value v)
{
  CAMLparam1(v);
  CAMLlocal5(v_result, v_feedback, v_title, v_clipboard, v_tmp);

  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_sync: vterm destroyed");

  struct vterm_out out = vterm_sync(vt);

  /* feedback: bytes option */
  if (out.feedback && out.feedback_len > 0) {
    v_tmp = caml_alloc_string(out.feedback_len);
    memcpy(Bytes_val(v_tmp), out.feedback, out.feedback_len);
    v_feedback = caml_alloc(1, 0); /* Some */
    Store_field(v_feedback, 0, v_tmp);
  } else {
    v_feedback = Val_none;
  }

  /* title: string option */
  if (out.name) {
    v_tmp = caml_copy_string((const char *)out.name);
    v_title = caml_alloc(1, 0);
    Store_field(v_title, 0, v_tmp);
  } else {
    v_title = Val_none;
  }

  /* clipboard: string option (takes ownership) */
  if (out.clipboard) {
    v_tmp = caml_alloc_string(out.clipboard_len);
    memcpy(Bytes_val(v_tmp), out.clipboard, out.clipboard_len);
    v_clipboard = caml_alloc(1, 0);
    Store_field(v_clipboard, 0, v_tmp);
    free(out.clipboard);
  } else {
    v_clipboard = Val_none;
  }

  /* Record: { feedback; title; mouse_changed; clipboard } */
  v_result = caml_alloc(4, 0);
  Store_field(v_result, 0, v_feedback);
  Store_field(v_result, 1, v_title);
  Store_field(v_result, 2, Val_bool(out.mouse_changed));
  Store_field(v_result, 3, v_clipboard);

  CAMLreturn(v_result);
}

/* ============================================================
   Resize
   ============================================================ */

CAMLprim value caml_vterm_resize(value v, value v_w, value v_h)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_resize: vterm destroyed");
  vterm_resize(vt, Int_val(v_w), Int_val(v_h));
  return Val_unit;
}

/* ============================================================
   Display
   ============================================================ */

CAMLprim value caml_vterm_prepare_rows(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_prepare_rows: vterm destroyed");
  return Val_int(vterm_prepare_rows(vt));
}

/* Helper: convert a struct gr color to an OCaml Grid.color value.
   Grid.color = Default | Basic of int | Color256 of int
              | TrueColor of int * int * int
   Tags: Default=0, Basic=0(block), Color256=1(block), TrueColor=2(block) */
static value gr_color_to_ocaml(uint32 raw, uint32 mode)
{
  CAMLparam0();
  CAMLlocal1(v);
  uint32 color = raw & GR_CLR_MASK;

  switch (mode >> GR_MD_BITS) {
  case 0: /* 16-color */
    if (color == DEFAULT_COLOR) {
      CAMLreturn(Val_int(0)); /* Default */
    } else {
      v = caml_alloc(1, 0); /* Basic */
      Store_field(v, 0, Val_int(color));
      CAMLreturn(v);
    }
  case 1: /* 256-color */
    v = caml_alloc(1, 1); /* Color256 */
    Store_field(v, 0, Val_int(color));
    CAMLreturn(v);
  case 2: /* 24-bit */
    v = caml_alloc(3, 2); /* TrueColor */
    Store_field(v, 0, Val_int((color >> 16) & 0xff));
    Store_field(v, 1, Val_int((color >> 8) & 0xff));
    Store_field(v, 2, Val_int(color & 0xff));
    CAMLreturn(v);
  default:
    CAMLreturn(Val_int(0)); /* Default */
  }
}

/* Helper: build a Grid.attr from struct gr */
static value gr_to_attr(struct gr g)
{
  CAMLparam0();
  CAMLlocal3(v_attr, v_fg, v_bg);
  uint32 attrb = gr_attrb(g);

  v_fg = gr_color_to_ocaml(g.fg, g.fg & GR_MD_MASK);
  v_bg = gr_color_to_ocaml(g.bg, g.bg & GR_MD_MASK);

  /* Grid.attr = { fg; bg; bold; dim; reverse; underline } */
  v_attr = caml_alloc(6, 0);
  Store_field(v_attr, 0, v_fg);
  Store_field(v_attr, 1, v_bg);
  Store_field(v_attr, 2, Val_bool(attrb & ATTRB_BD));
  Store_field(v_attr, 3, Val_bool(attrb & ATTRB_DM));
  Store_field(v_attr, 4, Val_bool(attrb & ATTRB_IN));
  Store_field(v_attr, 5, Val_bool(attrb & ATTRB_UL));

  CAMLreturn(v_attr);
}

/* vterm_get_row : t -> y:int -> (string * int * Grid.attr * bool * bool) array
   Returns array of (text, width, attr, selected, cursor) for each cell.
   The sentinel (code == '\n') is not included. */
CAMLprim value caml_vterm_get_row(value v, value v_y)
{
  CAMLparam2(v, v_y);
  CAMLlocal4(v_arr, v_cell, v_attr, v_text);

  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_get_row: vterm destroyed");

  struct array *row = vterm_get_row(vt, Int_val(v_y));
  const struct vterm_cell *cells = row->ptr;
  unsigned n = row->n;

  /* Count non-sentinel cells */
  unsigned count = 0;
  for (unsigned i = 0; i < n; i++) {
    if (cells[i].code == '\n') break;
    count++;
  }

  v_arr = caml_alloc(count, 0);
  for (unsigned i = 0; i < count; i++) {
    const struct vterm_cell *c = &cells[i];

    /* Encode codepoint as UTF-8 */
    uchar utf8buf[8];
    uchar *end = put_utf8(utf8buf, c->code);
    v_text = caml_alloc_string(end - utf8buf);
    memcpy(Bytes_val(v_text), utf8buf, end - utf8buf);

    v_attr = gr_to_attr(c->gr);

    /* 5-tuple: (text, width, attr, selected, cursor) */
    v_cell = caml_alloc(5, 0);
    Store_field(v_cell, 0, v_text);
    Store_field(v_cell, 1, Val_int(c->w));
    Store_field(v_cell, 2, v_attr);
    Store_field(v_cell, 3, Val_bool(c->selected));
    Store_field(v_cell, 4, Val_bool(c->cursor));

    Store_field(v_arr, i, v_cell);
  }

  CAMLreturn(v_arr);
}

/* vterm_get_row_sentinel : t -> y:int -> (Grid.attr * int) option
   Returns Some (trailing_attr, end_col) for the sentinel, or None */
CAMLprim value caml_vterm_get_row_sentinel(value v, value v_y)
{
  CAMLparam2(v, v_y);
  CAMLlocal3(v_result, v_pair, v_attr);

  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_get_row_sentinel: vterm destroyed");

  struct array *row = vterm_get_row(vt, Int_val(v_y));
  const struct vterm_cell *cells = row->ptr;
  unsigned n = row->n;

  for (unsigned i = 0; i < n; i++) {
    if (cells[i].code == '\n') {
      v_attr = gr_to_attr(cells[i].gr);
      v_pair = caml_alloc(3, 0);
      Store_field(v_pair, 0, v_attr);
      Store_field(v_pair, 1, Val_int(cells[i].x));
      Store_field(v_pair, 2, Val_bool(cells[i].selected));
      v_result = caml_alloc(1, 0); /* Some */
      Store_field(v_result, 0, v_pair);
      CAMLreturn(v_result);
    }
  }

  CAMLreturn(Val_none);
}

/* ============================================================
   Scroll
   ============================================================ */

CAMLprim value caml_vterm_scroll(value v, value v_n)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_scroll: vterm destroyed");
  return Val_bool(vterm_scroll(vt, Int_val(v_n)));
}

CAMLprim value caml_vterm_scroll_to_end(value v, value v_top)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_scroll_to_end: vterm destroyed");
  return Val_bool(vterm_scroll_to_end(vt, Bool_val(v_top)));
}

/* ============================================================
   Selection
   ============================================================ */

CAMLprim value caml_vterm_hit_test(value v, value v_row, value v_col)
{
  CAMLparam3(v, v_row, v_col);
  CAMLlocal1(v_result);

  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_hit_test: vterm destroyed");

  struct scroll_pos pos = vterm_hit_test(vt, Int_val(v_row), Int_val(v_col));

  v_result = caml_alloc(2, 0);
  Store_field(v_result, 0, Val_int(pos.line));
  Store_field(v_result, 1, Val_int(pos.col));
  CAMLreturn(v_result);
}

CAMLprim value caml_vterm_sel_start(value v, value v_line, value v_col)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_sel_start: vterm destroyed");
  struct scroll_pos pos = { Int_val(v_line), Int_val(v_col) };
  vterm_sel_start(vt, pos);
  return Val_unit;
}

CAMLprim value caml_vterm_sel_extend(value v, value v_line, value v_col)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_sel_extend: vterm destroyed");
  struct scroll_pos pos = { Int_val(v_line), Int_val(v_col) };
  vterm_sel_extend(vt, pos);
  return Val_unit;
}

CAMLprim value caml_vterm_sel_word(value v, value v_line, value v_col)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_sel_word: vterm destroyed");
  struct scroll_pos pos = { Int_val(v_line), Int_val(v_col) };
  vterm_sel_word(vt, pos);
  return Val_unit;
}

CAMLprim value caml_vterm_sel_text(value v)
{
  CAMLparam1(v);
  CAMLlocal2(v_result, v_str);

  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_sel_text: vterm destroyed");

  uchar *text = vterm_sel_text(vt);
  if (!text) CAMLreturn(Val_none);

  v_str = caml_copy_string((const char *)text);
  free(text);
  v_result = caml_alloc(1, 0); /* Some */
  Store_field(v_result, 0, v_str);
  CAMLreturn(v_result);
}

CAMLprim value caml_vterm_has_selection(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) return Val_false;
  return Val_bool(vt->sel.on);
}

/* ============================================================
   State queries
   ============================================================ */

CAMLprim value caml_vterm_mouse_mode(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) return Val_int(0);
  return Val_int(vt->t.mouse_mode);
}

CAMLprim value caml_vterm_mouse_flags(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) return Val_int(0);
  return Val_int(vt->t.mouse_flags);
}

CAMLprim value caml_vterm_kitty_flags(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) return Val_int(0);
  return Val_int(vt->t.kitty_kb_flags);
}

CAMLprim value caml_vterm_term_mode(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) return Val_int(0);
  return Val_int(vt->t.mode);
}

CAMLprim value caml_vterm_alt_screen(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) return Val_false;
  return Val_bool(vt->t.alt_screen);
}

CAMLprim value caml_vterm_bracketed_paste(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) return Val_false;
  return Val_bool(vt->t.bracketed_paste);
}

CAMLprim value caml_vterm_cursor(value v)
{
  CAMLparam1(v);
  CAMLlocal2(v_result, v_info);

  struct vterm *vt = Vterm_val(v);
  if (!vt) CAMLreturn(Val_none);

  /* Ensure layout is fresh */
  vterm_prepare_rows(vt);
  struct cursor_pos *cp = &vt->layout.cursor_pos;

  if (!cp->on_screen) CAMLreturn(Val_none);

  /* (x, y, w) */
  v_info = caml_alloc(3, 0);
  Store_field(v_info, 0, Val_int(cp->x));
  Store_field(v_info, 1, Val_int(cp->y));
  Store_field(v_info, 2, Val_int(cp->w));

  v_result = caml_alloc(1, 0); /* Some */
  Store_field(v_result, 0, v_info);
  CAMLreturn(v_result);
}

CAMLprim value caml_vterm_width(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) return Val_int(0);
  return Val_int(vt->t.w);
}

CAMLprim value caml_vterm_height(value v)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) return Val_int(0);
  return Val_int(vt->t.h);
}

/* ============================================================
   Key encoding
   ============================================================ */

/* keyseq : keysym:int -> modifiers:int -> mode:int
            -> event_type:int -> string option */
CAMLprim value caml_keyseq_lookup(value v_keysym, value v_mod,
    value v_mode, value v_event_type)
{
  CAMLparam4(v_keysym, v_mod, v_mode, v_event_type);
  CAMLlocal2(v_result, v_str);

  const uchar *seq = keyseq_lookup(
    Int_val(v_keysym), Int_val(v_mod),
    Int_val(v_mode), Int_val(v_event_type));

  if (!seq) CAMLreturn(Val_none);

  v_str = caml_copy_string((const char *)seq);
  v_result = caml_alloc(1, 0);
  Store_field(v_result, 0, v_str);
  CAMLreturn(v_result);
}

/* kitty_keyseq : keysym:int -> base_keysym:int -> modifiers:int
                  -> mode:int -> kitty_flags:int -> event_type:int
                  -> text:string -> string option */
CAMLprim value caml_kitty_keyseq_lookup_nat(value v_keysym,
    value v_base_keysym, value v_mod, value v_mode,
    value v_kitty_flags, value v_event_type, value v_text);

CAMLprim value caml_kitty_keyseq_lookup_bc(value *argv, int argc)
{
  return caml_kitty_keyseq_lookup_nat(
    argv[0], argv[1], argv[2], argv[3],
    argv[4], argv[5], argv[6]);
}

CAMLprim value caml_kitty_keyseq_lookup_nat(value v_keysym,
    value v_base_keysym, value v_mod, value v_mode,
    value v_kitty_flags, value v_event_type, value v_text)
{
  CAMLparam5(v_keysym, v_base_keysym, v_mod, v_mode, v_kitty_flags);
  CAMLxparam2(v_event_type, v_text);
  CAMLlocal2(v_result, v_str);

  const uchar *seq = kitty_keyseq_lookup(
    Int_val(v_keysym), Int_val(v_base_keysym),
    Int_val(v_mod), Int_val(v_mode),
    Int_val(v_kitty_flags), Int_val(v_event_type),
    (const uchar *)String_val(v_text),
    caml_string_length(v_text));

  if (!seq) CAMLreturn(Val_none);

  v_str = caml_copy_string((const char *)seq);
  v_result = caml_alloc(1, 0);
  Store_field(v_result, 0, v_str);
  CAMLreturn(v_result);
}

/* ============================================================
   Mouse encoding
   ============================================================ */

/* mouseseq : button:int -> modifiers:int -> cx:int -> cy:int
              -> ev:int -> mode:int -> flags:int -> string */
CAMLprim value caml_mouseseq_nat(value v_button, value v_mod,
    value v_cx, value v_cy, value v_ev, value v_mode, value v_flags);

CAMLprim value caml_mouseseq_bc(value *argv, int argc)
{
  return caml_mouseseq_nat(argv[0], argv[1], argv[2], argv[3],
                           argv[4], argv[5], argv[6]);
}

CAMLprim value caml_mouseseq_nat(value v_button, value v_mod,
    value v_cx, value v_cy, value v_ev, value v_mode, value v_flags)
{
  CAMLparam5(v_button, v_mod, v_cx, v_cy, v_ev);
  CAMLxparam2(v_mode, v_flags);
  CAMLlocal1(v_result);

  unsigned char buf[64];
  unsigned len = mouseseq(buf,
    Int_val(v_button), Int_val(v_mod),
    Int_val(v_cx), Int_val(v_cy),
    Int_val(v_ev), Int_val(v_mode), Int_val(v_flags));

  v_result = caml_alloc_string(len);
  memcpy(Bytes_val(v_result), buf, len);
  CAMLreturn(v_result);
}

/* ============================================================
   PTY
   ============================================================ */

/* pty_open : cmd:string -> args:string array -> env:string array
              -> w:int -> h:int -> cwd:string -> (Unix.file_descr * int) */
CAMLprim value caml_pty_open_nat(value v_cmd, value v_args, value v_env,
    value v_w, value v_h, value v_cwd);

CAMLprim value caml_pty_open_bc(value *argv, int argc)
{
  return caml_pty_open_nat(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
}

CAMLprim value caml_pty_open_nat(value v_cmd, value v_args, value v_env,
    value v_w, value v_h, value v_cwd)
{
  CAMLparam5(v_cmd, v_args, v_env, v_w, v_h);
  CAMLxparam1(v_cwd);
  CAMLlocal1(v_result);

  int argc = Wosize_val(v_args);
  int envc = Wosize_val(v_env);

  /* Build argv: [cmd, args..., NULL] */
  char **argv = calloc(argc + 2, sizeof(char *));
  if (!argv) caml_failwith("pty_open: out of memory");
  argv[0] = (char *)String_val(v_cmd);
  for (int i = 0; i < argc; i++)
    argv[i + 1] = (char *)String_val(Field(v_args, i));
  argv[argc + 1] = NULL;

  /* Build envp from current env + overrides */
  /* For now, just pass the override env entries alongside inherited env */
  /* We'll use execvpe-style: build a full environment */
  extern char **environ;
  int base_envc = 0;
  for (char **e = environ; *e; e++) base_envc++;

  char **envp = calloc(base_envc + envc + 1, sizeof(char *));
  if (!envp) { free(argv); caml_failwith("pty_open: out of memory"); }
  int ei = 0;
  for (int i = 0; i < base_envc; i++) envp[ei++] = environ[i];
  /* Override/append entries from v_env (format "KEY=VALUE") */
  for (int i = 0; i < envc; i++) envp[ei++] = (char *)String_val(Field(v_env, i));
  envp[ei] = NULL;

  /* Open PTY */
  int fdm;
  do fdm = open("/dev/ptmx", O_RDWR | O_NOCTTY); while (fdm == -1 && errno == EINTR);
  if (fdm == -1) { free(argv); free(envp); caml_failwith("pty_open: open /dev/ptmx failed"); }
  if (grantpt(fdm)) { close(fdm); free(argv); free(envp); caml_failwith("pty_open: grantpt failed"); }
  if (unlockpt(fdm)) { close(fdm); free(argv); free(envp); caml_failwith("pty_open: unlockpt failed"); }
  const char *slave = ptsname(fdm);
  if (!slave) { close(fdm); free(argv); free(envp); caml_failwith("pty_open: ptsname failed"); }
  fcntl(fdm, F_SETFL, O_NONBLOCK);

  /* Set initial size */
  unsigned short w = Int_val(v_w), h = Int_val(v_h);

  /* Extract cwd before fork */
  const char *cwd_str = String_val(v_cwd);
  char *cwd = NULL;
  if (cwd_str[0] != '\0') {
    cwd = strdup(cwd_str);
  }

  pid_t child = fork();
  if (child == -1) {
    close(fdm); free(argv); free(envp);
    caml_failwith("pty_open: fork failed");
  }

  if (child == 0) {
    /* Child */
    int fds;
    pid_t sid = setsid();
    fds = open(slave, O_RDWR);
    if (fds == -1) _exit(1);
    if (dup2(fds, 0) == -1 || dup2(fds, 1) == -1 || dup2(fds, 2) == -1) _exit(1);
    if (fds > 2) close(fds);
    close(fdm);
    ioctl(0, TIOCSCTTY, 0);
    tcsetpgrp(0, sid);

    /* Set terminal size on slave */
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = h;
    ws.ws_col = w;
    ioctl(0, TIOCSWINSZ, &ws);

    /* Change working directory if specified */
    if (cwd) {
      if (chdir(cwd) != 0) _exit(1);
    }

    execvpe(argv[0], argv, envp);
    _exit(1);
  }

  /* Parent */
  free(argv);
  free(envp);
  free(cwd);

  v_result = caml_alloc(2, 0);
  Store_field(v_result, 0, Val_int(fdm));
  Store_field(v_result, 1, Val_int(child));
  CAMLreturn(v_result);
}

CAMLprim value caml_pty_set_size(value v_fd, value v_w, value v_h)
{
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = Int_val(v_h);
  ws.ws_col = Int_val(v_w);
  ioctl(Int_val(v_fd), TIOCSWINSZ, &ws);
  return Val_unit;
}

/* ============================================================
   Wrap mode
   ============================================================ */

CAMLprim value caml_vterm_set_wrap_mode(value v, value v_mode)
{
  struct vterm *vt = Vterm_val(v);
  if (!vt) caml_failwith("vterm_set_wrap_mode: vterm destroyed");
  return Val_bool(vterm_set_wrap_mode(vt, Int_val(v_mode)));
}
