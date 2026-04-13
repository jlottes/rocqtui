#ifndef KEYSEQ_H
#define KEYSEQ_H

/* event_type: 0 or 1 = press (legacy), 2 = repeat, 3 = release */
const unsigned char *keyseq_lookup(
    unsigned key, unsigned mod, unsigned mode, int event_type);

#endif
