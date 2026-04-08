#define _GNU_SOURCE
#include <stddef.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>
#include <signal.h>
#include <execinfo.h>
#include <sys/mman.h>
#include <sys/epoll.h>
#include <sys/types.h> /* opendir, open, mkdir, stat */
#include <sys/stat.h>  /* open, mkdir, stat */
#include <dirent.h>    /* opendir */
#include <fcntl.h>     /* open */
#include <sys/ioctl.h>
#include <termios.h>   /* TIOCSCTTY */
#include "fail.h"
#include "c99.h"
#include "mem.h"

#define sys_repeat(out, expr) \
  do (out)=(expr); while ((out)==-1 && errno==EINTR)
#define sys_try(out, expr, on_fail) do { \
  sys_repeat(out,expr); \
  if((out)==-1) { on_fail; } \
} while(0)

/*==================================================
  mmap'd memory
  ==================================================*/

#ifdef SYS_VALGRIND
#include <valgrind/valgrind.h>
#include <valgrind/memcheck.h>

static inline void *mremap_for_valgrind(
  void *old_address, size_t old_size, size_t new_size, int flags)
{
  void *mres = mremap(old_address, old_size, new_size, flags);

  if (mres != MAP_FAILED) {
    VALGRIND_MAKE_MEM_NOACCESS(old_address, old_size);
    VALGRIND_MAKE_MEM_DEFINED(mres, new_size);
  }

  return mres;
}
#define mremap(...) mremap_for_valgrind(__VA_ARGS__)
#endif

static long page_sz;

struct sysbuf { void *restrict ptr; size_t base,pgn, n,max; };

static int sysbuf_rsz(struct sysbuf *restrict a, const size_t pgn)
{
  void *p;
  if(a->ptr==0) {
    if(pgn==0) return 0;
    p = mmap(0,pgn*page_sz,PROT_READ|PROT_WRITE,
             MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    #if PRINT_MALLOCS
    printf("mmap [%p,%p)\n", p,(unsigned char*)p+pgn*page_sz),fflush(stdout);
    #endif
  } else {
    void *base = (unsigned char*)a->ptr - a->base;
    if(pgn==0) {
      #if PRINT_MALLOCS
      printf("unmap [%p,%p)\n", base,(unsigned char*)base+a->pgn*page_sz);
      fflush(stdout);
      #endif
      if(munmap(base,a->pgn*page_sz)) failerr(1,"munmap failed");
      a->ptr=0; a->base=a->pgn=0; return 0;
    }
    p = mremap(base,a->pgn*page_sz,pgn*page_sz,MREMAP_MAYMOVE);
    #if PRINT_MALLOCS
    printf("mremap [%p,%p) -> [%p,%p)\n",
            base,(unsigned char*)base+a->pgn*page_sz,
            p,(unsigned char*)p+pgn*page_sz), fflush(stdout);
    #endif
  }
  if(p == MAP_FAILED) return -1;
  a->ptr = (unsigned char*)p + a->base;
  a->pgn = pgn;
  return 0;
}

void sysbuf_reset(struct sysbuf *restrict a, const size_t size)
{
  if(a->ptr!=0) a->ptr = (unsigned char*)a->ptr - a->base;
  a->base = 0;
  a->n = 0;
  a->max = (a->pgn*page_sz)/size;
}

void sysbuf_free(struct sysbuf *restrict a)
{
  sysbuf_rsz(a,0); a->n=a->max=0;
}

int sysbuf_reserve(struct sysbuf *restrict a, size_t min, size_t size)
{
  size_t pmin = (a->base+(min*size)+page_sz-1)/page_sz;
  size_t pgn = a->pgn;
  if(pgn<pmin) {
    pgn += pgn/2;
    if(pgn<pmin) pgn=pmin;
    if(sysbuf_rsz(a,pgn)) {
      if(pgn>pmin && (sysbuf_rsz(a,pmin)==0)) pgn=pmin;
      else return -1;
    }
    a->max = (pgn*page_sz-a->base)/size;
  }
  return 0;
}

void sysbuf_shrink_dn(struct sysbuf *restrict a, size_t max, size_t size)
{
  size_t pmax = (a->base+(max*size)+page_sz-1)/page_sz;
  if(pmax<a->pgn) {
    if(sysbuf_rsz(a,pmax)) failerr(1,"could not shrink mmap region");
    a->max = (pmax*page_sz-a->base)/size;
  }
}

void sysbuf_shrink_up(struct sysbuf *restrict a, size_t n, size_t size)
{
  size_t cruft = a->base + (n*size),
         pn = cruft/page_sz, base = cruft%page_sz;
  void *pbase;
  if(a->ptr==0 || pn>a->pgn || n>a->n)
    fail(1,"invalid call to sysbuf_shrink_up");
  pbase = (unsigned char*)a->ptr - a->base;
  if(pn) {
    #if PRINT_MALLOCS
    printf("unmap [%p,%p)\n", pbase,(unsigned char*)pbase+pn*page_sz);
    fflush(stdout);
    #endif
    if(munmap(pbase,pn*page_sz)) failerr(1,"munmap failed");
    pbase = (unsigned char*)pbase + pn*page_sz;
    a->pgn -= pn;
    if(a->pgn==0) { a->ptr=0; a->base=a->n=a->max=0; return; }
  }
  a->base = base;
  a->ptr = (unsigned char*)pbase + base;
  a->n -= n, a->max -= n;
}

/*==================================================
  I/O wrappers
  ==================================================*/

ssize_t sys_read(int fd, void *buf, size_t count)
{
  ssize_t nread = 0;
  while(count) {
    ssize_t n=read(fd,buf,count);
    if(n==-1) {
      if(errno==EINTR) continue;
      return -1;
    } else if(n==0) break; /* end of file */
    buf=(char *)buf + n, count-=n, nread+=n;
  }
  return nread;
}

int sys_write(int fd, const void *buf, size_t count)
{
  while(count) {
    ssize_t n=write(fd,buf,count);
    if(n==-1) {
      if(errno==EINTR) continue;
      return -1;
    }
    buf=(const char *)buf + n, count-=n;
  }
  return 0;
}

/*==================================================
  printf wrappers
  ==================================================*/

static buffer bprintf_buf = null_buffer;

#define BPRINTF_BODY() do { \
  int n; \
  va_list ap; \
  va_start(ap,fmt); \
  n=vsnprintf(bprintf_buf.ptr,bprintf_buf.max,fmt,ap); \
  va_end(ap); \
  if(n>=0 && (unsigned)n>=bprintf_buf.max) { \
    buffer_reserve(&bprintf_buf,n+1); \
    va_start(ap,fmt); \
    bprintf_buf.n=1+vsnprintf(bprintf_buf.ptr,bprintf_buf.max,fmt,ap); \
    va_end(ap); \
  } else \
    bprintf_buf.n=n+1; \
} while(0)

