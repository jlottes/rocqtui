(* Per-tab AI state. *)

type ghost = {
  text : string;          (* the suggested completion *)
  origin_line : int;      (* cursor line when the request was issued *)
  origin_col : int;       (* cursor col when the request was issued *)
  origin_revision : int;  (* buffer revision when issued — stale check *)
}

(* A single predicted edit, returned by edit-shape bridge responses.
   Coordinates are 0-indexed half-open: replace bytes
   [start_line:start_col, end_line:end_col) with [replacement]. *)
type edit_change = {
  start_line : int;
  start_col : int;
  end_line : int;
  end_col : int;
  replacement : string;
}

(* Predicted-edits overlay: changes accumulated as the bridge streams
   them back, plus the buffer revision at request time so we can
   detect staleness after the user edits in between. *)
type edits_overlay = {
  mutable changes : edit_change list;
  origin_revision : int;
}

type t = {
  mutable ghost : ghost option;
  mutable edits : edits_overlay option;
}

let create () = { ghost = None; edits = None }

let clear_ghost t = t.ghost <- None
let clear_edits t = t.edits <- None
let clear t = clear_ghost t; clear_edits t
