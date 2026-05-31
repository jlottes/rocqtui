type leaf = {
  id : int;
  mp : Msg_pane.t;
  mutable rect : Render.rect;
}

type split = {
  mutable a : t;
  mutable b : t;
  mutable frac : float;
  mutable rect : Render.rect;
}

and t =
  | Leaf of leaf
  | VSplit of split
  | HSplit of split

let empty_rect : Render.rect = { row = 0; col = 0; height = 0; width = 0 }

let next_id = ref 0
let alloc_id () =
  let id = !next_id in
  incr next_id;
  id

let new_leaf () = {
  id = alloc_id ();
  mp = Msg_pane.create ();
  rect = empty_rect;
}

let make_vsplit a b =
  { a; b; frac = 0.5; rect = empty_rect }

let make_hsplit a b =
  { a; b; frac = 0.5; rect = empty_rect }

let rect_of = function
  | Leaf l -> l.rect
  | VSplit s | HSplit s -> s.rect

let set_rect_of t rect =
  match t with
  | Leaf l -> l.rect <- rect
  | VSplit s | HSplit s -> s.rect <- rect

let rec leaves = function
  | Leaf l -> [l]
  | VSplit s | HSplit s -> leaves s.a @ leaves s.b

let iter_leaves t f = List.iter f (leaves t)

(* Rect-contains check (right/bottom exclusive). *)
let contains (r : Render.rect) ~x ~y =
  x >= r.col && x < r.col + r.width &&
  y >= r.row && y < r.row + r.height

let rec find_leaf_at t ~x ~y =
  match t with
  | Leaf l ->
    if contains l.rect ~x ~y then Some l else None
  | VSplit s | HSplit s ->
    (match find_leaf_at s.a ~x ~y with
     | Some _ as r -> r
     | None -> find_leaf_at s.b ~x ~y)

let rec find_split_border_at t ~x ~y =
  match t with
  | Leaf _ -> None
  | VSplit s ->
    let a_rect = rect_of s.a in
    let divider_col = a_rect.col + a_rect.width in
    if x = divider_col &&
       y >= s.rect.row && y < s.rect.row + s.rect.height
    then Some (`VBorder s)
    else begin
      match find_split_border_at s.a ~x ~y with
      | Some _ as r -> r
      | None -> find_split_border_at s.b ~x ~y
    end
  | HSplit s ->
    let a_rect = rect_of s.a in
    let divider_row = a_rect.row + a_rect.height in
    if y = divider_row &&
       x >= s.rect.col && x < s.rect.col + s.rect.width
    then Some (`HBorder s)
    else begin
      match find_split_border_at s.a ~x ~y with
      | Some _ as r -> r
      | None -> find_split_border_at s.b ~x ~y
    end

let rec find_leaf_by_id t id =
  match t with
  | Leaf l -> if l.id = id then Some l else None
  | VSplit s | HSplit s ->
    (match find_leaf_by_id s.a id with
     | Some _ as r -> r
     | None -> find_leaf_by_id s.b id)

(* Per-leaf minimums. A leaf needs room for at least its tab strip
   and one row of body. *)
let min_w = 8
let min_h = 3