char *bprintf(const char *fmt, ...)
{
  BPRINTF_BODY();
  return bprintf_buf.ptr;
}

int fdprintf(int fd, const char *fmt, ...)
{
  BPRINTF_BODY();
  return sys_write(fd,bprintf_buf.ptr,bprintf_buf.n-1);
}

#undef BPRINTF_BODY

char *mprintf(const char *fmt, ...)
{
  int n;
  va_list ap;
  va_start(ap,fmt);
  n=vsnprintf(0,0,fmt,ap);
  va_end(ap);
  if(n>=0) {
    char *out = tmalloc(char,n+1);
    va_start(ap,fmt);
    vsnprintf(out,n+1,fmt,ap);
    va_end(ap);
    return out;
  }
  return 0;
}

/*==================================================
  file system related
  ==================================================*/

void chk_or_mkdir(const char *path)
{
  struct stat buf;
  if(stat(path,&buf)) {
    if(errno==ENOENT) {
      mkdir(path,0700);
      if(stat(path,&buf)) failerr(1,"could not stat %s", path);
    } else failerr(1,"could not stat %s", path);
  } else if(!(S_ISDIR(buf.st_mode))) fail(1,"%s not a directory",path);
}

int chk_or_mkfifo(int *restrict fd, const char *fifo_name)
{
  sys_repeat(*fd,open(fifo_name,O_WRONLY|O_NONBLOCK));
  if(*fd>=0) { /* someone is listening */
    fcntl(*fd,F_SETFL,O_WRONLY);
    return 1;
  } else {         /* nobody listening */
    switch(errno) {
      case ENOENT: /* because it doesn't exist */
        if(mkfifo(fifo_name,0600)==-1)
          failerr(1,"could not create FIFO %s",fifo_name);
        break;
      case ENXIO: /* it's there, but nobodoy listening */
        break;
      default:
        failerr(1,"error opening FIFO %s", fifo_name);
        break;
    }
    /* ask for write access only to prevent EOF from ever being set */
    sys_try(*fd,open(fifo_name,O_RDWR|O_NONBLOCK),
      failerr(1,"error re-opening FIFO %s", fifo_name));
    return 0;
  }
}


