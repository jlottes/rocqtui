(* Terminal input parser.
   A push-based state machine: raw bytes are fed in via [feed] (in
   whatever chunks the OS delivers them) and complete events are drained
   via [next_event]. State persists across [feed] calls, so a sequence
   split across read boundaries — a bracketed-paste marker, a CSI escape,
   a multi-byte UTF-8 codepoint — is parsed correctly regardless of where
   the chunk boundary falls. This is the same model as the embedded
   terminal's [Vterm_api.proc].

   The single timing-sensitive decision — a lone ESC keypress vs. the
   start of an escape sequence — is NOT made here. The parser holds in
   the [Esc] state emitting nothing; the event loop resolves it by
   calling [flush] when its select cycle goes idle (see [pending]). Every
   other multi-byte sequence is machine-emitted and arrives in full, so
   those states simply wait for bytes and never time out. This is the
   only residual exposure to a slow link splitting an ESC from its
   following bytes — inherent to legacy (non-kitty) terminals, and far
   narrower than the old per-byte read timeouts. *)

type modifier = {
  shift : bool;
  alt : bool;
  ctrl : bool;
  super : bool;
}

let no_mod = { shift = false; alt = false; ctrl = false; super = false }
let alt_mod = { no_mod with alt = true }

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

let debug_log : (string -> unit) option ref = ref None
let set_debug_log f = debug_log := Some f
let log msg = match !debug_log with Some f -> f msg | None -> ()

(* Parse CSI parameters: semicolon-separated integers. *)
let parse_params s =
  let parts = String.split_on_char ';' s in
  List.map (fun p ->
    match String.split_on_char ':' p with
    | n :: _ -> (match int_of_string_opt n with Some v -> v | None -> 0)
    | [] -> 0
  ) parts

let mods_from p = if p > 1 then modifier_of_param p else no_mod

(* UTF-8 continuation-byte count implied by a lead byte (0 if [b] is not
   a valid multi-byte lead). *)
let utf8_need b =
  if b < 0xC0 then 0
  else if b < 0xE0 then 1
  else if b < 0xF0 then 2
  else 3

(* ---- State machine ---- *)

