
#define MOUSE_EV_PRESS   0
#define MOUSE_EV_RELEASE 1
#define MOUSE_EV_MOTION  2

/* Returns length of encoded sequence written to buf.
   button: 1=left, 2=mid, 3=right, 4=scroll up, 5=scroll down, ...
   mod: XGL_SHIFT/XGL_ALT/XGL_CTRL bitmask
   cx, cy: 1-based cell coordinates
   ev: MOUSE_EV_PRESS / MOUSE_EV_RELEASE / MOUSE_EV_MOTION
   mode: MOUSE_MODE_*
   flags: MOUSE_SGR, etc. */
unsigned mouseseq(unsigned char *buf,
  unsigned button, unsigned mod,
  unsigned cx, unsigned cy,
  unsigned ev, unsigned mode, unsigned flags);
