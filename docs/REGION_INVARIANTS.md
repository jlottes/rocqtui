# Region invariants

The editor tracks three kinds of text regions that interact with Rocq:
the **verified region**, the **error region**, and the **target**. Each
has a different relationship to user edits, and confusing them produces
subtle bugs (drifting highlights, lying status, fused sentence
boundaries, etc.). This doc states the invariants we want to hold.

## Verified region

The verified region is a *commitment from Rocq*: every sentence inside
it has been accepted by the kernel.

1. **No edit may alter the verified region.** Edits inside it must be
   rejected (or first push the boundary back by rewinding).
2. **No edit may erase the sentence boundary at the end of the verified
   region.** In particular, an edit immediately past the boundary that
   would silently fuse the terminating "." into a qualified-id
   separator (extending the sentence past the boundary) counts as
   altering the verified region and must be treated the same way.

The boundary is part of the commitment. Letting it float — even by one
character, even when the bytes inside are unchanged — would make
"verified" a lie.

## Error region

The error region is a *commitment from Rocq* about which span was
rejected and why.

1. **If the text inside the error region changes, the error region is
   cleared.** The boundary must never move, and the text inside must
   never change while the region is still displayed. Once the
   underlying text shifts, the commitment no longer refers to anything
   real, so the honest move is to clear it rather than let the
   highlight drift onto unrelated characters or silently re-anchor.

## Target

The target is different in kind from the other two: it is *user
intent* ("step to here"), not a commitment about Rocq state. So its
invariant is weaker.

1. **The target tracks edits as a stable anchor.** Insertions and
   deletions before it shift it along with the text; edits after it
   leave it alone. Unlike the verified and error regions, the target
   is allowed to move with the text, because what the user pointed at
   hasn't changed identity just because the file got longer above.
2. **If the text the target anchors to is destroyed, the target is
   cleared.** Same reasoning as the error region: the commitment
   ("step to *here*") no longer refers to anything real, so silently
   re-snapping the target to a nearby character would misrepresent the
   user's intent.

"Destroyed" needs a definition. We lean **strict**: any edit that
touches the target's anchor character clears the target. The looser
rule — "only deletion that removes the anchor character clears it" —
is defensible, but if the user retypes the line the target was on,
their old intent probably doesn't apply to the new text. Revisit if
the strict rule turns out to be annoying in practice.
