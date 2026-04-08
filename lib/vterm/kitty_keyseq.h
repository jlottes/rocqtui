
/* event_type: 1=press, 2=repeat, 3=release
   text/text_len: UTF-8 text from XLookupString (for flag bit 4) */
const uchar *kitty_keyseq_lookup(
    unsigned long keysym, unsigned long base_keysym,
    uchar xgl_mod, uchar mode,
    uchar kitty_flags, int event_type,
    const uchar *text, unsigned text_len);