let rec compute_rects t ~(bounds : Render.rect) =
  set_rect_of t bounds;
  match t with
  | Leaf _ -> ()
  | VSplit s ->
    (* Reserve one column for the divider. *)
    let usable = max 0 (bounds.width - 1) in
    let min_total = min_w + min_w in
    if usable < min_total then begin
      (* Underflow: give both children the same minimum sliver and
         pretend the divider sits in the middle. compute_rects will
         still descend, but the children won't render meaningfully. *)
      let half = usable / 2 in
      let a_rect = { bounds with width = max 0 half } in
      let b_col = bounds.col + half + 1 in
      let b_rect = { bounds with col = b_col;
                     width = max 0 (bounds.width - half - 1) } in
      compute_rects s.a ~bounds:a_rect;
      compute_rects s.b ~bounds:b_rect
    end
    else begin
      let raw_a = int_of_float (s.frac *. float_of_int usable) in
      let a_w = max min_w (min (usable - min_w) raw_a) in
      let b_w = usable - a_w in
      (* Re-clamp frac so later renders don't drift. *)
      s.frac <- float_of_int a_w /. float_of_int usable;
      let a_rect = { bounds with width = a_w } in
      let b_rect = { bounds with col = bounds.col + a_w + 1;
                     width = b_w } in
      compute_rects s.a ~bounds:a_rect;
      compute_rects s.b ~bounds:b_rect
    end
  | HSplit s ->
    let usable = max 0 (bounds.height - 1) in
    let min_total = min_h + min_h in
    if usable < min_total then begin
      let half = usable / 2 in
      let a_rect = { bounds with height = max 0 half } in
      let b_row = bounds.row + half + 1 in
      let b_rect = { bounds with row = b_row;
                     height = max 0 (bounds.height - half - 1) } in
      compute_rects s.a ~bounds:a_rect;
      compute_rects s.b ~bounds:b_rect
    end
    else begin
      let raw_a = int_of_float (s.frac *. float_of_int usable) in
      let a_h = max min_h (min (usable - min_h) raw_a) in
      let b_h = usable - a_h in
      s.frac <- float_of_int a_h /. float_of_int usable;
      let a_rect = { bounds with height = a_h } in
      let b_rect = { bounds with row = bounds.row + a_h + 1;
                     height = b_h } in
      compute_rects s.a ~bounds:a_rect;
      compute_rects s.b ~bounds:b_rect
    end

let leaf_body_rect (l : leaf) : Render.rect =
  (* Tab strip occupies row 0 of the leaf. *)
  { row = l.rect.row + 1;
    col = l.rect.col;
    height = max 0 (l.rect.height - 1);
    width = l.rect.width }

let rec replace t ~target ~with_ =
  if t == target then with_
  else match t with
  | Leaf _ -> t
  | VSplit s ->
    s.a <- replace s.a ~target ~with_;
    s.b <- replace s.b ~target ~with_;
    t
  | HSplit s ->
    s.a <- replace s.a ~target ~with_;
    s.b <- replace s.b ~target ~with_;
    t

let rec contains_leaf t (l : leaf) =
  match t with
  | Leaf l' -> l'.id = l.id
  | VSplit s | HSplit s -> contains_leaf s.a l || contains_leaf s.b l

let split_leaf root ~(existing : leaf) ~(inserted : leaf) ~dir =
  let new_split = (match dir with
    | `V -> VSplit (make_vsplit (Leaf existing) (Leaf inserted))
    | `H -> HSplit (make_hsplit (Leaf existing) (Leaf inserted)))
  in
  let rec walk t =
    match t with
    | Leaf l when l.id = existing.id -> new_split
    | Leaf _ -> t
    | VSplit s ->
      s.a <- walk s.a;
      s.b <- walk s.b;
      t
    | HSplit s ->
      s.a <- walk s.a;
      s.b <- walk s.b;
      t
  in
  walk root

let collapse_leaf root (l : leaf) =
  (* If the leaf IS the root, no sibling to replace with. *)
  match root with
  | Leaf l' when l'.id = l.id -> None
  | _ ->
    (* Walk to find the split whose [a] or [b] is [Leaf l], then
       replace that split with the sibling subtree. *)
    let rec rewrite t =
      match t with
      | Leaf _ -> t
      | VSplit s | HSplit s ->
        let a_is_target = (match s.a with
          | Leaf l' -> l'.id = l.id | _ -> false) in
        let b_is_target = (match s.b with
          | Leaf l' -> l'.id = l.id | _ -> false) in
        if a_is_target then s.b
        else if b_is_target then s.a
        else begin
          if contains_leaf s.a l then s.a <- rewrite s.a
          else if contains_leaf s.b l then s.b <- rewrite s.b;
          t
        end
    in
    Some (rewrite root)
