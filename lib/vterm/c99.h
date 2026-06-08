#ifndef C99_H
#define C99_H

#include "types.h"

#ifndef __STDC_VERSION__
#  define NO_C99
#elif __STDC_VERSION__ < 199901L
#  define NO_C99
#endif

#ifdef NO_C99
#  define restrict
#  define inline
#  if UCHAR_BITS>=32
     typedef unsigned char  uint32;
#  elif USHRT_BITS>=32
     typedef unsigned short uint32;
#  elif UINT_BITS>=32
     typedef unsigned int   uint32;
#  else
     typedef unsigned long  uint32;
#  endif
#  if ULLONG_BITS>=64
     typedef unsigned long long uint64;
#  else
     typedef unsigned long      uint64;
#  endif
#  undef NO_C99
#else
#  include <stdint.h>
   typedef uint_least32_t uint32;
   typedef uint_least64_t uint64;
#endif

#endif
