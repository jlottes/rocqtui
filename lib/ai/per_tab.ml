(* Per-tab AI state. Phase 1: ghost-text suggestion only. *)

type ghost = {
  text : string;          (* the suggested completion *)
  origin_line : int;      (* cursor line when the request was issued *)
  origin_col : int;       (* cursor col when the request was issued *)
  origin_revision : int;  (* buffer revision when issued — stale check *)
}

type t = {
  mutable ghost : ghost option;
}

let create () = { ghost = None }
let clear t = t.ghost <- None
