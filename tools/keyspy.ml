(* keyspy: display raw bytes received from stdin.
   Run inside an embedded terminal to debug key encoding. *)

let () =
  (* Put stdin in raw mode *)
  let tio = Unix.tcgetattr Unix.stdin in
  let raw = { tio with
    Unix.c_icanon = false;
    c_echo = false;
    c_isig = false;
    c_ixon = false;
    c_icrnl = false;
    c_vmin = 1;
    c_vtime = 0;
  } in
  Unix.tcsetattr Unix.stdin Unix.TCSANOW raw;
  let write s = ignore (Unix.write_substring Unix.stdout s 0 (String.length s)) in
  (* Enable Kitty keyboard protocol level 1 *)
  write "\x1b[>1u";
  let restore () =
    write "\x1b[<u";  (* disable Kitty *)
    Unix.tcsetattr Unix.stdin Unix.TCSANOW tio
  in
  at_exit restore;
  Printf.printf "keyspy: press keys to see raw bytes. Ctrl+\\ to quit.\n%!";
  Printf.printf "  (Kitty keyboard protocol level 1 enabled)\n%!";
  let buf = Bytes.create 64 in
  try while true do
    let n = Unix.read Unix.stdin buf 0 64 in
    if n > 0 then begin
      (* Quit on Ctrl+\ : legacy single byte 0x1c, or — when the kitty
         keyboard protocol is active (iTerm2 etc.) — CSI 92 ; <mods> u
         (backslash = codepoint 92, ctrl = modifier bit). *)
      let is_ctrl_backslash =
        (n = 1 && Bytes.get buf 0 = '\x1c')
        || (let s = Bytes.sub_string buf 0 n in
            n >= 6 && String.sub s 0 5 = "\x1b[92;" && s.[n - 1] = 'u')
      in
      if is_ctrl_backslash then begin
        Printf.printf "\nquit.\n%!";
        exit 0
      end;
      Printf.printf "  %d byte%s:" n (if n > 1 then "s" else "");
      for i = 0 to n - 1 do
        let c = Char.code (Bytes.get buf i) in
        Printf.printf " %02x" c
      done;
      Printf.printf "  |";
      for i = 0 to n - 1 do
        let c = Char.code (Bytes.get buf i) in
        if c >= 32 && c < 127 then
          Printf.printf "%c" (Char.chr c)
        else
          Printf.printf "."
      done;
      Printf.printf "|\n%!"
    end
  done with _ -> ()
