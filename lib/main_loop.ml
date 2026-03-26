(* CursesMainLoop: implements Spawn.MainLoopModel for our select-based loop.

   The main loop calls [poll_watches] on each iteration, which checks all
   registered fds via Unix.select and dispatches callbacks for ready ones. *)

type async_chan = Unix.file_descr

(* Conditions match GLib's convention *)
type condition = [ `IN | `ERR | `HUP | `NVAL | `PRI ]

type watch_id = int

type watch_entry = {
  id : watch_id;
  fd : Unix.file_descr;
  callback : condition list -> bool;
}

let next_id = ref 0
let watches : watch_entry list ref = ref []

let add_watch ~callback fd =
  let id = !next_id in
  incr next_id;
  watches := { id; fd; callback } :: !watches;
  id

let remove_watch wid =
  watches := List.filter (fun w -> w.id <> wid) !watches

let read_all fd =
  (* Read all available bytes from a non-blocking fd *)
  let buf = Stdlib.Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let keep_reading = ref true in
  while !keep_reading do
    try
      let n = Unix.read fd chunk 0 4096 in
      if n = 0 then keep_reading := false
      else Stdlib.Buffer.add_subbytes buf chunk 0 n
    with
    | Unix.Unix_error (Unix.EAGAIN, _, _) -> keep_reading := false
    | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) -> keep_reading := false
  done;
  Stdlib.Buffer.contents buf

let async_chan_of_file_or_socket fd = fd

(* Get all watched fds for use in select *)
let watched_fds () =
  List.map (fun w -> w.fd) !watches

(* Check watched fds and dispatch callbacks. Non-blocking (timeout=0).
   Returns true if any callback fired. *)
let [@warning "-32"] poll_watches () =
  match !watches with
  | [] -> false
  | _ ->
    let fds = watched_fds () in
    let ready, _, _ =
      try Unix.select fds [] [] 0.0
      with Unix.Unix_error (Unix.EINTR, _, _) -> ([], [], [])
    in
    let any_fired = ref false in
    List.iter (fun fd ->
      match List.find_opt (fun w -> w.fd = fd) !watches with
      | Some w ->
        any_fired := true;
        let live = w.callback [`IN] in
        if not live then remove_watch w.id
      | None -> ()
    ) ready;
    !any_fired

(* Select on watched fds + extra fds (like stdin), with timeout.
   Returns list of ready extra fds. Dispatches watch callbacks internally. *)
let select_with_watches extra_fds timeout =
  let watch_fds = watched_fds () in
  let all_fds = watch_fds @ extra_fds in
  let ready, _, _ =
    try Unix.select all_fds [] [] timeout
    with Unix.Unix_error (Unix.EINTR, _, _) -> ([], [], [])
  in
  (* Dispatch watch callbacks *)
  List.iter (fun fd ->
    match List.find_opt (fun w -> w.fd = fd) !watches with
    | Some w ->
      let live = w.callback [`IN] in
      if not live then remove_watch w.id
    | None -> ()
  ) ready;
  (* Return only the extra fds that are ready *)
  List.filter (fun fd -> List.mem fd ready) extra_fds