void sys_setenv(const char *name, const char *val)
{ setenv(name,val,1); }

#define MAX_STATIC_PROCPATH 256
static char s_procpath[MAX_STATIC_PROCPATH];
static char *the_procpath=0;

static void get_procpath(void) {
  static char slink[1024]; ssize_t max=1024;
  const char *dir; char *link = slink;
  buffer buf=null_buffer;
  for(;;) {
    ssize_t len = readlink("/proc/self/exe",link,max);
    if(len==-1) failerr(1,"could not read /proc/self/exe");
    if(len<max) { link[len]=0; break; }
    max*=2, link=buffer_resize(&buf,max);
  }
  dir = dirname(link);
  max = strlen(dir)+1;
  the_procpath = max>MAX_STATIC_PROCPATH ? tmalloc(char,max) : s_procpath;
  memcpy(the_procpath,dir,max);
  buffer_free(&buf);
}

const char *procpath(void)
{
  if(!the_procpath) get_procpath();
  return the_procpath;
}

static void close_after(int fdmax)
{
  int dfd;
  DIR *d = opendir("/proc/self/fd");
  const struct dirent *de;
  if(d==0) failerr(1,"failed to open /proc/self/fd");
  dfd = dirfd(d);
  while(de=readdir(d)) {
    int fd = atoi(de->d_name);
    if(de->d_name[0]=='.' | de->d_name[0]==0) continue;
    if(fd==dfd || fd<=fdmax) continue;
    close(fd);
  }
  closedir(d);
}

/*==================================================
  synchronous signal handling, waiting for input
  ==================================================*/

static void print_trace(void)
{
  void *array[100];
  size_t i,size = backtrace(array, 100);
  char **strings = backtrace_symbols (array, size);
  fprintf(stderr,"Backtrace:\n");
  for(i=0; i<size; ++i) fprintf(stderr, "  %s\n", strings[i]);
  fflush(stderr);
  free(strings);
}

static void catch_sigsegv(int signum)
{
  fprintf(stderr,"received SIGSEGV\n"), fflush(stderr);
  print_trace();
  signal(SIGSEGV,SIG_DFL);
  raise(SIGSEGV);
}

static volatile sig_atomic_t caught_sig[NSIG];
struct sig_data { int signum; void (*fun)(int); };
static struct sig_data sig_data[NSIG];
static int sig_n = 0;
static sigset_t sig_mask;

static void catch_any(int signum) { caught_sig[signum]=1; }

void install_handler(int signum, void (*fun)(int))
{
  struct sigaction sa;
  if(sig_n == NSIG) failerr(1,"too many signals");
  if(!sig_n) sigemptyset(&sig_mask);
  if(sigaddset(&sig_mask,signum)==-1)
    failerr(1,"install signal handler failed (invalid signum)");
  sig_data[sig_n].signum=signum;
  sig_data[sig_n].fun=fun;
  ++sig_n;

  sa.sa_handler = &catch_any;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  if(sigaction(signum,&sa,0)==-1)
    failerr(1,"install signal handler: sigaction failed");
}

static void reset_sigs(void)
{
  int i, n = sig_n;
  for(i=0;i<n;++i) signal(sig_data[i].signum,SIG_DFL);
}

static int check_sigs_aux(void)
{
  int did_something=0, i;
  for(i=0;i<sig_n;++i) {
    int signum = sig_data[i].signum;
    if(caught_sig[signum]) sig_data[i].fun(signum), did_something=1;
    caught_sig[signum]=0;
  }
  return did_something;
}

static int epoll_fd = -1;

void watch_fd(int fd)
{
  struct epoll_event ev;
  memset(&ev,0,sizeof(struct epoll_event));
  if(epoll_fd==-1 && -1==(epoll_fd=epoll_create1(EPOLL_CLOEXEC)))
    failerr(1,"could not create epoll");
  ev.events=EPOLLIN;
  ev.data.fd=fd;
  if(-1==epoll_ctl(epoll_fd,EPOLL_CTL_ADD,fd,&ev))
    failerr(1,"epoll_ctl failed");
}

void watch_fd_writable(int fd, int writable)
{
  struct epoll_event ev;
  memset(&ev,0,sizeof(struct epoll_event));
  ev.events = EPOLLIN | (writable ? EPOLLOUT : 0);
  ev.data.fd = fd;
  if(-1==epoll_ctl(epoll_fd,EPOLL_CTL_MOD,fd,&ev))
    failerr(1,"epoll_ctl mod failed");
}

