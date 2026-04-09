#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/types.h>
#include "c99.h"
#include "mem.h"
#include "sysbuf.h"
#include "term.h"
#include "mouseseq.h"

/* mod bits (match XGL_*) */
#define SHIFT 1u
#define ALT   2u
#define CTRL  4u

unsigned mouseseq(unsigned char *buf,
  unsigned button, unsigned mod,
  unsigned cx, unsigned cy,
  unsigned ev, unsigned mode, unsigned flags)
{
  unsigned cb;

  /* X10 mode: press only, no modifiers */
  if(mode==MOUSE_MODE_X10) {
    if(ev!=MOUSE_EV_PRESS) return 0;
    if(button>=1 && button<=3) cb = button-1;
    else if(button==4||button==5) cb = button-4+64;
    else return 0;
    buf[0]='\033'; buf[1]='['; buf[2]='M';
    buf[3]=cb+32; buf[4]=cx+32; buf[5]=cy+32;
    return 6;
  }

  /* encode button value */
  if(ev==MOUSE_EV_RELEASE && !(flags&MOUSE_SGR)) cb = 3;
  else if(button>=1 && button<=3) cb = button-1;
  else if(button==4||button==5) cb = button-4+64;
  else if(button==6||button==7) cb = button-6+64+2;
  else if(button>=8 && button<=11) cb = button-8+128;
  else cb = 0;

  /* modifier bits */
  if(mod&SHIFT) cb|=4;
  if(mod&ALT)   cb|=8;
  if(mod&CTRL)  cb|=16;

  /* motion bit */
  if(ev==MOUSE_EV_MOTION) cb|=32;

  if(flags&MOUSE_SGR) {
    int n = sprintf((char*)buf, "\033[<%u;%u;%u%c",
      cb, cx, cy, ev==MOUSE_EV_RELEASE?'m':'M');
    return n>0 ? (unsigned)n : 0;
  }

  /* default encoding */
  if(cx>223) cx=223;
  if(cy>223) cy=223;
  buf[0]='\033'; buf[1]='['; buf[2]='M';
  buf[3]=cb+32; buf[4]=cx+32; buf[5]=cy+32;
  return 6;
}
