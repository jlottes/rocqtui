(* Terminal setup, teardown, and size queries.
   Replaces ncurses' initscr/endwin/raw/noecho. *)

(* C stubs *)
external get_winsize : Unix.file_descr -> int * int = "caml_get_winsize"
external install_crash_handler : unit -> unit = "caml_install_crash_handler"
external setlocale : int -> string -> string = "caml_curses_setlocale"

let original_termios : Unix.terminal_io option ref = ref None
let is_init = ref false
let sigwinch_pending = ref false

let init () =
  if !is_init then ()
  else begin
    is_init := true;
    ignore (setlocale 0 "");  (* LC_ALL *)
    (* Save and set raw mode *)
    let old = Unix.tcgetattr Unix.stdin in
    original_termios := Some old;
    let raw = { old with
      Unix.c_icanon = false;
      c_echo = false;
      c_isig = false;   (* no SIGINT/SIGQUIT from ^C/^\ *)
      c_ixon = false;   (* no ^S/^Q flow control *)
      c_icrnl = false;  (* don't convert CR to NL — needed to distinguish Enter from Shift+Enter *)
      c_vmin = 0;
      c_vtime = 0;
    } in
    Unix.tcsetattr Unix.stdin Unix.TCSANOW raw;
    (* Alternate screen buffer *)
    let write s = ignore (Unix.write_substring Unix.stdout s 0 (String.length s)) in
    write "\x1b[?1049h";       (* alternate screen *)
    write "\x1b[?25l";         (* hide cursor *)
    write "\x1b[?1002h";       (* button-event mouse tracking *)
    write "\x1b[?1006h";       (* SGR mouse mode — better than X10 *)
    write "\x1b[?2004h";       (* bracketed paste *)
    write "\x1b[>1u";          (* Kitty keyboard protocol level 1: disambiguate *)
    (* SIGWINCH handler — set a flag, deliver as Resize event *)
    Sys.set_signal 28 (* SIGWINCH *)
      (Sys.Signal_handle (fun _ -> sigwinch_pending := true));
    (* Install crash handler to reset terminal on SIGSEGV/SIGBUS/SIGABRT *)
    install_crash_handler ();
  end

let teardown () =
  if not !is_init then ()
  else begin
    is_init := false;
    let write s = ignore (Unix.write_substring Unix.stdout s 0 (String.length s)) in
    write "\x1b[<u";           (* disable Kitty keyboard protocol *)
    write "\x1b[?2004l";       (* disable bracketed paste *)
    write "\x1b[?1006l";       (* disable SGR mouse *)
    write "\x1b[?1002l";       (* disable mouse tracking *)
    write "\x1b[?25h";         (* show cursor *)
    write "\x1b[?1049l";       (* restore main screen *)
    write "\x1b[0m";           (* reset attributes *)
    Sys.set_signal 28 Sys.Signal_default;
    (* Restore terminal settings *)
    (match !original_termios with
     | Some old -> Unix.tcsetattr Unix.stdin Unix.TCSANOW old
     | None -> ());
    original_termios := None
  end

let size () =
  try get_winsize Unix.stdout
  with _ ->
    (* Fallback: try stty *)
    try
      let ic = Unix.open_process_in "stty size 2>/dev/null" in
      let line = input_line ic in
      ignore (Unix.close_process_in ic);
      Scanf.sscanf line "%d %d" (fun h w -> (h, w))
    with _ -> (24, 80)

(* Write raw bytes to stdout *)
let write_stdout s =
  let len = String.length s in
  let written = ref 0 in
  while !written < len do
    try
      let n = Unix.write_substring Unix.stdout s !written (len - !written) in
      written := !written + n
    with Unix.Unix_error (Unix.EINTR, _, _) -> ()  (* retry *)
  done

(* Flush — Unix.write is unbuffered, but we may want to batch *)
let [@warning "-32"] flush () = ()  (* no-op with direct Unix.write *)

(* Move cursor to (row, col), 0-based *)
let move_cursor row col =
  write_stdout (Printf.sprintf "\x1b[%d;%dH" (row + 1) (col + 1))

(* Show/hide cursor *)
let show_cursor () = write_stdout "\x1b[?25h"
let hide_cursor () = write_stdout "\x1b[?25l"

(* Clear entire screen *)
let clear_screen () = write_stdout "\x1b[2J\x1b[H"

(* Check and clear the SIGWINCH flag *)
let check_resize () =
  if !sigwinch_pending then begin
    sigwinch_pending := false;
    true
  end else false

(* OSC 1547 ; <slot> ; <pattern> ST  — bind font slot to fontconfig pattern.
   OSC 1547 ; <slot>              ST  — unbind. *)
let bind_font_slot slot pattern =
  write_stdout (Printf.sprintf "\x1b]1547;%d;%s\x1b\\" slot pattern)

let unbind_font_slot slot =
  write_stdout (Printf.sprintf "\x1b]1547;%d\x1b\\" slot)
