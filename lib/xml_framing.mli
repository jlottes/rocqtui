(** Incremental top-level-element boundary detector for the coqidetop XML
    stream — see xml_framing.ml for the lexical model.

    Purely a performance gate for [Rocq_protocol]: it lets the protocol
    layer avoid re-lexing an in-progress message on every pipe drain.
    [Xml_parser] stays authoritative on actual message boundaries, so a
    false positive only costs a wasted parse attempt; the contract is
    that there are no false negatives for well-formed coqidetop output. *)

type t

(** Fresh scanner: depth 0, no boundary seen. *)
val initial : t

(** Feed the next chunk of stream bytes. O(chunk length). Feed only bytes
    not previously fed — the scanner is stateful across calls. *)
val feed : t -> string -> t

(** True once at least one top-level element has fully closed (nesting
    depth returned to 0) in the bytes fed so far — i.e. a complete
    protocol message is available to parse. *)
val at_boundary : t -> bool

(** Current element-nesting depth (0 = between top-level elements). *)
val depth : t -> int
