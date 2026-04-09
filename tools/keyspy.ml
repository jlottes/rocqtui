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
  let restore () = Unix.tcsetattr Unix.stdin Unix.TCSANOW tio in
  at_exit restore;
  Printf.printf "keyspy: press keys to see raw bytes. Ctrl+\\ to quit.\n%!";
  let buf = Bytes.create 64 in
  try while true do
    let n = Unix.read Unix.stdin buf 0 64 in
    if n > 0 then begin
      (* Check for Ctrl+\ (0x1c) to quit *)
      if n = 1 && Bytes.get buf 0 = '\x1c' then begin
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
