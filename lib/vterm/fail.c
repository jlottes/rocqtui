#define _GNU_SOURCE /* vsnprintf */
#include <stdio.h>  /* sprintf, vfprintf, stderr */
#include <stdarg.h> /* va_list, va_start, ... */
#include <stdlib.h> /* exit */
#include <string.h> /* memcpy, and str* functions */
#include <errno.h>
#include "fail.h"

void die(int status)
{
  exit(status);
}

#define MAX_MSG 2048
static char msg[MAX_MSG];

extern const char *const exe_name; /* defined right above main() */

#define SET_MSG(s) do { \
  int n1=strlen(exe_name),n2=strlen(s), n=n1+n2+2; \
  memcpy(msg,exe_name,n1); \
  msg[n1]=':'; msg[n1+1]=' '; \
  memcpy(msg+n1+2,s,n2); \
  vsnprintf(msg+n, MAX_MSG-n, fmt, ap); \
  msg[MAX_MSG-1]=0; \
} while(0)

#define FIN_MSG() do { \
  int n; \
  msg[MAX_MSG-1]=0; \
  n=strlen(msg); \
  if(n>MAX_MSG-2) n=MAX_MSG-2; \
  msg[n]='\n'; \
  msg[n+1]=0; \
  fputs(msg,stderr); \
} while(0)

#define WRAPPER0(name) \
void name(const char *fmt, ...) \
{ \
  va_list ap; va_start(ap,fmt); \
  v##name(fmt,ap); \
  va_end(ap); \
}

#define WRAPPER1(name) \
void name(int status, const char *fmt, ...) \
{ \
  va_list ap; va_start(ap,fmt); \
  v##name(status,fmt,ap); \
  va_end(ap); \
}

void vwarn(const char *fmt, va_list ap)
{
  SET_MSG("WARNING: "); FIN_MSG();
}
WRAPPER0(warn)

void vfail(int status, const char *fmt, va_list ap)
{
  SET_MSG("ERROR: "); FIN_MSG();
  die(status);
}
WRAPPER1(fail)

void vfailerr(int status, const char *fmt, va_list ap)
{
  int n;
  SET_MSG("ERROR: ");
  n = strlen(msg);
  snprintf(msg+n,MAX_MSG-n,": %s",strerror(errno));
  FIN_MSG();
  die(status);
}
WRAPPER1(failerr)

void vwarnerr(const char *fmt, va_list ap)
{
  int n;
  SET_MSG("WARNING: ");
  n = strlen(msg);
  snprintf(msg+n,MAX_MSG-n,": %s",strerror(errno));
  FIN_MSG();
}
WRAPPER0(warnerr)
