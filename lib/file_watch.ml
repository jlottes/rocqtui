(* File and directory watcher using Linux inotify.

   Two flavors of watch:
   - file watches: track content changes of one file (used to detect
     external edits to open buffers and to the project file)
   - directory watches: track entries created/deleted/moved inside one
     directory (used by File_tree to follow project-tree changes) *)

external inotify_init : unit -> int = "caml_inotify_init"
external inotify_add_watch : int -> string -> int -> int = "caml_inotify_add_watch"
external inotify_rm_watch : int -> int -> unit = "caml_inotify_rm_watch"
external inotify_read : int -> (int * int * string) list = "caml_inotify_read"
external in_close_write : unit -> int = "caml_inotify_in_close_write"
external in_move_self : unit -> int = "caml_inotify_in_move_self"
external in_delete_self : unit -> int = "caml_inotify_in_delete_self"
external in_create : unit -> int = "caml_inotify_in_create"
external in_delete : unit -> int = "caml_inotify_in_delete"
external in_moved_from : unit -> int = "caml_inotify_in_moved_from"
external in_moved_to : unit -> int = "caml_inotify_in_moved_to"
external in_isdir : unit -> int = "caml_inotify_in_isdir"
external in_ignored : unit -> int = "caml_inotify_in_ignored"

type watch_kind = WatchFile | WatchDir

type watch = {
  wd : int;
  path : string;
  kind : watch_kind;
}

type event =
  | FileChanged of string
  | DirEntryAdded of { dir : string; name : string; is_dir : bool }
  | DirEntryRemoved of { dir : string; name : string; is_dir : bool }

type t = {
  fd : Unix.file_descr;
  ifd : int;
  mutable watches : watch list;
}

let file_mask = in_close_write () lor in_move_self () lor in_delete_self ()
let dir_mask = in_create () lor in_delete ()
               lor in_moved_from () lor in_moved_to ()

let mask_delete_self = in_delete_self ()
let mask_move_self = in_move_self ()
let mask_create = in_create ()
let mask_delete = in_delete ()
let mask_moved_from = in_moved_from ()
let mask_moved_to = in_moved_to ()
let mask_isdir = in_isdir ()
let mask_ignored = in_ignored ()

let create () =
  let ifd = inotify_init () in
  { fd = (Obj.magic ifd : Unix.file_descr);
    ifd;
    watches = [] }

let watch_fd t = t.fd

let find_watch_by_path t path =
  List.find_opt (fun w -> w.path = path) t.watches

let add_watch t path =
  match find_watch_by_path t path with
  | Some _ -> ()
  | None ->
    try
      let wd = inotify_add_watch t.ifd path file_mask in
      t.watches <- { wd; path; kind = WatchFile } :: t.watches
    with _ -> ()  (* file might not exist yet *)

let add_dir_watch t path =
  match find_watch_by_path t path with
  | Some w when w.kind = WatchDir -> ()
  | Some _ ->
    (* Was a file watch on the same path — replace with a dir watch. *)
    (try inotify_rm_watch t.ifd
       (List.find (fun w -> w.path = path) t.watches).wd
     with _ -> ());
    t.watches <- List.filter (fun w -> w.path <> path) t.watches;
    (try
       let wd = inotify_add_watch t.ifd path dir_mask in
       t.watches <- { wd; path; kind = WatchDir } :: t.watches
     with _ -> ())
  | None ->
    try
      let wd = inotify_add_watch t.ifd path dir_mask in
      t.watches <- { wd; path; kind = WatchDir } :: t.watches
    with _ -> ()

let remove_watch t path =
  match find_watch_by_path t path with
  | Some w ->
    (try inotify_rm_watch t.ifd w.wd with _ -> ());
    t.watches <- List.filter (fun w2 -> w2.wd <> w.wd) t.watches
  | None -> ()

(* Decode raw inotify events into our typed event variant. Also handles
   re-attaching watches when a file is replaced (atomic rename) so a
   subsequent edit still fires events on the same logical path. *)
let poll t =
  let raw = try inotify_read t.ifd with _ -> [] in
  let events = ref [] in
  let push e = events := e :: !events in
  List.iter (fun (wd, emask, name) ->
    match List.find_opt (fun w -> w.wd = wd) t.watches with
    | None -> ()
    | Some w ->
      match w.kind with
      | WatchFile ->
        (* The watched inode is gone whenever MOVE_SELF, DELETE_SELF,
           or IGNORED fires. Atomic-rename saves produce all three —
           Claude Code's Edit tool emits IGNORED before DELETE_SELF,
           so checking only the latter two would let IGNORED GC the
           entry first and silently skip the re-attach. Drop the dead
           entry and try to re-attach on the same path so subsequent
           edits still fire. Repeat events for the same wd within one
           poll are harmless: the second lookup falls through to None. *)
        if emask land mask_delete_self <> 0
           || emask land mask_move_self <> 0
           || emask land mask_ignored <> 0 then begin
          t.watches <- List.filter (fun w2 -> w2.wd <> wd) t.watches;
          (try
             let new_wd = inotify_add_watch t.ifd w.path file_mask in
             t.watches <-
               { wd = new_wd; path = w.path; kind = WatchFile }
               :: t.watches
           with _ -> ())
        end;
        push (FileChanged w.path)
      | WatchDir ->
        if emask land mask_ignored <> 0 then
          (* Directory gone (deleted / unmounted) — GC the entry. *)
          t.watches <- List.filter (fun w2 -> w2.wd <> wd) t.watches
        else begin
          let is_dir = emask land mask_isdir <> 0 in
          let added =
            emask land mask_create <> 0
            || emask land mask_moved_to <> 0
          in
          let removed =
            emask land mask_delete <> 0
            || emask land mask_moved_from <> 0
          in
          if added then
            push (DirEntryAdded { dir = w.path; name; is_dir })
          else if removed then
            push (DirEntryRemoved { dir = w.path; name; is_dir })
        end
  ) raw;
  List.rev !events

let close t =
  List.iter (fun w ->
    (try inotify_rm_watch t.ifd w.wd with _ -> ())
  ) t.watches;
  t.watches <- [];
  (try Unix.close t.fd with _ -> ())

let watched_paths t =
  List.map (fun w -> w.path) t.watches
