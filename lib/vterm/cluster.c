#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include "c99.h"
#include "mem.h"
#include "cluster.h"

/* Hash over a uint32 sequence. Follows the style of string_hash.h:
   h ^= (h<<5) + (h>>2) + c, byte-feeding the four code-unit bytes. */
static unsigned long codes_hash(const uint32 *codes, unsigned n)
{
  unsigned long h = 0;
  unsigned i; unsigned j; unsigned c;
  for(i=0; i<n; ++i) {
    uint32 v = codes[i];
    for(j=0; j<4; ++j) {
      c = v & 0xffu; v >>= 8;
      h ^= (h<<5) + (h>>2) + c;
    }
  }
  return h;
}

/*--------------------------------------------------------------------------*/

static struct {
  /* codepoint storage */
  uint32 *codes; size_t codes_n, codes_max;

  /* offsets: offsets[0..n_entries] (with sentinel); length(i) = off[i+1]-off[i] */
  uint32 *offsets; size_t off_n, off_max;

  /* narrow bitmap: one bit per entry; clear = width 2, set = width 1 */
  uint64 *narrow; size_t narrow_words;

  /* dedup hash: open addressing, power-of-2 size; stores entry indices,
     CLUSTER_TABLE_NONE = empty slot */
  uint32 *hash; size_t hash_cap, hash_used;
} ct;

/* Load factor: grow when used > cap/2. */
#define HASH_LOAD_NUM 1
#define HASH_LOAD_DEN 2

static void hash_grow(size_t new_cap)
{
  size_t i;
  uint32 *old = ct.hash;
  size_t old_cap = ct.hash_cap;
  ct.hash = tmalloc(uint32, new_cap);
  for(i=0; i<new_cap; ++i) ct.hash[i] = CLUSTER_TABLE_NONE;
  ct.hash_cap = new_cap;
  ct.hash_used = 0;
  if(!old) return;
  for(i=0; i<old_cap; ++i) {
    uint32 idx = old[i];
    if(idx == CLUSTER_TABLE_NONE) continue;
    const uint32 *codes = ct.codes + ct.offsets[idx];
    unsigned n = ct.offsets[idx+1] - ct.offsets[idx];
    unsigned long h = codes_hash(codes, n);
    size_t mask = new_cap - 1;
    size_t pos = (size_t)h & mask;
    while(ct.hash[pos] != CLUSTER_TABLE_NONE) pos = (pos+1) & mask;
    ct.hash[pos] = idx;
    ++ct.hash_used;
  }
  free(old);
}

/* Returns the hash slot for this sequence — either a slot holding a matching
   entry index, or an empty slot where insertion would go. */
static size_t hash_probe(const uint32 *codes, unsigned n)
{
  unsigned long h = codes_hash(codes, n);
  size_t mask = ct.hash_cap - 1;
  size_t pos = (size_t)h & mask;
  while(ct.hash[pos] != CLUSTER_TABLE_NONE) {
    uint32 idx = ct.hash[pos];
    unsigned len = ct.offsets[idx+1] - ct.offsets[idx];
    if(len == n) {
      const uint32 *p = ct.codes + ct.offsets[idx];
      unsigned k = 0;
      while(k<n && p[k]==codes[k]) ++k;
      if(k==n) return pos; /* hit */
    }
    pos = (pos+1) & mask;
  }
  return pos; /* miss — empty slot */
}

void cluster_init(void)
{
  ct.codes = 0; ct.codes_n = 0; ct.codes_max = 0;
  ct.offsets = 0; ct.off_n = 0; ct.off_max = 0;
  ct.narrow = 0; ct.narrow_words = 0;
  ct.hash = 0; ct.hash_cap = 0; ct.hash_used = 0;
  hash_grow(64);

  /* Reserve initial buffers + sentinel offset (offsets[0] = 0). */
  ct.offsets = tmalloc(uint32, 16);
  ct.off_max = 16;
  ct.offsets[0] = 0;
  ct.off_n = 1;

  ct.codes = tmalloc(uint32, 64);
  ct.codes_max = 64;
  ct.codes_n = 0;

  ct.narrow = tcalloc(uint64, 1);
  ct.narrow_words = 1;
}

static void ensure_init(void)
{
  if(!ct.hash) cluster_init();
}

void cluster_done(void)
{
  free(ct.codes); ct.codes = 0;
  free(ct.offsets); ct.offsets = 0;
  free(ct.narrow); ct.narrow = 0;
  free(ct.hash); ct.hash = 0;
  ct.codes_n = ct.codes_max = 0;
  ct.off_n = ct.off_max = 0;
  ct.narrow_words = 0;
  ct.hash_cap = ct.hash_used = 0;
}

unsigned cluster_intern(const uint32 *codes, unsigned n, unsigned width)
{
  size_t pos;
  ensure_init();
  pos = hash_probe(codes, n);
  if(ct.hash[pos] != CLUSTER_TABLE_NONE) return ct.hash[pos];

  /* Insert new entry. */
  uint32 idx = (uint32)(ct.off_n - 1); /* entries: 0..off_n-2, sentinel at off_n-1 */

  /* Grow codes buffer if needed. */
  if(ct.codes_n + n > ct.codes_max) {
    size_t new_max = ct.codes_max;
    while(new_max < ct.codes_n + n) new_max = new_max + new_max/2 + 1;
    ct.codes = trealloc(uint32, ct.codes, new_max);
    ct.codes_max = new_max;
  }
  memcpy(ct.codes + ct.codes_n, codes, n * sizeof(uint32));
  ct.codes_n += n;

  /* Append a new offset slot (sentinel slides forward). */
  if(ct.off_n + 1 > ct.off_max) {
    size_t new_max = ct.off_max + ct.off_max/2 + 1;
    ct.offsets = trealloc(uint32, ct.offsets, new_max);
    ct.off_max = new_max;
  }
  ct.offsets[ct.off_n] = (uint32)ct.codes_n;
  ++ct.off_n;

  /* Grow narrow bitmap if the new bit doesn't fit. */
  if((size_t)idx / 64 >= ct.narrow_words) {
    size_t new_words = ct.narrow_words * 2; if(!new_words) new_words = 1;
    ct.narrow = trealloc(uint64, ct.narrow, new_words);
    memset(ct.narrow + ct.narrow_words, 0,
           (new_words - ct.narrow_words) * sizeof(uint64));
    ct.narrow_words = new_words;
  }
  if(width == 1) ct.narrow[idx/64] |= (uint64)1 << (idx % 64);
  else           ct.narrow[idx/64] &= ~((uint64)1 << (idx % 64));

  /* Slot the new entry. Grow hash first if needed. */
  if(ct.hash_used * HASH_LOAD_DEN >= ct.hash_cap * HASH_LOAD_NUM) {
    hash_grow(ct.hash_cap * 2);
    pos = hash_probe(codes, n); /* re-probe; load is now low */
  }
  ct.hash[pos] = idx;
  ++ct.hash_used;

  return idx;
}

const uint32 *cluster_get(unsigned index, unsigned *n)
{
  *n = ct.offsets[index+1] - ct.offsets[index];
  return ct.codes + ct.offsets[index];
}

unsigned cluster_get_width(unsigned index)
{
  return (ct.narrow[index/64] >> (index % 64)) & 1u ? 1u : 2u;
}
