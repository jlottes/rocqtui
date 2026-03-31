(* File manager: owns the inotify watcher and handles file change detection.
   Determines when to auto-reload vs notify. *)

type file_event =
  | Reloaded of string          (* file was auto-reloaded *)
  | DiskChanged of string       (* file changed, buffer is dirty — notify only *)
  | VerifiedAffected of string  (* file changed within verified region — notify only *)

type t = {
  watcher : File_watch.t;
}

let create () =
  { watcher = File_watch.create () }

let watch_fd t = File_watch.watch_fd t.watcher

let add_watch t path =
  File_watch.add_watch t.watcher path

let close t =
  File_watch.close t.watcher

(* Reload a tab's buffer from disk: rewind session, reload, re-watch. *)
let reload_tab t (tab : Tab.t) path =
  (match tab.session with
   | Some s -> Session.go_to_offset s 0
   | None -> ());
  Buffer.reload tab.buf;
  Buffer.set_disk_changed tab.buf false;
  File_watch.add_watch t.watcher path

(* Check for file changes and process them against open tabs.
   Returns a list of events describing what happened. *)
let poll t (tabs : Tab.t list) =
  if not (File_watch.poll t.watcher) then []
  else begin
    let changed = File_watch.take_changed t.watcher in
    let events = ref [] in
    List.iter (fun path ->
      List.iter (fun (tab : Tab.t) ->
        match Buffer.filename tab.buf with
        | Some f when f = path ->
          Buffer.set_disk_changed tab.buf true;
          if Buffer.modified tab.buf then
            (* Dirty buffer — just notify, don't reload *)
            events := DiskChanged path :: !events
          else begin
            (* Compare disk content with buffer to detect actual changes *)
            let old_text = Buffer.text tab.buf in
            let new_text = try
              let ic = open_in path in
              let s = In_channel.input_all ic in
              close_in ic; s
            with _ -> old_text in
            if old_text = new_text then
              (* No actual change — likely our own save. Clear the flag. *)
              Buffer.set_disk_changed tab.buf false
            else begin
              let vend = match tab.session with
                | Some s -> Session.verified_end s | None -> 0 in
              if vend > 0 then begin
                let min_len = min (String.length old_text) (String.length new_text) in
                let diff_at = ref min_len in
                (try for i = 0 to min_len - 1 do
                   if old_text.[i] <> new_text.[i] then begin
                     diff_at := i; raise Exit
                   end
                 done with Exit -> ());
                if !diff_at < vend then
                  events := VerifiedAffected path :: !events
                else begin
                  reload_tab t tab path;
                  events := Reloaded path :: !events
                end
              end else begin
                reload_tab t tab path;
                events := Reloaded path :: !events
              end
            end
          end
        | _ -> ()
      ) tabs
    ) changed;
    List.rev !events
  end
