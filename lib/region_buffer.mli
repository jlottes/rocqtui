(** RegionBuffer: text mutation gateway that enforces region invariants.

    All text-mutating editor paths must go through this module. Holds a
    [Buffer.t] and a (read-only) reference to a [Session.t option] for
    boundary queries. Edits that would violate the invariants in
    [docs/REGION_INVARIANTS.md] are rejected.

    Invariants enforced:
    - No edit may alter the verified region (bytes [0, verified_end)).
    - No edit may erase the sentence boundary at verified_end (the byte
      at verified_end must remain whitespace or EOF post-edit).
    - No edit may overlap the pending region [verified_end, target_end). *)

type t

type reject_reason =
  | In_verified_region   (** edit overlaps [0, verified_end) *)
  | Erodes_boundary      (** edit would un-terminate the boundary *)
  | In_pending_region    (** edit overlaps [verified_end, target_end) *)

type result = Applied | Rejected of reject_reason

val create : Buffer.t -> session:Session.t option -> t

(** Read-only access to the underlying buffer. *)
val buffer : t -> Buffer.t

(** {1 Lock}

    The lock is a coarse "is this buffer being driven by an external
    client right now" flag. It is not consulted by the [try_*] functions
    below — those enforce region invariants only. Callers that should
    yield to a held lock (the editor's keystroke path; third-party MCP
    clients) consult [locked] explicitly before calling a [try_*]. *)

val lock : t -> unit
val unlock : t -> unit
val locked : t -> bool

(** {1 Cursor-relative atomic edits} *)

val try_insert_char : t -> char -> result
val try_insert_newline : t -> result
val try_insert_newline_auto_indent : t -> result

(** Forward delete: deletes selection if non-empty, else one codepoint
    at the cursor. *)
val try_delete_forward : t -> result

(** Backward delete (backspace): deletes selection if non-empty, else
    one codepoint before the cursor. *)
val try_delete_backward : t -> result

(** Atomic delete-selection-then-paste from the cut buffer. The
    invariant check covers the combined edit. If the cut buffer is
    empty, [Applied] is returned without mutation. *)
val try_paste : t -> result

val try_cut_line : t -> result

(** Enter-key behavior: delete selection (if any) and insert a newline
    with auto-indent, atomically. *)
val try_enter : t -> result
val try_indent_lines : t -> int -> result
val try_unindent_lines : t -> int -> result

(** Replace the current selection (or insert at cursor if no selection)
    atomically with [text]. This is the canonical "type while
    selection exists" operation; using it ensures invariants are
    checked against the final state, not the intermediate
    delete-then-insert. *)
val try_replace_selection : t -> string -> result

(** {1 Explicit-range edits (for MCP)} *)

(** Replace bytes [\[start, old_end)] with [text]. *)
val try_replace : t -> start:int -> old_end:int -> string -> result

(** {1 Wholesale text replacement} *)

(** Replace the entire buffer text with [text]. If [text] agrees with
    the current text on [\[0, verified_end)] and the boundary byte is
    preserved, the session is left intact. Otherwise rejected. *)
val try_load_text : t -> string -> result

(** Reload from the buffer's filename on disk. Equivalent to
    [try_load_text] with the file's contents. Returns [Rejected] if
    the file's contents would violate invariants; the file
    descriptor / on-disk file is untouched on rejection. *)
val try_reload_from_disk : t -> result

(** {1 Undo/redo} *)

val try_undo : t -> result
val try_redo : t -> result

(** {1 Recent edits ring}

    Bounded log of recently-applied edits, captured automatically by
    every [try_*] that returns [Applied]. Generic infrastructure —
    not tied to any one consumer. *)

type edit_record = { before : string; after : string; at : float }

(** The N most-recently-applied edits, most-recent LAST. Capped at
    [ring_size]. *)
val recent_edits : t -> edit_record list

(** Capacity of the recent-edits ring. *)
val ring_size : int
