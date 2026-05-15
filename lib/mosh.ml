(* Detect whether we're running under mosh.

   Mosh's terminal emulator on the server side re-emits a sanitized
   subset of SGR codes and drops some attributes — notably SGR 2 (dim)
   on at least some versions.  Grid.emit_attr consults [is_active] to
   substitute a darker fg color when dim is requested.

   Detection walks parent processes via /proc looking for
   [mosh-server].  Linux-only, which matches the rest of rocqtui.

   Override with the ROCQTUI_MOSH env var: "0" or "false" forces off,
   any other value forces on, unset auto-detects. *)

let read_comm pid =
  try
    let ic = open_in (Printf.sprintf "/proc/%d/comm" pid) in
    let s = input_line ic in
    close_in ic;
    Some (String.trim s)
  with _ -> None

let read_ppid pid =
  try
    let ic = open_in (Printf.sprintf "/proc/%d/status" pid) in
    let r = ref None in
    (try
      while true do
        let line = input_line ic in
        if String.length line > 5 && String.sub line 0 5 = "PPid:" then begin
          let rest = String.trim (String.sub line 5 (String.length line - 5)) in
          r := int_of_string_opt rest;
          raise Exit
        end
      done
    with Exit | End_of_file -> ());
    close_in ic;
    !r
  with _ -> None

let any_ancestor_is_mosh_server () =
  let rec loop pid depth =
    if depth >= 32 || pid <= 1 then false
    else match read_comm pid with
      | Some "mosh-server" -> true
      | _ ->
        (match read_ppid pid with
         | Some ppid when ppid > 0 && ppid <> pid -> loop ppid (depth + 1)
         | _ -> false)
  in
  loop (Unix.getpid ()) 0

let detect () =
  match Sys.getenv_opt "ROCQTUI_MOSH" with
  | Some ("0" | "false" | "FALSE" | "") -> false
  | Some _ -> true
  | None -> any_ancestor_is_mosh_server ()

let active = lazy (detect ())

let is_active () = Lazy.force active
