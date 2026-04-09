#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <stdio.h>

typedef unsigned char uchar;

static char buf[24];

/* mod */
#define SHIFT    1u
#define ALT      2u
#define CTRL     4u
#define NUM_LOCK 8u

/* mode */
#define APP_KEYPAD 1u
#define APP_CURSOR 2u
#define META 4u

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

const uchar *keyseq_lookup(unsigned long key, uchar mod, uchar mode,
                           int event_type)
{
  int i;
  static const char crsr[]  = {'A','B','C','D','H','F','E'};
  static const char crsrn[] = {'8','2','6','4','7','1','5'};
  static const char crsrv[] = {'x','r','v','t','w','q','u'};
  uchar sac = mod&~NUM_LOCK;
  char m = '1' + sac;
  int evt = event_type;
  if(key==XK_Return && (sac&SHIFT) && evt<=1)
    { buf[0]='\n'; buf[1]=0; return (const uchar *)buf; }
  switch((KeySym)key) {
    case XK_Up:        i=0; break;
    case XK_Down:      i=1; break;
    case XK_Right:     i=2; break;
    case XK_Left:      i=3; break;
    case XK_Home:      i=4; break;
    case XK_End:       i=5; break;
    default: goto cursor_kp;
  }
  if(sac==0) {
    if(evt<=1) sprintf(buf,"\033%c%c",mode&APP_CURSOR?'O':'[',crsr[i]);
    else FMT_CSI_LETTER_NOMODS("1",evt,crsr[i]);
  } else FMT_CSI_LETTER("1",m,evt,crsr[i]);
  return (const uchar *)buf;
cursor_kp:
  switch((KeySym)key) {
    case XK_KP_8: case XK_KP_Up:        i=0; break;
    case XK_KP_2: case XK_KP_Down:      i=1; break;
    case XK_KP_6: case XK_KP_Right:     i=2; break;
    case XK_KP_4: case XK_KP_Left:      i=3; break;
    case XK_KP_7: case XK_KP_Home:      i=4; break;
    case XK_KP_1: case XK_KP_End:       i=5; break;
    case XK_KP_5: case XK_KP_Begin:     i=6; break;
    default: goto edit;
  }
  if(   (mod&(NUM_LOCK|SHIFT)) == NUM_LOCK
     || (mod&(NUM_LOCK|SHIFT)) == SHIFT    ) {
    if((mod&NUM_LOCK)==0 && (mode&APP_KEYPAD))
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
  switch((KeySym)key) {
    case XK_Insert:    i=0; break;
    case XK_Delete:    i=1; break;
    case XK_Page_Up:   i=2; break;
    case XK_Page_Down: i=3; break;
    default: goto edit_kp;
  }
  { char ns[2] = {edit[i], 0};
    if(sac==0) FMT_CSI_TILDE_NOMODS(ns,evt);
    else       FMT_CSI_TILDE(ns,m,evt);
  }
  return (const uchar *)buf;
edit_kp:
  switch((KeySym)key) {
    case XK_KP_0:       case XK_KP_Insert:    i=0; break;
    case XK_KP_Decimal: case XK_KP_Delete:    i=1; break;
    case XK_KP_9:       case XK_KP_Page_Up:   i=2; break;
    case XK_KP_3:       case XK_KP_Page_Down: i=3; break;
    default: goto keypad;
  }
  if(   (mod&(NUM_LOCK|SHIFT)) == NUM_LOCK
     || (mod&(NUM_LOCK|SHIFT)) == SHIFT    ) {
    if((mod&NUM_LOCK)==0 && (mode&APP_KEYPAD))
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
  switch((KeySym)key){
    case XK_KP_Space:     i= 0; break;
    case XK_KP_Tab:       i= 1; break;
    case XK_KP_Enter:     i= 2; break;
    case XK_KP_F1:        i= 3; break;
    case XK_KP_F2:        i= 4; break;
    case XK_KP_F3:        i= 5; break;
    case XK_KP_F4:        i= 6; break;
    case XK_KP_Multiply:  i= 7; break;
    case XK_KP_Add:       i= 8; break;
    case XK_KP_Separator: i= 9; break;
    case XK_KP_Subtract:  i=10; break;
    case XK_KP_Divide:    i=11; break;
    case XK_KP_Equal:     i=12; break;
    default: goto fk_low;
  }
  if((mode&APP_KEYPAD) || (i>=3&&i<7)) sprintf(buf,"\033O%c",kpv[i]);
  else sprintf(buf,"%c",kpn[i]);
  return (const uchar *)buf;
  }
fk_low:
  switch((KeySym)key){
    case XK_F1:  i= 0; break;
    case XK_F2:  i= 1; break;
    case XK_F3:  i= 2; break;
    case XK_F4:  i= 3; break;
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
  switch((KeySym)key){
    case XK_F5 :  i= 0; break;
    case XK_F6 :  i= 1; break;
    case XK_F7 :  i= 2; break;
    case XK_F8 :  i= 3; break;
    case XK_F9 :  i= 4; break;
    case XK_F10:  i= 5; break;
    case XK_F11:  i= 6; break;
    case XK_F12:  i= 7; break;
    case XK_F13:  i= 8; break;
    case XK_F14:  i= 9; break;
    case XK_F15:  i=10; break;
    case XK_F16:  i=11; break;
    case XK_F17:  i=12; break;
    case XK_F18:  i=13; break;
    case XK_F19:  i=14; break;
    case XK_F20:  i=15; break;
    default: return 0;
  }
  if(sac==0) FMT_CSI_TILDE_NOMODS(fkh[i],evt);
  else FMT_CSI_TILDE(fkh[i],m,evt);
  return (const uchar *)buf;
  }
}
