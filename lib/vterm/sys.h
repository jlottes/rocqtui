#ifndef SYS_H
#define SYS_H

#define sys_repeat(out, expr) \
  do (out)=(expr); while ((out)==-1 && errno==EINTR)
#define sys_try(out, expr, on_fail) do { \
  sys_repeat(out,expr); \
  if((out)==-1) { on_fail; } \
} while(0)

#ifdef __GNUC__
#  define ATTRB1  __attribute__ ((format(printf,1,2)))
#  define ATTRB2  __attribute__ ((format(printf,2,3)))
#else
#  define ATTRB1
#  define ATTRB2
#endif
#define DEF_FUNS() \
  char *bprintf(const char *fmt, ...) ATTRB1; \
  int  fdprintf(int fd, const char *fmt, ...) ATTRB2; \
  char *mprintf(const char *fmt, ...) ATTRB1;
DEF_FUNS()
#undef DEF_FUNS
#undef ATTRB2
#undef ATTRB1

void sys_init(void);
void sys_done(void);

struct sysbuf { void *restrict ptr; size_t base,pgn, n,max; };
void sysbuf_reset(struct sysbuf *restrict a, const size_t size);
void sysbuf_free(struct sysbuf *restrict a);
int sysbuf_reserve(struct sysbuf *restrict a, size_t min, size_t size);
void sysbuf_shrink_dn(struct sysbuf *restrict a, size_t max, size_t size);
void sysbuf_shrink_up(struct sysbuf *restrict a, size_t n, size_t size);

ssize_t sys_read(int fd, void *buf, size_t count);
int sys_write(int fd, const void *buf, size_t count);

void chk_or_mkdir(const char *path);
int chk_or_mkfifo(int *restrict fd, const char *fifo_name);
void sys_setenv(const char *name, const char *val);
const char *procpath(void);
void install_handler(int signum, void (*fun)(int));
void watch_fd(int fd);
void watch_fd_writable(int fd, int writable);
int check_sigs(int block);
int wait_for_fd(int block);

struct pty { int fdm; pid_t child; };
struct pty get_pty(int watch, int argc, char *argv[]);
void pty_set_size(int fd, unsigned w, unsigned h);

#endif
