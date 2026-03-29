(* Terminal input parser.
   Reads raw bytes from stdin, parses escape sequences into key events.
   Handles: CSI sequences (arrows, function keys, mouse), CSI u (Kitty),
   SS3, bracketed paste, and plain UTF-8 characters. *)

type modifier = {
  shift : bool;
  alt : bool;
  ctrl : bool;
  super : bool;
}

let no_mod = { shift = false; alt = false; ctrl = false; super = false }

let modifier_of_param n =
  let bits = n - 1 in
  { shift = bits land 1 <> 0;
    alt = bits land 2 <> 0;
    ctrl = bits land 4 <> 0;
    super = bits land 8 <> 0 }

type special_key =
  | Up | Down | Left | Right
  | Home | End | PageUp | PageDown
  | Insert | Delete
  | F of int
  | Backspace | Tab | Enter | Escape

type mouse_button = Left | Middle | Right | ScrollUp | ScrollDown | Release

type mouse_event = {
  button : mouse_button;
  x : int;
  y : int;
  mods : modifier;
}

type event =
  | Key of int * modifier          (* Unicode codepoint + modifiers *)
  | Special of special_key * modifier
  | Mouse of mouse_event
  | Paste of string
  | Resize
  | Unknown

(* Read a single byte from fd with timeout (seconds).
   Returns -1 on timeout, error, or EINTR (signal interrupted). *)
let read_byte fd timeout =
  try
    let ready, _, _ = Unix.select [fd] [] [] timeout in
    if ready = [] then -1
    else begin
      let buf = Bytes.create 1 in
      let n = Unix.read fd buf 0 1 in
      if n = 0 then -1
      else Char.code (Bytes.get buf 0)
    end
  with
  | Unix.Unix_error (Unix.EINTR, _, _) -> -1  (* signal interrupted *)
  | _ -> -1

(* Read a single byte, blocking. Retries on EINTR. *)
let read_byte_block fd =
  let rec loop () =
    try
      let buf = Bytes.create 1 in
      let n = Unix.read fd buf 0 1 in
      if n = 0 then -1
      else Char.code (Bytes.get buf 0)
    with
    | Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    | _ -> -1
  in loop ()

(* Read remaining bytes of a UTF-8 sequence given the first byte. *)
let read_utf8 fd first_byte =
  let expected =
    if first_byte < 0x80 then 0
    else if first_byte < 0xC0 then 0  (* invalid *)
    else if first_byte < 0xE0 then 1
    else if first_byte < 0xF0 then 2
    else 3
  in
  if expected = 0 then first_byte
  else begin
    let cp = ref (first_byte land (0x7F lsr expected)) in
    for _ = 1 to expected do
      let b = read_byte fd 0.05 in
      if b >= 0x80 && b < 0xC0 then
        cp := (!cp lsl 6) lor (b land 0x3F)
      else
        cp := 0xFFFD  (* invalid *)
    done;
    !cp
  end

(* Parse CSI parameters: semicolon-separated integers *)
let parse_params s =
  let parts = String.split_on_char ';' s in
  List.map (fun p ->
    match String.split_on_char ':' p with
    | n :: _ -> (match int_of_string_opt n with Some v -> v | None -> 0)
    | [] -> 0
  ) parts

