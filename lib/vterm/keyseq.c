#include <stdio.h>
#include "keys.h"
#include "keyseq.h"

typedef unsigned char uchar;

/* mode */
#define APP_KEYPAD 1u
#define APP_CURSOR 2u
#define META       4u

static char buf[24];

/* format helpers for event_type:
   evt<=1 means press (omit event_type),
   evt>1 appends :evt to the modifier field */
#define FMT_CSI_LETTER(pre,m,evt,c) \
  (evt>1 ? sprintf(buf,"\033[" pre ";%c:%d%c",m,evt,c) \
         : sprintf(buf,"\033[" pre ";%c%c",m,c))
#define FMT_CSI_LETTER_NOMODS(pre,evt,c) \
  (evt>1 ? sprintf(buf,"\033[" pre ";1:%d%c",evt,c) \
         : sprintf(buf,"\033[" pre "%c",c))
#define FMT_CSI_TILDE(n,m,evt) \
  (evt>1 ? sprintf(buf,"\033[%s;%c:%d~",n,m,evt) \
         : sprintf(buf,"\033[%s;%c~",n,m))
#define FMT_CSI_TILDE_NOMODS(n,evt) \
  (evt>1 ? sprintf(buf,"\033[%s;1:%d~",n,evt) \
         : sprintf(buf,"\033[%s~",n))

