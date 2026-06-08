#ifndef CLUSTER_H
#define CLUSTER_H

#if !defined(C99_H)
#warning "cluster.h" requires "c99.h"
#endif

/*----------------------------------------------------------------------------
  Cluster table

  Process-lifetime, append-only, dedup'd table of codepoint sequences for
  cells whose codepoint field has CLUSTER_BIT set. The index stored in
  the cell's codepoint field (low bits, masked by CLUSTER_INDEX_MASK)
  indexes this table.

  Layout follows the CSR convention used elsewhere in the codebase:
   - codepoints: flat buffer of all entry sequences concatenated
   - offsets:    offsets[i] = start of entry i in codepoints
                 length of entry i = offsets[i+1] - offsets[i]
                 length is implicit; offsets has n_entries+1 elements
   - narrow:     bitmap, one bit per entry; clear = width 2 (common),
                 set = width 1 (rare VS-15 forced text presentation)
   - hash:       open-addressed dedup table of entry indices,
                 power-of-2 sized, NONE = empty slot

  Lookup hashes the input codepoint sequence and probes hash; on hit,
  compares the codepoints. If absent, the sequence is appended and the
  new index returned.

  Never shrinks. Lifetime is the process. Shared across all term
  instances in the process — emoji clusters are dedup'd globally.

  See doc/cluster-cell-plan.md for the design rationale. */

#define CLUSTER_TABLE_NONE 0xffffffffu

/*----------------------------------------------------------------------------
  Parser state

  Lives in struct term as a uchar; survives across term_proc calls. "IDLE
  with promotable top cell" and "no promotable top cell" are distinct
  states (LEADER vs DEAD) — the parser can't otherwise tell whether the
  most-recently-emitted cell is a normal base that may absorb a trigger,
  or a zero-width follower / freshly-cleared region. */
enum cluster_state {
  CPS_DEAD = 0,            /* no cluster open; top is NOT promotable        */
  CPS_LEADER,              /* top is a normal leader, promotable on trigger  */
  CPS_AWAIT_SECOND_RI,     /* top is an RI; a second RI completes the flag   */
  CPS_AWAIT_PICTOGRAPHIC,  /* top is a cluster ending in ZWJ                 */
  CPS_IN_CLUSTER           /* top is a cluster, may accept further triggers  */
};

/* Maximum codepoints in a single cluster. Real-world clusters stay well
   below this (family ZWJ sequences with skin tones ~10). On overflow the
   parser closes the cluster rather than corrupting state. */
#define CLUSTER_MAX_LEN 16

/*----------------------------------------------------------------------------
  Codepoint classifiers (pure range tests). */
static inline int cluster_is_trigger_extend(uint32 c)
{
  return c == 0x200Du   /* ZERO WIDTH JOINER */
      || c == 0xFE0Eu   /* VARIATION SELECTOR-15 (text presentation) */
      || c == 0xFE0Fu   /* VARIATION SELECTOR-16 (emoji presentation) */
      || c == 0x20E3u   /* COMBINING ENCLOSING KEYCAP */
      || (c >= 0x1F3FBu && c <= 0x1F3FFu)   /* skin tone modifiers */
      || (c >= 0xE0020u && c <= 0xE007Fu);  /* tag characters */
}
static inline int cluster_is_ri(uint32 c)
{
  return c >= 0x1F1E6u && c <= 0x1F1FFu;
}
/* Approximate Extended_Pictographic with the main emoji blocks and the
   older symbol block. Good enough for v1; refine if a real producer
   surprises us. */
static inline int cluster_is_pictographic(uint32 c)
{
  return (c >= 0x1F300u && c <= 0x1FAFFu)
      || (c >= 0x2600u  && c <= 0x27BFu);
}

void cluster_init(void);
void cluster_done(void);

/* Find or insert a codepoint sequence; returns the entry index (0..2^30-1).
   `width` is 1 or 2. The sequence must not be empty. */
unsigned cluster_intern(const uint32 *codes, unsigned n, unsigned width);

/* Read back an entry's codepoint sequence. Returns the codepoint pointer
   and writes the length through `n`. Pointer is invalidated by any
   subsequent cluster_intern() that grows the codepoints buffer. */
const uint32 *cluster_get(unsigned index, unsigned *n);

/* Read back an entry's width (1 or 2). */
unsigned cluster_get_width(unsigned index);

#endif
