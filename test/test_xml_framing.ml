(* Unit tests for the incremental XML boundary scanner.
   Run: dune exec test/test_xml_framing.exe *)

open Rocqtui_lib

let failures = ref 0
let check name cond =
  if cond then Printf.printf "OK: %s\n" name
  else (incr failures; Printf.printf "FAIL: %s\n" name)

(* Feed a whole string from the initial state. *)
let scan s = Xml_framing.feed Xml_framing.initial s

(* Feed one byte at a time; return the list of [at_boundary] after each
   byte, so we can pinpoint where a boundary is first reported. *)
let scan_bytewise s =
  let st = ref Xml_framing.initial in
  List.init (String.length s) (fun i ->
    st := Xml_framing.feed !st (String.sub s i 1);
    Xml_framing.at_boundary !st)

let first_boundary s =
  let rec go i = function
    | [] -> None
    | b :: _ when b -> Some i
    | _ :: tl -> go (i + 1) tl
  in
  go 0 (scan_bytewise s)

let () =
  (* A simple complete top-level element: boundary at depth 0. *)
  let m1 = {|<value val="good"><state_id val="2"/></value>|} in
  check "complete element -> boundary" (Xml_framing.at_boundary (scan m1));
  check "complete element -> depth 0" (Xml_framing.depth (scan m1) = 0);

  (* No boundary until the element actually closes. *)
  let open_only = {|<value val="good"><state_id val="2"/>|} in
  check "open element -> no boundary" (not (Xml_framing.at_boundary (scan open_only)));
  check "open element -> depth 1" (Xml_framing.depth (scan open_only) = 1);

  (* Byte-at-a-time feeding agrees with whole-string feeding, and the
     boundary is first reported exactly at the final '>'. *)
  check "bytewise matches whole" (first_boundary m1 = Some (String.length m1 - 1));

  (* A prefix split mid-tag / mid-attribute never reports a boundary. *)
  List.iteri (fun i n ->
    let pre = String.sub m1 0 n in
    check (Printf.sprintf "prefix %d (len %d) no premature boundary" i n)
      (n >= String.length m1 || not (Xml_framing.at_boundary (scan pre))))
    [5; 12; 18; 30; String.length m1 - 1];

  (* Self-closing top-level element completes a message. *)
  check "self-closing top -> boundary" (Xml_framing.at_boundary (scan {|<value val="good"/>|}));
  check "self-closing top -> depth 0" (Xml_framing.depth (scan {|<value val="good"/>|}) = 0);

  (* Nested self-close does NOT complete the outer message. *)
  let nested_open = {|<a><b/>|} in
  check "nested self-close -> no boundary" (not (Xml_framing.at_boundary (scan nested_open)));
  check "nested self-close -> depth 1" (Xml_framing.depth (scan nested_open) = 1);
  check "nested closed -> boundary" (Xml_framing.at_boundary (scan {|<a><b/><c><d/></c></a>|}));

  (* '>' inside a quoted attribute value must not be mistaken for a tag
     close. *)
  check "'>' in attr value, self-close -> boundary"
    (Xml_framing.at_boundary (scan {|<x a=">"/>|}));
  check "'>' in attr value -> depth 0" (Xml_framing.depth (scan {|<x a=">"/>|}) = 0);
  check "'>' in attr value, open tag -> depth 1, no boundary"
    (let st = scan {|<x a=">">|} in
     Xml_framing.depth st = 1 && not (Xml_framing.at_boundary st));

  (* A backslash-escaped quote inside an attribute value does not end
     the value (xml-light treats backslash-quote as a literal quote). *)
  check "escaped quote in attr value -> single open tag"
    (let st = scan {|<x a="he said \" end">|} in
     Xml_framing.depth st = 1 && not (Xml_framing.at_boundary st));

  (* Comments and headers are depth-neutral and complete cleanly. *)
  check "comment is depth-neutral"
    (Xml_framing.depth (scan {|<!-- <fake> --><a/>|}) = 0
     && Xml_framing.at_boundary (scan {|<!-- <fake> --><a/>|}));
  check "header is depth-neutral"
    (Xml_framing.depth (scan {|<?xml version="1.0"?><a/>|}) = 0
     && Xml_framing.at_boundary (scan {|<?xml version="1.0"?><a/>|}));

  (* Two complete messages: boundary reported after the first already. *)
  check "two messages -> boundary after first"
    (first_boundary (m1 ^ m1) = Some (String.length m1 - 1));

  (* Resync pattern used by Rocq_protocol: after the first message is
     parsed and trimmed away, a fresh scanner over the partial remainder
     reports no boundary until that message completes. *)
  let remainder = {|<feedback object="state"><state_id val="3"/>|} in
  check "resync remainder -> no boundary"
    (not (Xml_framing.at_boundary (scan remainder)));
  check "resync remainder -> depth 1" (Xml_framing.depth (scan remainder) = 1);
  check "resync completed -> boundary"
    (Xml_framing.at_boundary (scan (remainder ^ {|</feedback>|})));

  if !failures > 0 then (Printf.printf "%d failure(s)\n" !failures; exit 1)
  else Printf.printf "all xml_framing tests passed\n"
