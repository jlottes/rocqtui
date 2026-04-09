#define _GNU_SOURCE
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/mman.h>
#include "sysbuf.h"

#ifndef PRINT_MALLOCS
#  define PRINT_MALLOCS 0
#endif

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
static void ensure_page_sz(void) { if(!page_sz) page_sz = sysconf(_SC_PAGESIZE); }

static int sysbuf_rsz(struct sysbuf *restrict a, const size_t pgn)
{
  void *p;
  ensure_page_sz();
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
      if(munmap(base,a->pgn*page_sz)) fprintf(stderr,"munmap failed: %s\n",strerror(errno)), abort();
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
  ensure_page_sz();
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
  size_t pmin;
  ensure_page_sz();
  pmin = (a->base+(min*size)+page_sz-1)/page_sz;
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
    if(sysbuf_rsz(a,pmax)) fprintf(stderr,"could not shrink mmap region: %s\n",strerror(errno)), abort();
    a->max = (pmax*page_sz-a->base)/size;
  }
}

void sysbuf_shrink_up(struct sysbuf *restrict a, size_t n, size_t size)
{
  size_t cruft = a->base + (n*size),
         pn = cruft/page_sz, base = cruft%page_sz;
  void *pbase;
  if(a->ptr==0 || pn>a->pgn || n>a->n)
    fprintf(stderr,"invalid call to sysbuf_shrink_up\n"), abort();
  pbase = (unsigned char*)a->ptr - a->base;
  if(pn) {
    #if PRINT_MALLOCS
    printf("unmap [%p,%p)\n", pbase,(unsigned char*)pbase+pn*page_sz);
    fflush(stdout);
    #endif
    if(munmap(pbase,pn*page_sz)) fprintf(stderr,"munmap failed: %s\n",strerror(errno)), abort();
    pbase = (unsigned char*)pbase + pn*page_sz;
    a->pgn -= pn;
    if(a->pgn==0) { a->ptr=0; a->base=a->n=a->max=0; return; }
  }
  a->base = base;
  a->ptr = (unsigned char*)pbase + base;
  a->n -= n, a->max -= n;
}
