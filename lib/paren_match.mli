(** Matching paren / bracket / brace finder.

    Scans text the same way [Sentence] does — skipping over Rocq strings
    and (nested) comments — so brackets inside ["foo"] or [(* ... *)] are
    ignored. Recognized bracket pairs: [()], [[]], [{}].

    Rocq uses bare [{] and [}] as proof-focusing bullets when surrounded
    by whitespace. Those are intentionally skipped: only bracket-style
    uses (immediately adjacent to non-whitespace) participate in
    matching. *)

(** Find the byte offset of the bracket that matches the one at byte
    offset [pos]. Returns [None] if [pos] isn't on a bracket, the
    bracket is inside a string/comment, the bracket is a proof-focus
    brace, or no match is found. *)
val find_match : string -> int -> int option

(** Given a cursor at [cursor] (byte offset), pick the bracket the
    cursor is "on": the bracket immediately under the cursor first,
    else the bracket immediately to the left of the cursor. Returns
    the two byte offsets to highlight, or [None] if there is no
    matched pair. *)
val pair_at_cursor : string -> cursor:int -> (int * int) option
