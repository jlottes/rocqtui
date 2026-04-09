#ifndef SYSBUF_H
#define SYSBUF_H

struct sysbuf { void *restrict ptr; size_t base,pgn, n,max; };
void sysbuf_reset(struct sysbuf *restrict a, const size_t size);
void sysbuf_free(struct sysbuf *restrict a);
int sysbuf_reserve(struct sysbuf *restrict a, size_t min, size_t size);
void sysbuf_shrink_dn(struct sysbuf *restrict a, size_t max, size_t size);
void sysbuf_shrink_up(struct sysbuf *restrict a, size_t n, size_t size);

#endif
