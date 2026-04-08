#ifndef MEM_H
#define MEM_H

/* requires:
     <stddef.h> for size_t, offsetof
     <stdlib.h> for malloc, calloc, realloc, free
     <string.h> for memcpy
     "c99.h"
     "fail.h"
*/

#if !defined(C99_H) || !defined(FAIL_H)
#error "mem.h" requires "c99.h" and "fail.h"
#endif

#ifndef PRINT_MALLOCS
#  define PRINT_MALLOCS 0
#else
#  include <stdio.h>
#endif

/*--------------------------------------------------------------------------
   Memory Allocation Wrappers to Catch Out-of-memory
  --------------------------------------------------------------------------*/

static inline void *smalloc(size_t size, const char *file, unsigned line)
{
  void *restrict res = malloc(size);
  #if PRINT_MALLOCS
  printf("MEM: %p = malloc(%ld) @ %s(%u)\n",res,(long)size,file,line);
  #endif
  if(!res && size)
    fail(1,"%s(%u): allocation of %ld bytes failed\n",file,line,(long)size);
  return res;
}

static inline void *scalloc(
  size_t nmemb, size_t size, const char *file, unsigned line)
{
  void *restrict res = calloc(nmemb, size);
  #if PRINT_MALLOCS
  printf("MEM: %p = calloc(%ld) @ %s(%u)\n",res,(long)size*nmemb,file,line);
  #endif
  if(!res && nmemb)
    fail(1,"%s(%u): allocation of %ld bytes failed\n",file,line,
           (long)size*nmemb);
  return res;
}

static inline void *srealloc(
  void *restrict ptr, size_t size, const char *file, unsigned line)
{
  void *restrict res = realloc(ptr, size);
  #if PRINT_MALLOCS
  if(res!=ptr) {
    if(ptr)
      printf("MEM: %p freed by realloc @ %s(%u)\n",ptr,file,line);
    printf("MEM: %p = realloc of %p to %lu @ %s(%u)\n",
           res,ptr,(long)size,file,line);
  } else
    printf("MEM: %p realloc'd to %lu @ %s(%u)\n",res,(long)size,file,line);
  #endif
  if(!res && size)
    fail(1,"%s(%u): allocation of %ld bytes failed\n",file,line,(long)size);
  return res;
}

#define tmalloc(type, count) \
  ((type*) smalloc((count)*sizeof(type),__FILE__,__LINE__) )
#define tcalloc(type, count) \
  ((type*) scalloc((count),sizeof(type),__FILE__,__LINE__) )
#define trealloc(type, ptr, count) \
  ((type*) srealloc((ptr),(count)*sizeof(type),__FILE__,__LINE__) )

#if PRINT_MALLOCS
static inline void sfree(void *restrict ptr, const char *file, unsigned line)
{
  free(ptr);
  printf("MEM: %p freed @ %s(%u)\n",ptr,file,line);
}
#define free(x) sfree(x,__FILE__,__LINE__)
#endif

/*--------------------------------------------------------------------------
   A dynamic array
  --------------------------------------------------------------------------*/
struct array { void *restrict ptr; size_t n,max; };
#define null_array {0,0,0}
static inline void array_init_(
  struct array *restrict a, size_t max, size_t size,
  const char *file, unsigned line)
{
  a->n=0, a->max=max, a->ptr=smalloc(max*size,file,line);
}
static inline void *array_resize_(
  struct array *restrict a, size_t max, size_t size,
  const char *file, unsigned line)
{
  a->max=max; return a->ptr=srealloc(a->ptr,max*size,file,line);
}
static inline void *array_reserve_(
  struct array *restrict a, size_t min, size_t size,
  const char *file, unsigned line)
{
  size_t max = a->max;
  if(max<min) {
    max+=max/2+1;
    if(max<min) max=min;
    return array_resize_(a,max,size,file,line);
  }
  return a->ptr;
}
static void array_copy_(struct array *restrict dst,
                        const struct array *restrict src,
                        size_t size, const char *file, unsigned line)
{
  array_reserve_(dst,src->n,size,file,line);
  memcpy(dst->ptr,src->ptr,src->n*size);
  dst->n=src->n;
}
#define array_free(a) free((a)->ptr)
#define array_init(T,a,max) array_init_(a,max,sizeof(T),__FILE__,__LINE__)
#define array_resize(T,a,max) \
  ((T*)array_resize_(a,max,sizeof(T),__FILE__,__LINE__))
#define array_reserve(T,a,min) \
  ((T*)array_reserve_(a,min,sizeof(T),__FILE__,__LINE__))
#define array_data(T,a) ((T*)(a)->ptr)
#define array_copy(T,dst,src) array_copy_(dst,src,sizeof(T),__FILE__,__LINE__)

/*--------------------------------------------------------------------------
   Buffer = char array
  --------------------------------------------------------------------------*/
typedef struct array buffer;
#define null_buffer null_array
#define buffer_init(b,max) array_init_(b,max,1,__FILE__,__LINE__)
#define buffer_resize(b,max) array_resize_(b,max,1,__FILE__,__LINE__)
#define buffer_reserve(b,min) array_reserve_(b,min,1,__FILE__,__LINE__)
#define buffer_free(b) array_free(b)

/*--------------------------------------------------------------------------
   Alignment routines
  --------------------------------------------------------------------------*/
#define ALIGNOF(T) offsetof(struct { char c; T x; }, x)
static inline size_t align_as_(size_t a, size_t n) { return (n+a-1)/a*a; }
#define align_as(T,n) align_as_(ALIGNOF(T),n)
#define align_ptr(T,base,offset) ((T*)((char*)(base)+align_as(T,offset)))
#endif

