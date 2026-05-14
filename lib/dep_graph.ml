(* Static dependency graph over the .v files of a Rocq project.
   Pure: no I/O, no subprocess. Caller parses `rocq dep` output and
   hands it to [of_rocq_dep_output]; queries return file paths in
   project-relative form (".v", not ".vo"). *)

type t = {
  (* Insertion order, reversed — used to make [toposort] deterministic
     when multiple in-degree-zero nodes are available. *)
  mutable order : string list;
  nodes : (string, unit) Hashtbl.t;
  (* dep -> [dependents]: traversed forward to find descendants. *)
  forward : (string, string list) Hashtbl.t;
  (* dependent -> [deps]: traversed forward to find ancestors. *)
  reverse : (string, string list) Hashtbl.t;
}

let empty () = {
  order = [];
  nodes = Hashtbl.create 64;
  forward = Hashtbl.create 64;
  reverse = Hashtbl.create 64;
}

let add_node t path =
  if not (Hashtbl.mem t.nodes path) then begin
    Hashtbl.add t.nodes path ();
    t.order <- path :: t.order
  end

let neighbours tbl k = try Hashtbl.find tbl k with Not_found -> []

let add_edge t ~dep ~dependent =
  if dep <> dependent then begin
    add_node t dep;
    add_node t dependent;
    let fwd = neighbours t.forward dep in
    if not (List.mem dependent fwd) then
      Hashtbl.replace t.forward dep (dependent :: fwd);
    let rev = neighbours t.reverse dependent in
    if not (List.mem dep rev) then
      Hashtbl.replace t.reverse dependent (dep :: rev)
  end

(* "foo/bar.vo" -> "foo/bar.v"; pass through anything else unchanged. *)
let vo_to_v s =
  if Filename.check_suffix s ".vo" then
    Filename.chop_suffix s ".vo" ^ ".v"
  else s

(* Parse one Makefile-style rule line of the form:
       target1.vo target2.glob ...: source.v dep1.vo dep2.vo ...
   Returns Some (target.v, [dep1.v; dep2.v]) or None for lines that
   don't carry a .vo target. *)
let parse_line line =
  match String.index_opt line ':' with
  | None -> None
  | Some i ->
    let lhs = String.sub line 0 i in
    let rhs = String.sub line (i + 1) (String.length line - i - 1) in
    let split s =
      String.split_on_char ' ' s
      |> List.filter (fun t -> t <> "" && t <> "\\")
    in
    let lhs_toks = split lhs in
    let rhs_toks = split rhs in
    let tgt_vo =
      List.find_opt (fun s -> Filename.check_suffix s ".vo") lhs_toks
    in
    match tgt_vo with
    | None -> None
    | Some tgt_vo ->
      let dep_vs =
        List.filter_map (fun s ->
          if Filename.check_suffix s ".vo" && s <> tgt_vo
          then Some (vo_to_v s) else None
        ) rhs_toks
      in
      Some (vo_to_v tgt_vo, dep_vs)

let of_rocq_dep_output text =
  let t = empty () in
  String.split_on_char '\n' text
  |> List.iter (fun line ->
    match parse_line line with
    | None -> ()
    | Some (tgt, deps) ->
      add_node t tgt;
      List.iter (fun dep -> add_edge t ~dep ~dependent:tgt) deps);
  t

let nodes t = List.rev t.order

(* --- Queries --- *)

let has t path = Hashtbl.mem t.nodes path

(* Kahn's algorithm with deterministic tie-breaking by insertion order.
   Tolerates cycles: appends any unsortable remainder at the end so
   the output always covers every node. *)
let toposort t =
  let in_deg = Hashtbl.create 64 in
  Hashtbl.iter (fun n () -> Hashtbl.add in_deg n 0) t.nodes;
  Hashtbl.iter (fun _ deps ->
    List.iter (fun n ->
      let d = try Hashtbl.find in_deg n with Not_found -> 0 in
      Hashtbl.replace in_deg n (d + 1)
    ) deps
  ) t.forward;
  let result = ref [] in
  let visited = Hashtbl.create 64 in
  let order = List.rev t.order in  (* insertion order *)
  let rec drain () =
    let pickable =
      List.filter (fun n ->
        not (Hashtbl.mem visited n)
        && (try Hashtbl.find in_deg n = 0 with Not_found -> false)
      ) order
    in
    match pickable with
    | [] -> ()
    | _ ->
      List.iter (fun n ->
        Hashtbl.add visited n ();
        result := n :: !result;
        List.iter (fun m ->
          let d = try Hashtbl.find in_deg m with Not_found -> 0 in
          Hashtbl.replace in_deg m (d - 1)
        ) (neighbours t.forward n)
      ) pickable;
      drain ()
  in
  drain ();
  (* Append any unsorted remainder (cycle nodes) in insertion order. *)
  let leftovers =
    List.filter (fun n -> not (Hashtbl.mem visited n)) order
  in
  List.rev_append !result leftovers

(* Generic BFS following [step]; returns the reachable set excluding
   the start node itself. *)
let reachable t step start =
  if not (has t start) then []
  else begin
    let seen = Hashtbl.create 16 in
    Hashtbl.add seen start ();
    let queue = Queue.create () in
    Queue.push start queue;
    let result = ref [] in
    while not (Queue.is_empty queue) do
      let n = Queue.pop queue in
      List.iter (fun m ->
        if not (Hashtbl.mem seen m) then begin
          Hashtbl.add seen m ();
          result := m :: !result;
          Queue.push m queue
        end
      ) (step n)
    done;
    !result
  end

let descendants t start = reachable t (neighbours t.forward) start
let ancestors   t start = reachable t (neighbours t.reverse) start

let closure_bidirectional t start =
  if not (has t start) then []
  else
    (* Dedup: ancestors and descendants can overlap when the graph has
       a cycle through [start]. *)
    let seen = Hashtbl.create 16 in
    let push acc n =
      if Hashtbl.mem seen n then acc
      else (Hashtbl.add seen n (); n :: acc)
    in
    let acc = push [] start in
    let acc = List.fold_left push acc (ancestors t start) in
    let acc = List.fold_left push acc (descendants t start) in
    List.rev acc
