(** tterm's split layout: a tree of leaves, each owning a
    [Msg_pane.t] instance.

    A leaf is a "panel" with a tab strip at top and a body below.
    A split wraps two children either horizontally ({!HSplit}) or
    vertically ({!VSplit}), with a draggable border. Rocqtui does
    not use this module — only [bin/tterm.ml] does. *)

type leaf = {
  id : int;
  mp : Msg_pane.t;
  mutable rect : Render.rect;
  (** The leaf's full rectangle (including its tab strip). Set by
      {!compute_rects} each frame. *)
}

type split = {
  mutable a : t;
  mutable b : t;
  mutable frac : float;
  (** Position of the divider as a fraction of the split's extent,
      clamped to keep both children at minimum size. *)
  mutable rect : Render.rect;
  (** Rect containing both children plus the divider. Set by
      {!compute_rects}. *)
}

and t =
  | Leaf of leaf
  | VSplit of split  (** Children laid out left | right, divider is a column. *)
  | HSplit of split  (** Children laid out top / bottom, divider is a row. *)

(** Fresh leaf with a new empty [Msg_pane.t] and a stable id. *)
val new_leaf : unit -> leaf

(** The rect of any node — for a leaf, its own [rect]; for a split,
    the rect spanning both children + the divider. *)
val rect_of : t -> Render.rect

(** All leaves of the tree, in document order (left-to-right,
    top-to-bottom). *)
val leaves : t -> leaf list

(** Iterate over the leaves in document order. *)
val iter_leaves : t -> (leaf -> unit) -> unit

(** Find the leaf whose [rect] contains [(x, y)]. Returns [None] for
    a coordinate landing on a split divider. *)
val find_leaf_at : t -> x:int -> y:int -> leaf option

(** Find the split whose divider passes through [(x, y)]. Returns
    [`VBorder] for a vertical divider (a column between two
    side-by-side children, drag changes width allocation), [`HBorder]
    for a horizontal divider. *)
val find_split_border_at : t -> x:int -> y:int ->
  [ `VBorder of split | `HBorder of split ] option

(** Find a leaf by its stable id. *)
val find_leaf_by_id : t -> int -> leaf option

(** Walk the tree and write each node's [rect]. The root is laid
    out into [bounds]; splits recursively partition their child
    rects. The horizontal divider takes one row; the vertical one
    takes one column.

    Each leaf's rect is clamped to a minimum size; [frac] is
    silently re-clamped so neither side goes below it.
    Minimum: 8 columns, 3 rows per leaf. *)
val compute_rects : t -> bounds:Render.rect -> unit

(** The body of a leaf — the area below its 1-row tab strip. *)
val leaf_body_rect : leaf -> Render.rect

(** Replace the subtree [target] with [with_] in [root]. Comparison
    is by physical equality on the node. Returns the new root (which
    will be [with_] if [target == root]). *)
val replace : t -> target:t -> with_:t -> t

(** Drop [leaf] from the tree. If its parent split has [leaf] as one
    of its children, the split is replaced by the sibling subtree.
    If [leaf] is the only node, returns [None]. *)
val collapse_leaf : t -> leaf -> t option

(** Replace the [Leaf existing] node in [root] with a fresh split
    whose [a] is [Leaf existing] and [b] is [Leaf inserted]. [frac]
    is initialized to 0.5. Returns the new root.

    If [existing] is not in the tree, returns [root] unchanged. *)
val split_leaf : t -> existing:leaf -> inserted:leaf ->
  dir:[ `V | `H ] -> t

(** Construct a new split node wrapping [a] and [b]. *)
val make_vsplit : t -> t -> split
val make_hsplit : t -> t -> split
