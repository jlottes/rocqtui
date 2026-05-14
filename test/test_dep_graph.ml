open Rocqtui_lib

let check name cond =
  if cond then Printf.printf "OK: %s\n" name
  else (Printf.printf "FAIL: %s\n" name; exit 1)

let set_eq xs ys =
  let s = List.sort compare in
  s xs = s ys

let test_empty () =
  let g = Dep_graph.empty () in
  check "empty graph: no nodes" (Dep_graph.nodes g = []);
  check "empty graph: toposort = []" (Dep_graph.toposort g = []);
  check "empty graph: descendants of missing"
    (Dep_graph.descendants g "x.v" = []);
  check "empty graph: closure of missing"
    (Dep_graph.closure_bidirectional g "x.v" = [])

let test_linear_chain () =
  let g = Dep_graph.empty () in
  Dep_graph.add_edge g ~dep:"a.v" ~dependent:"b.v";
  Dep_graph.add_edge g ~dep:"b.v" ~dependent:"c.v";
  check "linear: toposort"
    (Dep_graph.toposort g = ["a.v"; "b.v"; "c.v"]);
  check "linear: ancestors(c)"
    (set_eq (Dep_graph.ancestors g "c.v") ["a.v"; "b.v"]);
  check "linear: ancestors(a) empty"
    (Dep_graph.ancestors g "a.v" = []);
  check "linear: descendants(a)"
    (set_eq (Dep_graph.descendants g "a.v") ["b.v"; "c.v"]);
  check "linear: descendants(c) empty"
    (Dep_graph.descendants g "c.v" = []);
  check "linear: closure(b) covers all"
    (set_eq (Dep_graph.closure_bidirectional g "b.v")
       ["a.v"; "b.v"; "c.v"])

let test_diamond () =
  let g = Dep_graph.empty () in
  Dep_graph.add_edge g ~dep:"a.v" ~dependent:"b.v";
  Dep_graph.add_edge g ~dep:"a.v" ~dependent:"c.v";
  Dep_graph.add_edge g ~dep:"b.v" ~dependent:"d.v";
  Dep_graph.add_edge g ~dep:"c.v" ~dependent:"d.v";
  let topo = Dep_graph.toposort g in
  let pos x =
    let rec loop i = function
      | [] -> -1
      | y :: _ when y = x -> i
      | _ :: rest -> loop (i + 1) rest
    in
    loop 0 topo
  in
  check "diamond: a before b" (pos "a.v" < pos "b.v");
  check "diamond: a before c" (pos "a.v" < pos "c.v");
  check "diamond: b before d" (pos "b.v" < pos "d.v");
  check "diamond: c before d" (pos "c.v" < pos "d.v");
  check "diamond: ancestors(d)"
    (set_eq (Dep_graph.ancestors g "d.v") ["a.v"; "b.v"; "c.v"]);
  check "diamond: descendants(a)"
    (set_eq (Dep_graph.descendants g "a.v") ["b.v"; "c.v"; "d.v"]);
  check "diamond: closure(b)"
    (set_eq (Dep_graph.closure_bidirectional g "b.v")
       ["a.v"; "b.v"; "d.v"])  (* not c — c is sibling, not ancestor *)

let test_isolated_node () =
  let g = Dep_graph.empty () in
  Dep_graph.add_edge g ~dep:"a.v" ~dependent:"b.v";
  (* Add an isolated node by mentioning it as a target with no deps —
     not via add_edge, so we expose [of_rocq_dep_output] instead *)
  let g2 = Dep_graph.of_rocq_dep_output "x.vo: x.v\n" in
  check "isolated: x present" (Dep_graph.has g2 "x.v");
  check "isolated: toposort includes x"
    (List.mem "x.v" (Dep_graph.toposort g2));
  check "isolated: ancestors(x) empty"
    (Dep_graph.ancestors g2 "x.v" = []);
  check "isolated: descendants(x) empty"
    (Dep_graph.descendants g2 "x.v" = []);
  check "isolated: closure(x) singleton"
    (Dep_graph.closure_bidirectional g2 "x.v" = ["x.v"]);
  ignore g

let test_cycle_tolerance () =
  (* a -> b -> a creates a cycle. toposort should emit both somehow,
     not loop forever, not drop nodes. *)
  let g = Dep_graph.empty () in
  Dep_graph.add_edge g ~dep:"a.v" ~dependent:"b.v";
  Dep_graph.add_edge g ~dep:"b.v" ~dependent:"a.v";
  let topo = Dep_graph.toposort g in
  check "cycle: toposort terminates and covers all nodes"
    (set_eq topo ["a.v"; "b.v"]);
  check "cycle: closure(a) covers both"
    (set_eq (Dep_graph.closure_bidirectional g "a.v") ["a.v"; "b.v"])

let test_parse_real_rocq_dep_output () =
  (* Shape that `rocq dep -f _RocqProject` actually emits. *)
  let text =
    "theory/groups.vo theory/groups.glob theory/groups.v.beautified \
     theory/groups.required_vo: theory/groups.v interfaces/eq.vo \
     orders/preorder.vo\n\
     interfaces/eq.vo interfaces/eq.glob: interfaces/eq.v\n\
     orders/preorder.vo orders/preorder.glob: orders/preorder.v \
     interfaces/eq.vo\n"
  in
  let g = Dep_graph.of_rocq_dep_output text in
  check "parse: nodes include groups"
    (Dep_graph.has g "theory/groups.v");
  check "parse: nodes include eq"
    (Dep_graph.has g "interfaces/eq.v");
  check "parse: nodes include preorder"
    (Dep_graph.has g "orders/preorder.v");
  check "parse: eq has no deps"
    (Dep_graph.ancestors g "interfaces/eq.v" = []);
  check "parse: groups depends on eq and preorder"
    (set_eq (Dep_graph.ancestors g "theory/groups.v")
       ["interfaces/eq.v"; "orders/preorder.v"]);
  check "parse: descendants(eq)"
    (set_eq (Dep_graph.descendants g "interfaces/eq.v")
       ["orders/preorder.v"; "theory/groups.v"]);
  let topo = Dep_graph.toposort g in
  let pos x =
    let rec loop i = function
      | [] -> -1
      | y :: _ when y = x -> i
      | _ :: rest -> loop (i + 1) rest
    in
    loop 0 topo
  in
  check "parse: eq before preorder"
    (pos "interfaces/eq.v" < pos "orders/preorder.v");
  check "parse: preorder before groups"
    (pos "orders/preorder.v" < pos "theory/groups.v")

let test_dedup_edges () =
  (* Same edge twice — should appear in ancestors only once. *)
  let g = Dep_graph.empty () in
  Dep_graph.add_edge g ~dep:"a.v" ~dependent:"b.v";
  Dep_graph.add_edge g ~dep:"a.v" ~dependent:"b.v";
  check "dedup: ancestors(b) = [a]"
    (Dep_graph.ancestors g "b.v" = ["a.v"])

let test_self_loop_ignored () =
  let g = Dep_graph.empty () in
  Dep_graph.add_edge g ~dep:"a.v" ~dependent:"a.v";
  check "self-loop: ancestors(a) empty"
    (Dep_graph.ancestors g "a.v" = []);
  check "self-loop: descendants(a) empty"
    (Dep_graph.descendants g "a.v" = [])

let () =
  test_empty ();
  test_linear_chain ();
  test_diamond ();
  test_isolated_node ();
  test_cycle_tolerance ();
  test_parse_real_rocq_dep_output ();
  test_dedup_edges ();
  test_self_loop_ignored ()