static int wait_gen(int efd, int block)
{
  int out=-1;
  sigset_t oldmask;
  sigprocmask(SIG_BLOCK,sig_n?&sig_mask:0,&oldmask);
  if(check_sigs_aux())
    out=-2;
  else if(efd==-1) { int d;
    if(block) { out=-2; do sigsuspend(&oldmask),d=check_sigs_aux(); while(!d); }
  } else {
    do {
      struct epoll_event ev; int n;
      n=epoll_pwait(efd,&ev,1,-1,&oldmask);
      if(n==0 || (n==-1 && errno==EINTR)) {
        if(check_sigs_aux()) { out=-2; break; } else continue;
      } else if(n==-1)
        failerr(1,"epoll_pwait failed");
      if(ev.events&(EPOLLIN|EPOLLOUT)) { out = ev.data.fd; break; }
    } while(block);
  }
  if(sig_n) sigprocmask(SIG_UNBLOCK,&sig_mask,0);
  return out;
}

int check_sigs(int block) { return wait_gen(-1,block)==-2; }
int wait_for_fd(int block) { return wait_gen(epoll_fd,block); }

void sys_init(void)
{
  page_sz = sysconf(_SC_PAGESIZE);
  signal(SIGSEGV,&catch_sigsegv);
}

void sys_done(void)
{
  buffer_free(&bprintf_buf);
  if(the_procpath && the_procpath != s_procpath) free(the_procpath);
  if(epoll_fd!=-1) { int e;
    sys_try(e,close(epoll_fd),failerr(1,"could not close epoll"));
  }
}

/*==================================================
  pseudo terminal
  ==================================================*/

struct pty { int fdm; pid_t child; };

static void get_pty_chdir(int argc, char *argv[]) {
  int i;
  for(i=1;i<argc;++i) {
    if( strcmp(argv[i],"-d")==0 ) {
      if(++i >=argc) return;
      if(chdir(argv[i])) return;
      return;
    }
  }
}

struct pty get_pty(int watch, int argc, char *argv[])
{
  struct pty p = { -1, -1 };
  const char *slave;

  sys_repeat(p.fdm,open("/dev/ptmx", O_RDWR|O_NOCTTY));
  if(p.fdm==-1) { warnerr("could not open /dev/ptmx to create pseudo-terminal");
    return p; }
  #define GET_PTY_FAIL(msg) do { int e; \
    warnerr(msg); \
    sys_try(e,close(p.fdm),warnerr("could not close pseudo-terminal fd")); \
    p.fdm = -1; return p; \
  } while(0)
  if(grantpt(p.fdm)) GET_PTY_FAIL("grantpt() failed");
  if(unlockpt(p.fdm)) GET_PTY_FAIL("unlockpt() failed");
  if(!(slave=ptsname(p.fdm))) GET_PTY_FAIL("ptsname() failed");
  fcntl(p.fdm,F_SETFL,O_NONBLOCK);

  p.child = fork();
  if(p.child==-1) GET_PTY_FAIL("fork failed");
  else if(p.child==0) {
    pid_t sid; int fds;
    char *shell, *sargv[] = {0,0};
    get_pty_chdir(argc,argv);
    reset_sigs();
    close_after(-1);
    shell = getenv("SHELL");
    if(!shell) shell = "/bin/sh";
    argv[0]=shell;
    sid = setsid(); /* new process session */
    sys_try(fds,open(slave,O_RDWR),exit(1));
    if(dup2(fds,0)==-1 || dup2(fds,1)==-1 || dup2(fds,2)==-1) exit(1);
    if(fds>2) close(fds);
    ioctl(0,TIOCSCTTY,0); /* make the new pseudo-terminal the controlling tty */
    tcsetpgrp(0, sid); /* make sid the terminal foreground process group */
    /* close(open(dev, O_RDWR)); */
    sargv[0]=shell; execvp(shell,sargv);
    exit(1);
  }
  if(watch) watch_fd(p.fdm);
  return p;
}

void pty_set_size(int fd, unsigned w, unsigned h)
{
  struct winsize ws;
  memset(&ws,0,sizeof(ws));
  ws.ws_row=h;
  ws.ws_col=w;
  if(-1==ioctl(fd,TIOCSWINSZ,&ws)) warnerr("ioctl TIOCSWINSZ failed");
}