(* Parse a CSI sequence (after ESC [).
   Reads parameter bytes then the final byte. *)
let parse_csi fd =
  let params = Stdlib.Buffer.create 16 in
  let rec read_params () =
    let b = read_byte fd 0.05 in
    if b < 0 then Unknown
    else if b >= 0x30 && b <= 0x3F then begin
      (* Parameter byte: 0-9 : ; < = > ? *)
      Stdlib.Buffer.add_char params (Char.chr b);
      read_params ()
    end
    else if b >= 0x20 && b <= 0x2F then begin
      (* Intermediate byte — rare, skip *)
      Stdlib.Buffer.add_char params (Char.chr b);
      read_params ()
    end
    else
      (* Final byte 0x40-0x7E *)
      let param_str = Stdlib.Buffer.contents params in
      let plist = parse_params param_str in
      let mods_from p = if p > 1 then modifier_of_param p else no_mod in
      match Char.chr b with
      | 'A' -> let m = match plist with _ :: p :: _ -> mods_from p | _ -> no_mod in
               Special (Up, m)
      | 'B' -> let m = match plist with _ :: p :: _ -> mods_from p | _ -> no_mod in
               Special (Down, m)
      | 'C' -> let m = match plist with _ :: p :: _ -> mods_from p | _ -> no_mod in
               Special (Right, m)
      | 'D' -> let m = match plist with _ :: p :: _ -> mods_from p | _ -> no_mod in
               Special (Left, m)
      | 'H' -> let m = match plist with _ :: p :: _ -> mods_from p | _ -> no_mod in
               Special (Home, m)
      | 'F' -> let m = match plist with _ :: p :: _ -> mods_from p | _ -> no_mod in
               Special (End, m)
      | '~' ->
        let key_num = match plist with n :: _ -> n | [] -> 0 in
        let m = match plist with _ :: p :: _ -> mods_from p | _ -> no_mod in
        (match key_num with
         | 2 -> Special (Insert, m)
         | 3 -> Special (Delete, m)
         | 5 -> Special (PageUp, m)
         | 6 -> Special (PageDown, m)
         | 15 -> Special (F 5, m)
         | 17 -> Special (F 6, m)
         | 18 -> Special (F 7, m)
         | 19 -> Special (F 8, m)
         | 20 -> Special (F 9, m)
         | 21 -> Special (F 10, m)
         | 23 -> Special (F 11, m)
         | 24 -> Special (F 12, m)
         | 200 ->
           (* Bracketed paste start *)
           let paste_buf = Stdlib.Buffer.create 256 in
           let done_ = ref false in
           while not !done_ do
             let c = read_byte_block fd in
             if c < 0 then done_ := true
             else if c = 27 then begin
               (* Check for ESC[201~ *)
               let c1 = read_byte fd 0.05 in
               if c1 = Char.code '[' then begin
                 let p = Stdlib.Buffer.create 8 in
                 let fin = ref (-1) in
                 let stop = ref false in
                 while not !stop do
                   let c2 = read_byte fd 0.05 in
                   if c2 < 0 then stop := true
                   else if c2 >= 0x40 && c2 <= 0x7E then
                     (fin := c2; stop := true)
                   else Stdlib.Buffer.add_char p (Char.chr c2)
                 done;
                 if Stdlib.Buffer.contents p = "201" && !fin = Char.code '~' then
                   done_ := true
                 else begin
                   Stdlib.Buffer.add_char paste_buf '\x1b';
                   Stdlib.Buffer.add_char paste_buf '[';
                   Stdlib.Buffer.add_string paste_buf (Stdlib.Buffer.contents p);
                   if !fin >= 0 then Stdlib.Buffer.add_char paste_buf (Char.chr !fin)
                 end
               end else begin
                 Stdlib.Buffer.add_char paste_buf '\x1b';
                 if c1 >= 0 then Stdlib.Buffer.add_char paste_buf (Char.chr c1)
               end
             end else
               Stdlib.Buffer.add_char paste_buf (Char.chr c)
           done;
           Paste (Stdlib.Buffer.contents paste_buf)
         | _ -> Unknown)
      | 'u' ->
        (* CSI u — Kitty keyboard protocol *)
        let keycode = match plist with n :: _ -> n | [] -> 0 in
        let m = match plist with _ :: p :: _ -> mods_from p | _ -> no_mod in
        (* Map well-known keycodes to Special *)
        (match keycode with
         | 13 -> Special (Enter, m)
         | 9 -> Special (Tab, m)
         | 27 -> Special (Escape, m)
         | 127 -> Special (Backspace, m)
         | 57352 -> Special (Up, m)     (* KP_UP *)
         | 57353 -> Special (Down, m)
         | 57354 -> Special (Right, m)
         | 57355 -> Special (Left, m)
         | n -> Key (n, m))
      | 'M' ->
        (* X10 mouse — 3 bytes follow *)
        let cb = read_byte fd 0.05 in
        let cx = read_byte fd 0.05 in
        let cy = read_byte fd 0.05 in
        if cb < 0 || cx < 0 || cy < 0 then Unknown
        else
          let btn = cb - 32 in
          let x = cx - 33 in
          let y = cy - 33 in
          let button = match btn land 3 with
            | 0 -> Left | 1 -> Middle | 2 -> Right | 3 -> Release
            | _ -> Left
          in
          let button = if btn land 64 <> 0 then
            (if btn land 1 <> 0 then ScrollDown else ScrollUp)
          else button in
          let mods = { shift = btn land 4 <> 0;
                       alt = btn land 8 <> 0;
                       ctrl = btn land 16 <> 0;
                       super = false } in
          Mouse { button; x; y; mods }
      | '<' ->
        (* SGR mouse: CSI < btn ; x ; y [Mm] *)
        (* We already consumed '<' into params. Re-parse. *)
        let rest = Stdlib.Buffer.create 16 in
        Stdlib.Buffer.add_string rest param_str;
        (* The '<' was a parameter prefix; params has everything after it.
           Actually, '<' was consumed as a param byte. Let's re-parse.
           param_str looks like "<btn;x;y" and final byte is 'M' or 'm'. *)
        (* We need to keep reading — '<' was consumed but M/m is the final byte.
           This path is entered when final='<', which is wrong. Let me handle
           SGR mouse differently. *)
        ignore rest;
        Unknown
      | _ -> Unknown
  in
  (* Check for SGR mouse: ESC [ < ... M/m
     The '<' is the first param byte *)
  let first = read_byte fd 0.05 in
  if first < 0 then Unknown
  else if first = Char.code '<' then begin
    (* SGR mouse mode *)
    let params = Stdlib.Buffer.create 16 in
    let final = ref ' ' in
    let finished = ref false in
    while not !finished do
      let b = read_byte fd 0.05 in
      if b < 0 then finished := true
      else if b >= 0x40 && b <= 0x7E then
        (final := Char.chr b; finished := true)
      else
        Stdlib.Buffer.add_char params (Char.chr b)
    done;
    let pstr = Stdlib.Buffer.contents params in
    let parts = String.split_on_char ';' pstr in
    (match parts with
     | [btn_s; x_s; y_s] ->
       let btn = (match int_of_string_opt btn_s with Some n -> n | None -> 0) in
       let x = (match int_of_string_opt x_s with Some n -> n - 1 | None -> 0) in
       let y = (match int_of_string_opt y_s with Some n -> n - 1 | None -> 0) in
       let is_release = !final = 'm' in
       let button =
         if btn land 64 <> 0 then
           (if btn land 1 <> 0 then ScrollDown else ScrollUp)
         else if is_release then Release
         else (match btn land 3 with
               | 0 -> Left | 1 -> Middle | 2 -> Right
               | _ -> Left)
       in
       let mods = { shift = btn land 4 <> 0;
                    alt = btn land 8 <> 0;
                    ctrl = btn land 16 <> 0;
                    super = false } in
       Mouse { button; x; y; mods }
     | _ -> Unknown)
  end
  else begin
    (* Regular CSI — put first byte into params and continue *)
    Stdlib.Buffer.add_char params (Char.chr first);
    read_params ()
  end

(* Parse SS3 sequence (after ESC O) *)
let parse_ss3 fd =
  let b = read_byte fd 0.05 in
  if b < 0 then Unknown
  else match Char.chr b with
    | 'P' -> Special (F 1, no_mod)
    | 'Q' -> Special (F 2, no_mod)
    | 'R' -> Special (F 3, no_mod)
    | 'S' -> Special (F 4, no_mod)
    | 'A' -> Special (Up, no_mod)
    | 'B' -> Special (Down, no_mod)
    | 'C' -> Special (Right, no_mod)
    | 'D' -> Special (Left, no_mod)
    | 'H' -> Special (Home, no_mod)
    | 'F' -> Special (End, no_mod)
    | _ -> Unknown

(* Read one complete input event. Returns None on timeout. *)
let read_event ?(timeout=(-1.0)) fd =
  (* Check for pending resize before reading *)
  if Term.check_resize () then Some Resize
  else
  let b = read_byte fd timeout in
  (* Check again after blocking — signal may have interrupted select *)
  if b < 0 && Term.check_resize () then Some Resize
  else
  if b < 0 then None
  else if b = 27 then begin
    (* ESC — peek ahead *)
    let next = read_byte fd 0.05 in
    if next < 0 then
      Some (Special (Escape, no_mod))
    else if next = Char.code '[' then
      Some (parse_csi fd)
    else if next = Char.code 'O' then
      Some (parse_ss3 fd)
    else begin
      (* Alt+key *)
      if next >= 0x80 then begin
        (* Alt + UTF-8 char *)
        let cp = read_utf8 fd next in
        Some (Key (cp, { no_mod with alt = true }))
      end else
        Some (Key (next, { no_mod with alt = true }))
    end
  end
  else if b < 32 then begin
    (* Control character *)
    match b with
    | 13 -> Some (Special (Enter, no_mod))
    | 10 -> Some (Special (Enter, no_mod))  (* some terminals send LF *)
    | 9 -> Some (Special (Tab, no_mod))
    | 8 -> Some (Special (Backspace, no_mod))
    | 127 -> Some (Special (Backspace, no_mod))
    | _ ->
      (* Ctrl+letter: ^A=1, ^B=2, ..., ^Z=26 *)
      let letter = b + 96 in  (* 1->97='a', etc. *)
      Some (Key (letter, { no_mod with ctrl = true }))
  end
  else if b = 127 then
    Some (Special (Backspace, no_mod))
  else begin
    (* Regular character — may be multi-byte UTF-8 *)
    let cp = read_utf8 fd b in
    Some (Key (cp, no_mod))
  end

(* Pretty-print an event for debugging *)
let show_event = function
  | Key (cp, m) ->
    let mod_s = (if m.ctrl then "C-" else "") ^
                (if m.alt then "M-" else "") ^
                (if m.shift then "S-" else "") in
    if cp >= 32 && cp < 127 then
      Printf.sprintf "%s'%c'" mod_s (Char.chr cp)
    else
      Printf.sprintf "%sU+%04X" mod_s cp
  | Special (k, m) ->
    let mod_s = (if m.ctrl then "C-" else "") ^
                (if m.alt then "M-" else "") ^
                (if m.shift then "S-" else "") in
    let name = match k with
      | Up -> "Up" | Down -> "Down" | Left -> "Left" | Right -> "Right"
      | Home -> "Home" | End -> "End" | PageUp -> "PgUp" | PageDown -> "PgDn"
      | Insert -> "Ins" | Delete -> "Del"
      | F n -> Printf.sprintf "F%d" n
      | Backspace -> "BS" | Tab -> "Tab" | Enter -> "Enter" | Escape -> "Esc"
    in
    mod_s ^ name
  | Mouse ev ->
    let btn = match ev.button with
      | Left -> "Left" | Middle -> "Middle" | Right -> "Right"
      | ScrollUp -> "ScrollUp" | ScrollDown -> "ScrollDown"
      | Release -> "Release"
    in
    Printf.sprintf "Mouse(%s,%d,%d)" btn ev.x ev.y
  | Paste s -> Printf.sprintf "Paste(%d bytes)" (String.length s)
  | Resize -> "Resize"
  | Unknown -> "Unknown"