const uchar *keyseq_lookup(
    unsigned key, unsigned mod, unsigned mode, int event_type)
{
  int i;
  static const char crsr[]  = {'A','B','C','D','H','F','E'};
  static const char crsrn[] = {'8','2','6','4','7','1','5'};
  static const char crsrv[] = {'x','r','v','t','w','q','u'};
  unsigned sac = mod & ~MOD_NUM_LOCK;
  char m = '1' + sac;
  int evt = event_type;
  if(key==KEY_ENTER && (sac&MOD_SHIFT) && evt<=1)
    { buf[0]='\n'; buf[1]=0; return (const uchar *)buf; }
  switch(key) {
    case KEY_UP:        i=0; break;
    case KEY_DOWN:      i=1; break;
    case KEY_RIGHT:     i=2; break;
    case KEY_LEFT:      i=3; break;
    case KEY_HOME:      i=4; break;
    case KEY_END:       i=5; break;
    default: goto cursor_kp;
  }
  if(sac==0) {
    if(evt<=1) sprintf(buf,"\033%c%c",mode&APP_CURSOR?'O':'[',crsr[i]);
    else FMT_CSI_LETTER_NOMODS("1",evt,crsr[i]);
  } else FMT_CSI_LETTER("1",m,evt,crsr[i]);
  return (const uchar *)buf;
cursor_kp:
  switch(key) {
    case KEY_KP_UP:    i=0; break;
    case KEY_KP_DOWN:  i=1; break;
    case KEY_KP_RIGHT: i=2; break;
    case KEY_KP_LEFT:  i=3; break;
    case KEY_KP_HOME:  i=4; break;
    case KEY_KP_END:   i=5; break;
    case KEY_KP_BEGIN: i=6; break;
    default: goto edit;
  }
  if(   (mod&(MOD_NUM_LOCK|MOD_SHIFT)) == MOD_NUM_LOCK
     || (mod&(MOD_NUM_LOCK|MOD_SHIFT)) == MOD_SHIFT    ) {
    if((mod&MOD_NUM_LOCK)==0 && (mode&APP_KEYPAD))
      sprintf(buf,"\033O%c",crsrv[i]);
    else
      sprintf(buf,"%c",crsrn[i]);
  } else if((mode&APP_KEYPAD) || sac==0) {
    if(evt<=1) sprintf(buf,"\033%c%c",mode&APP_CURSOR?'O':'[',crsr[i]);
    else FMT_CSI_LETTER_NOMODS("1",evt,crsr[i]);
  } else FMT_CSI_LETTER("1",m,evt,crsr[i]);
  return (const uchar *)buf;
edit: {
  static const char edit[]  = {'2','3','5','6'};
  static const char editn[] = {'0','.','9','3'};
  static const char editv[] = {'p','n','y','s'};
  switch(key) {
    case KEY_INSERT:    i=0; break;
    case KEY_DELETE:    i=1; break;
    case KEY_PAGE_UP:   i=2; break;
    case KEY_PAGE_DOWN: i=3; break;
    default: goto edit_kp;
  }
  { char ns[2] = {edit[i], 0};
    if(sac==0) FMT_CSI_TILDE_NOMODS(ns,evt);
    else       FMT_CSI_TILDE(ns,m,evt);
  }
  return (const uchar *)buf;
edit_kp:
  switch(key) {
    case KEY_KP_INSERT:    i=0; break;
    case KEY_KP_DELETE:    i=1; break;
    case KEY_KP_PAGE_UP:   i=2; break;
    case KEY_KP_PAGE_DOWN: i=3; break;
    default: goto keypad;
  }
  if(   (mod&(MOD_NUM_LOCK|MOD_SHIFT)) == MOD_NUM_LOCK
     || (mod&(MOD_NUM_LOCK|MOD_SHIFT)) == MOD_SHIFT    ) {
    if((mod&MOD_NUM_LOCK)==0 && (mode&APP_KEYPAD))
      sprintf(buf,"\033O%c",editv[i]);
    else
      sprintf(buf,"%c",editn[i]);
  } else {
    char ns[2] = {edit[i], 0};
    if((mode&APP_KEYPAD) || sac==0) FMT_CSI_TILDE_NOMODS(ns,evt);
    else FMT_CSI_TILDE(ns,m,evt);
  }
  return (const uchar *)buf;
  }
keypad: {
  static const char kpv[13]  =      " IMPQRSjklmoX";
  static const char kpn[13] =  " \x9\xd????*+,-/=";
  switch(key){
    case KEY_KP_SPACE:     i= 0; break;
    case KEY_KP_TAB:       i= 1; break;
    case KEY_KP_ENTER:     i= 2; break;
    case KEY_KP_F1:        i= 3; break;
    /* KP_F2/F3/F4 map to KEY_F2/F3/F4 (identical SS3 sequences),
       handled by the F1-F4 block below */
    case KEY_KP_MULTIPLY:  i= 7; break;
    case KEY_KP_ADD:       i= 8; break;
    case KEY_KP_SEPARATOR: i= 9; break;
    case KEY_KP_SUBTRACT:  i=10; break;
    case KEY_KP_DIVIDE:    i=11; break;
    case KEY_KP_EQUAL:     i=12; break;
    default: goto fk_low;
  }
  if((mode&APP_KEYPAD) || (i>=3&&i<7)) sprintf(buf,"\033O%c",kpv[i]);
  else sprintf(buf,"%c",kpn[i]);
  return (const uchar *)buf;
  }
fk_low:
  switch(key){
    case KEY_F1:  i= 0; break;
    case KEY_F2:  i= 1; break;
    case KEY_F3:  i= 2; break;
    case KEY_F4:  i= 3; break;
    default: goto fk_high;
  }
  if(sac==0) {
    if(evt<=1) sprintf(buf,"\033O%c",'P'+i);
    else FMT_CSI_LETTER_NOMODS("1",evt,'P'+i);
  } else FMT_CSI_LETTER("1",m,evt,'P'+i);
  return (const uchar *)buf;
fk_high: {
  static const char *fkh[] = {"15","17","18","19","20","21","23","24",
                              "25","26","28","29","31","32","33","34"};
  switch(key){
    case KEY_F5 :  i= 0; break;
    case KEY_F6 :  i= 1; break;
    case KEY_F7 :  i= 2; break;
    case KEY_F8 :  i= 3; break;
    case KEY_F9 :  i= 4; break;
    case KEY_F10:  i= 5; break;
    case KEY_F11:  i= 6; break;
    case KEY_F12:  i= 7; break;
    case KEY_F13:  i= 8; break;
    case KEY_F14:  i= 9; break;
    case KEY_F15:  i=10; break;
    case KEY_F16:  i=11; break;
    case KEY_F17:  i=12; break;
    case KEY_F18:  i=13; break;
    case KEY_F19:  i=14; break;
    case KEY_F20:  i=15; break;
    default: return 0;
  }
  if(sac==0) FMT_CSI_TILDE_NOMODS(fkh[i],evt);
  else FMT_CSI_TILDE(fkh[i],m,evt);
  return (const uchar *)buf;
  }
}
