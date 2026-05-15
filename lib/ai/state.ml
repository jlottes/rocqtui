(* Global AI subsystem state.

   Holds the single-flight request id (per-project convention: default
   to global, not per-tab) and an internal per-tab table so Tab.t need
   not know about AI at all. *)

type status =
  | Idle                       (* enabled, no activity *)
  | Pending                    (* request in flight *)
  | Ready                      (* response received, suggestion visible *)
  | Backend_error of string    (* bridge / llama-server unreachable *)
  | Disabled                   (* user toggled off *)

type t = {
  socket_path : string;
  mutable enabled : bool;
  mutable status : status;
  mutable in_flight_req_id : string option;
  mutable in_flight_tab_id : int option;
  (* Callback to cancel the in-flight request. Set by the Trigger
     when issuing; cleared on Done_resp / Error / by the canceller
     itself. *)
  mutable in_flight_cancel : (unit -> unit) option;
  mutable last_request_time : float;
  per_tab : (int, Per_tab.t) Hashtbl.t;
}

let create ~socket_path = {
  socket_path;
  enabled = true;
  status = Idle;
  in_flight_req_id = None;
  in_flight_tab_id = None;
  in_flight_cancel = None;
  last_request_time = 0.;
  per_tab = Hashtbl.create 4;
}

(* Drop the in-flight tracking and run its cancel callback (closing
   the bridge connection). Safe to call when nothing is in flight. *)
let cancel_in_flight t =
  (match t.in_flight_cancel with
   | Some f -> (try f () with _ -> ())
   | None -> ());
  t.in_flight_cancel <- None;
  t.in_flight_req_id <- None;
  t.in_flight_tab_id <- None;
  (match t.status with
   | Pending -> t.status <- Idle
   | _ -> ())

let per_tab t tab_id =
  match Hashtbl.find_opt t.per_tab tab_id with
  | Some p -> p
  | None ->
    let p = Per_tab.create () in
    Hashtbl.add t.per_tab tab_id p;
    p

let drop_tab t tab_id = Hashtbl.remove t.per_tab tab_id

let status_glyph = function
  | Disabled -> "○"
  | Backend_error _ -> "!"
  | Idle -> "·"
  | Pending -> "◐"
  | Ready -> "✦"

(* Clear ghost on every tab — used when toggling off or hard-dismiss. *)
let clear_all_ghosts t =
  Hashtbl.iter (fun _ p -> Per_tab.clear p) t.per_tab
