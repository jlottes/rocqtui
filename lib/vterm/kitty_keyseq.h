#ifndef KITTY_KEYSEQ_H
#define KITTY_KEYSEQ_H

/* event_type: 1=press, 2=repeat, 3=release
   text/text_len: UTF-8 text (for kitty flag bit 4) */
const unsigned char *kitty_keyseq_lookup(
    unsigned key, unsigned shifted_key,
    unsigned mod, unsigned mode,
    unsigned kitty_flags, int event_type,
    const unsigned char *text, unsigned text_len);

#endif
