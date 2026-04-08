#ifndef FAIL_H
#define FAIL_H

#ifdef __GNUC__
#  define ATTRB1  __attribute__ ((noreturn))
#  define ATTRB2V __attribute__ ((format(printf,1,0)))
#  define ATTRB2  __attribute__ ((format(printf,1,2)))
#  define ATTRB3V __attribute__ ((noreturn,format(printf,2,0)))
#  define ATTRB3  __attribute__ ((noreturn,format(printf,2,3)))
#else
#  define ATTRB1
#  define ATTRB2V
#  define ATTRB2
#  define ATTRB3V
#  define ATTRB3
#endif

#define DEF_FUNS() \
   void  die    (int status)                              ATTRB1 ; \
   void  warn   (const char *fmt, ...)                    ATTRB2 ; \
   void  warnerr(const char *fmt, ...)                    ATTRB2 ; \
   void  fail   (int status, const char *fmt, ...)        ATTRB3 ; \
   void  failerr(int status, const char *fmt, ...)        ATTRB3 ;
#define VDEF_FUNS() \
   void vwarn   (const char *fmt, va_list ap)             ATTRB2V; \
   void vwarnerr(const char *fmt, va_list ap)             ATTRB2V; \
   void vfail   (int status, const char *fmt, va_list ap) ATTRB3V; \
   void vfailerr(int status, const char *fmt, va_list ap) ATTRB3V;
DEF_FUNS()
#ifdef va_arg
VDEF_FUNS()
#endif

#undef VDEF_FUNS
#undef DEF_FUNS
#undef ATTRB3
#undef ATTRB3V
#undef ATTRB2
#undef ATTRB2V
#undef ATTRB1

#endif
