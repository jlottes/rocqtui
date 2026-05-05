(* File manager: owns the inotify watcher and handles file change detection.
   Determines when to auto-reload vs notify. *)

type file_event =
  | Reloaded of string          (* file was auto-reloaded *)
  | DiskChanged of string       (* file changed, buffer is dirty — notify only *)
  | VerifiedAffected of string  (* file changed within verified region — notify only *)

type t = {
  watcher : File_watch.t;
  mutable deferred : string list;
  (* Paths whose change events arrived while a tab was locked by
     an external client. Re-tried on each poll until the lock
     releases. *)
}

let create () =
  { watcher = File_watch.create (); deferred = [] }

let watch_fd t = File_watch.watch_fd t.watcher

let add_watch t path =
  File_watch.add_watch t.watcher path

let close t =
  File_watch.close t.watcher

(* Reload a tab's buffer from disk: rewind session, reload, re-watch.
   If [keep_verified] is true, skip the session rewind and let the
   gateway decide if the reload preserves the verified region. *)
let reload_tab ?(keep_verified = false) t (tab : Tab.t) path =
  if not keep_verified then
    (match tab.session with
     | Some s -> Session.go_to_offset s 0
     | None -> ());
  let result = Region_buffer.try_reload_from_disk tab.rb in
  (match result with
   | Region_buffer.Applied ->
     Buffer.set_disk_changed tab.buf false;
     File_watch.add_watch t.watcher path
   | Region_buffer.Rejected _ -> ());
  result

(* Check for file changes and process them against open tabs.
   Returns a list of events describing what happened. Events for tabs
   whose buffer is locked are deferred and retried on subsequent polls,
   so external file changes are handled the moment the lock releases
   rather than racing the bridge mid-sequence. *)
let poll t (tabs : Tab.t list) =
  let new_events =
    if File_watch.poll t.watcher then File_watch.take_changed t.watcher
    else []
  in
  let to_process =
    List.sort_uniq String.compare (t.deferred @ new_events)
  in
  if to_process = [] then []
  else begin
    t.deferred <- [];
    let events = ref [] in
    let still_deferred = ref [] in
    let defer path =
      if not (List.mem path !still_deferred) then
        still_deferred := path :: !still_deferred
    in
    List.iter (fun path ->
      List.iter (fun (tab : Tab.t) ->
        match Buffer.filename tab.buf with
        | Some f when f = path ->
          if Region_buffer.locked tab.rb then
            defer path
          else begin
            Buffer.set_disk_changed tab.buf true;
            if Buffer.modified tab.buf then
              (* Dirty buffer — just notify, don't reload *)
              events := DiskChanged path :: !events
            else begin
              let old_text = Buffer.text tab.buf in
              let new_text = try
                let ic = open_in path in
                let s = In_channel.input_all ic in
                close_in ic; s
              with _ -> old_text in
              if old_text = new_text then
                Buffer.set_disk_changed tab.buf false
              else begin
                match reload_tab ~keep_verified:true t tab path with
                | Region_buffer.Applied ->
                  events := Reloaded path :: !events
                | Region_buffer.Rejected _ ->
                  events := VerifiedAffected path :: !events
              end
            end
          end
        | _ -> ()
      ) tabs
    ) to_process;
    t.deferred <- !still_deferred;
    List.rev !events
  end
