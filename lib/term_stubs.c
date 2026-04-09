#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <termios.h>

/* Emergency terminal reset for crashes. Signal-safe: only uses write(). */
static struct termios saved_termios;
static int have_saved_termios = 0;

static void crash_handler(int sig) {
  /* Minimal cleanup using only async-signal-safe functions */
  static const char reset[] =
    "\x1b[<u"        /* disable Kitty keyboard protocol */
    "\x1b[?2004l"    /* disable bracketed paste */
    "\x1b[?1006l"    /* disable SGR mouse */
    "\x1b[?1003l"    /* disable any-motion mouse */
    "\x1b[?1002l"    /* disable button mouse tracking */
    "\x1b[?25h"      /* show cursor */
    "\x1b[?1049l"    /* restore main screen */
    "\x1b[0m";       /* reset attributes */
  write(STDOUT_FILENO, reset, sizeof(reset) - 1);
  if (have_saved_termios)
    tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
  /* Re-raise with default handler to get core dump / sanitizer output */
  struct sigaction dfl;
  memset(&dfl, 0, sizeof(dfl));
  dfl.sa_handler = SIG_DFL;
  sigaction(sig, &dfl, NULL);
  raise(sig);
}

CAMLprim value caml_install_crash_handler(value v_unit) {
  /* Save termios for restoration */
  if (tcgetattr(STDIN_FILENO, &saved_termios) == 0)
    have_saved_termios = 1;
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = crash_handler;
  sa.sa_flags = SA_RESETHAND;  /* one-shot: don't re-enter on nested fault */
  sigaction(SIGSEGV, &sa, NULL);
  sigaction(SIGBUS, &sa, NULL);
  sigaction(SIGABRT, &sa, NULL);
  return Val_unit;
}

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