type state =
  | Ground
  | Esc                         (* saw ESC, awaiting next byte or flush *)
  | Csi                         (* ESC [ … , accumulating into [csi] *)
  | Ss3                         (* ESC O … *)
  | Utf8 of int * int * bool    (* acc, remaining continuation bytes, alt *)
  | Mouse_x10 of int list       (* X10 mouse: bytes collected, reversed *)
  | Paste_body                  (* inside ESC[200~ … , accumulating [paste] *)
  | Paste_esc                   (* saw ESC inside paste body *)
  | Paste_esc_csi               (* accumulating a 201~ candidate into [csi] *)

type t = {
  mutable state : state;
  csi : Stdlib.Buffer.t;        (* CSI params / 201~ candidate *)
  paste : Stdlib.Buffer.t;      (* bracketed-paste body *)
  queue : event Queue.t;
  readbuf : bytes;              (* scratch for [read_available]/[read_event] *)
}

let create () = {
  state = Ground;
  csi = Stdlib.Buffer.create 16;
  paste = Stdlib.Buffer.create 256;
  queue = Queue.create ();
  readbuf = Bytes.create 4096;
}

let emit t ev =
  log (Printf.sprintf "input: emit %s"
         (match ev with
          | Paste s -> Printf.sprintf "Paste(%d)" (String.length s)
          | _ -> "ev"));
  Queue.add ev t.queue

(* Dispatch a complete CSI sequence: [params] is the bytes between
   "ESC [" and the [final] byte (0x40-0x7E). Sets [t.state]. *)
let dispatch_csi t params final =
  t.state <- Ground;
  let c = Char.chr final in
  let is_sgr_mouse =
    (c = 'M' || c = 'm') && String.length params > 0 && params.[0] = '<' in
  if is_sgr_mouse then begin
    let is_release = (c = 'm') in
    let body = String.sub params 1 (String.length params - 1) in
    match String.split_on_char ';' body with
    | [btn_s; x_s; y_s] ->
      let btn = (match int_of_string_opt btn_s with Some n -> n | None -> 0) in
      let x = (match int_of_string_opt x_s with Some n -> n - 1 | None -> 0) in
      let y = (match int_of_string_opt y_s with Some n -> n - 1 | None -> 0) in
      let button =
        if btn land 64 <> 0 then
          (if btn land 1 <> 0 then ScrollDown else ScrollUp)
        else if is_release then Release
        else (match btn land 3 with
              | 0 -> Left | 1 -> Middle | 2 -> Right | _ -> Left) in
      let mods = { shift = btn land 4 <> 0; alt = btn land 8 <> 0;
                   ctrl = btn land 16 <> 0; super = false } in
      emit t (Mouse { button; x; y; mods })
    | _ -> emit t Unknown
  end
  else if c = 'M' then
    (* X10 mouse — three raw bytes follow. *)
    t.state <- Mouse_x10 []
  else begin
    let plist = parse_params params in
    let arrow_mods = match plist with _ :: p :: _ -> mods_from p | _ -> no_mod in
    match c with
    | 'A' -> emit t (Special (Up, arrow_mods))
    | 'B' -> emit t (Special (Down, arrow_mods))
    | 'C' -> emit t (Special (Right, arrow_mods))
    | 'D' -> emit t (Special (Left, arrow_mods))
    | 'H' -> emit t (Special (Home, arrow_mods))
    | 'F' -> emit t (Special (End, arrow_mods))
    | 'P' -> emit t (Special (F 1, arrow_mods))
    | 'Q' -> emit t (Special (F 2, arrow_mods))
    | 'R' -> emit t (Special (F 3, arrow_mods))
    | 'S' -> emit t (Special (F 4, arrow_mods))
    | 'Z' -> emit t (Special (Tab, { no_mod with shift = true }))
    | '~' ->
      let key_num = match plist with n :: _ -> n | [] -> 0 in
      let m = arrow_mods in
      (match key_num with
       | 2 -> emit t (Special (Insert, m))
       | 3 -> emit t (Special (Delete, m))
       | 5 -> emit t (Special (PageUp, m))
       | 6 -> emit t (Special (PageDown, m))
       | 11 -> emit t (Special (F 1, m))
       | 12 -> emit t (Special (F 2, m))
       | 13 -> emit t (Special (F 3, m))
       | 14 -> emit t (Special (F 4, m))
       | 15 -> emit t (Special (F 5, m))
       | 17 -> emit t (Special (F 6, m))
       | 18 -> emit t (Special (F 7, m))
       | 19 -> emit t (Special (F 8, m))
       | 20 -> emit t (Special (F 9, m))
       | 21 -> emit t (Special (F 10, m))
       | 23 -> emit t (Special (F 11, m))
       | 24 -> emit t (Special (F 12, m))
       | 200 ->
         (* Bracketed-paste start. *)
         Stdlib.Buffer.clear t.paste;
         t.state <- Paste_body
       | _ -> emit t Unknown)
    | 'u' ->
      (* Kitty keyboard protocol: CSI keycode ; mods u *)
      let keycode = match plist with n :: _ -> n | [] -> 0 in
      let m = arrow_mods in
      (match keycode with
       | 13 -> emit t (Special (Enter, m))
       | 9 -> emit t (Special (Tab, m))
       | 27 -> emit t (Special (Escape, m))
       | 127 -> emit t (Special (Backspace, m))
       | 57352 -> emit t (Special (Up, m))
       | 57353 -> emit t (Special (Down, m))
       | 57354 -> emit t (Special (Right, m))
       | 57355 -> emit t (Special (Left, m))
       | 57358 -> emit t (Special (Insert, m))
       | 57359 -> emit t (Special (Delete, m))
       | 57360 -> emit t (Special (Home, m))
       | 57361 -> emit t (Special (End, m))
       | 57362 -> emit t (Special (PageUp, m))
       | 57363 -> emit t (Special (PageDown, m))
       | n when n >= 57364 && n <= 57375 -> emit t (Special (F (n - 57364 + 1), m))
       | n -> emit t (Key (n, m)))
    | _ -> emit t Unknown
  end

let dispatch_ss3 t b =
  t.state <- Ground;
  match Char.chr b with
  | 'P' -> emit t (Special (F 1, no_mod))
  | 'Q' -> emit t (Special (F 2, no_mod))
  | 'R' -> emit t (Special (F 3, no_mod))
  | 'S' -> emit t (Special (F 4, no_mod))
  | 'A' -> emit t (Special (Up, no_mod))
  | 'B' -> emit t (Special (Down, no_mod))
  | 'C' -> emit t (Special (Right, no_mod))
  | 'D' -> emit t (Special (Left, no_mod))
  | 'H' -> emit t (Special (Home, no_mod))
  | 'F' -> emit t (Special (End, no_mod))
  | _ -> emit t Unknown

(* Feed one byte through the state machine. *)
let rec feed_byte t b =
  match t.state with
  | Ground ->
    if b = 27 then t.state <- Esc
    else if b < 32 then
      (match b with
       | 13 -> emit t (Special (Enter, no_mod))
       | 10 -> emit t (Special (Enter, { no_mod with shift = true }))
       | 9 -> emit t (Special (Tab, no_mod))
       | 8 -> emit t (Special (Backspace, no_mod))
       | _ -> emit t (Key (b + 96, { no_mod with ctrl = true })))
    else if b = 127 then emit t (Special (Backspace, no_mod))
    else if b < 0x80 then emit t (Key (b, no_mod))
    else begin
      let need = utf8_need b in
      if need = 0 then emit t (Key (b, no_mod))
      else t.state <- Utf8 (b land (0x7F lsr need), need, false)
    end
  | Esc ->
    if b = Char.code '[' then (Stdlib.Buffer.clear t.csi; t.state <- Csi)
    else if b = Char.code 'O' then t.state <- Ss3
    else if b >= 0x80 then begin
      let need = utf8_need b in
      if need = 0 then (emit t (Key (b, alt_mod)); t.state <- Ground)
      else t.state <- Utf8 (b land (0x7F lsr need), need, true)
    end
    else (emit t (Key (b, alt_mod)); t.state <- Ground)
  | Csi ->
    if b >= 0x40 && b <= 0x7E then
      dispatch_csi t (Stdlib.Buffer.contents t.csi) b
    else if b >= 0x20 && b <= 0x3F then
      Stdlib.Buffer.add_char t.csi (Char.chr b)
    else
      (* Malformed (e.g. an embedded ESC) — abandon the partial sequence
         and reprocess this byte from Ground. *)
      (t.state <- Ground; feed_byte t b)
  | Ss3 -> dispatch_ss3 t b
  | Utf8 (acc, need, alt) ->
    if b >= 0x80 && b < 0xC0 then begin
      let acc = (acc lsl 6) lor (b land 0x3F) in
      if need = 1 then
        (emit t (Key (acc, if alt then alt_mod else no_mod)); t.state <- Ground)
      else t.state <- Utf8 (acc, need - 1, alt)
    end else begin
      (* Truncated codepoint — emit replacement and reprocess this byte. *)
      emit t (Key (0xFFFD, if alt then alt_mod else no_mod));
      t.state <- Ground; feed_byte t b
    end
  | Mouse_x10 bytes ->
    let bytes = b :: bytes in
    if List.length bytes >= 3 then begin
      t.state <- Ground;
      (match List.rev bytes with
       | cb :: cx :: cy :: _ ->
         let btn = cb - 32 in
         let x = cx - 33 in
         let y = cy - 33 in
         let button = match btn land 3 with
           | 0 -> Left | 1 -> Middle | 2 -> Right | 3 -> Release | _ -> Left in
         let button = if btn land 64 <> 0 then
           (if btn land 1 <> 0 then ScrollDown else ScrollUp) else button in
         let mods = { shift = btn land 4 <> 0; alt = btn land 8 <> 0;
                      ctrl = btn land 16 <> 0; super = false } in
         emit t (Mouse { button; x; y; mods })
       | _ -> emit t Unknown)
    end else t.state <- Mouse_x10 bytes
  | Paste_body ->
    if b = 27 then t.state <- Paste_esc
    else Stdlib.Buffer.add_char t.paste (Char.chr b)
  | Paste_esc ->
    if b = Char.code '[' then (Stdlib.Buffer.clear t.csi; t.state <- Paste_esc_csi)
    else begin
      (* The ESC was literal paste content. *)
      Stdlib.Buffer.add_char t.paste '\x1b';
      if b = 27 then ()  (* a fresh ESC — stay pending *)
      else (Stdlib.Buffer.add_char t.paste (Char.chr b); t.state <- Paste_body)
    end
  | Paste_esc_csi ->
    if b >= 0x40 && b <= 0x7E then begin
      if Stdlib.Buffer.contents t.csi = "201" && b = Char.code '~' then begin
        emit t (Paste (Stdlib.Buffer.contents t.paste));
        Stdlib.Buffer.clear t.paste;
        t.state <- Ground
      end else begin
        (* Not the terminator — fold the ESC[…<final> back into the body. *)
        Stdlib.Buffer.add_char t.paste '\x1b';
        Stdlib.Buffer.add_char t.paste '[';
        Stdlib.Buffer.add_buffer t.paste t.csi;
        Stdlib.Buffer.add_char t.paste (Char.chr b);
        t.state <- Paste_body
      end
    end else
      Stdlib.Buffer.add_char t.csi (Char.chr b)

let feed t bytes ~off ~len =
  for i = off to off + len - 1 do
    feed_byte t (Char.code (Bytes.get bytes i))
  done

let next_event t = Queue.take_opt t.queue

let pending t = t.state = Esc

let flush t =
  if t.state = Esc then begin
    emit t (Special (Escape, no_mod));
    t.state <- Ground
  end

let any_queued t pred = Queue.fold (fun acc e -> acc || pred e) false t.queue

(* Read whatever bytes are immediately available (non-blocking) and feed
   them into the parser. Returns the number of bytes fed. *)
let read_available t fd =
  let total = ref 0 in
  let continue = ref true in
  while !continue do
    let ready =
      try let r, _, _ = Unix.select [fd] [] [] 0.0 in r <> []
      with Unix.Unix_error (Unix.EINTR, _, _) -> false | _ -> false in
    if not ready then continue := false
    else begin
      let n =
        try Unix.read fd t.readbuf 0 (Bytes.length t.readbuf)
        with Unix.Unix_error (Unix.EINTR, _, _) -> 0 | _ -> 0 in
      if n <= 0 then continue := false
      else (feed t t.readbuf ~off:0 ~len:n; total := !total + n)
    end
  done;
  !total

(* Blocking convenience for standalone tools: drain a queued event, else
   block on [fd] up to [timeout] (negative = forever), feed, and resolve
   a lone ESC on timeout. *)
let rec read_event ?(timeout=(-1.0)) t fd =
  match next_event t with
  | Some _ as e -> e
  | None ->
    let ready =
      try let r, _, _ = Unix.select [fd] [] [] timeout in r
      with Unix.Unix_error (Unix.EINTR, _, _) -> [] | _ -> [] in
    if ready = [] then
      (if pending t then (flush t; next_event t) else None)
    else begin
      let n =
        try Unix.read fd t.readbuf 0 (Bytes.length t.readbuf)
        with _ -> 0 in
      if n <= 0 then None
      else begin
        feed t t.readbuf ~off:0 ~len:n;
        match next_event t with
        | Some _ as e -> e
        | None -> read_event ~timeout t fd
      end
    end

(* Pretty-print an event for debugging. *)
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
