
/* event_type: 0 or 1 = press (legacy), 2 = repeat, 3 = release */
const uchar *keyseq_lookup(unsigned long key, uchar mod, uchar mode,
                           int event_type);
