(* File modification watcher using Linux inotify. *)

external inotify_init : unit -> int = "caml_inotify_init"
external inotify_add_watch : int -> string -> int -> int = "caml_inotify_add_watch"
external inotify_rm_watch : int -> int -> unit = "caml_inotify_rm_watch"
external inotify_read : int -> (int * int * string) list = "caml_inotify_read"
external in_close_write : unit -> int = "caml_inotify_in_close_write"
external in_move_self : unit -> int = "caml_inotify_in_move_self"
external in_delete_self : unit -> int = "caml_inotify_in_delete_self"

type watch = {
  wd : int;
  path : string;
}

type t = {
  fd : Unix.file_descr;
  ifd : int;  (* raw fd for inotify calls *)
  mutable watches : watch list;
  mutable changed_paths : string list;  (* paths with pending changes *)
}

let mask = in_close_write () lor in_move_self () lor in_delete_self ()

let create () =
  let ifd = inotify_init () in
  { fd = (Obj.magic ifd : Unix.file_descr);
    ifd;
    watches = [];
    changed_paths = [] }

let watch_fd t = t.fd

let add_watch t path =
  (* Don't double-watch *)
  if List.exists (fun w -> w.path = path) t.watches then ()
  else begin
    try
      let wd = inotify_add_watch t.ifd path mask in
      t.watches <- { wd; path } :: t.watches
    with _ -> ()  (* file might not exist yet *)
  end

let remove_watch t path =
  match List.find_opt (fun w -> w.path = path) t.watches with
  | Some w ->
    (try inotify_rm_watch t.ifd w.wd with _ -> ());
    t.watches <- List.filter (fun w2 -> w2.path <> path) t.watches
  | None -> ()

(* Masks for detecting file replacement (atomic rename) *)
let mask_delete_self = in_delete_self ()
let mask_move_self = in_move_self ()

(* Read pending events. Returns list of changed file paths. *)
let poll t =
  let events = try inotify_read t.ifd with _ -> [] in
  let paths = List.filter_map (fun (wd, emask, _name) ->
    match List.find_opt (fun w -> w.wd = wd) t.watches with
    | Some w ->
      (* If the file was replaced (atomic rename), the old watch is dead.
         Re-add the watch on the new inode at the same path. *)
      if emask land mask_delete_self <> 0
         || emask land mask_move_self <> 0 then begin
        t.watches <- List.filter (fun w2 -> w2.wd <> wd) t.watches;
        (try
           let new_wd = inotify_add_watch t.ifd w.path mask in
           t.watches <- { wd = new_wd; path = w.path } :: t.watches
         with _ -> ())
      end;
      Some w.path
    | None -> None
  ) events in
  (* Deduplicate and accumulate *)
  let new_paths = List.filter (fun p ->
    not (List.mem p t.changed_paths)
  ) paths in
  t.changed_paths <- t.changed_paths @ new_paths;
  new_paths <> []

(* Get and clear the list of changed paths. *)
let take_changed t =
  let paths = t.changed_paths in
  t.changed_paths <- [];
  paths

let close t =
  List.iter (fun w ->
    (try inotify_rm_watch t.ifd w.wd with _ -> ())
  ) t.watches;
  (try Unix.close t.fd with _ -> ())
