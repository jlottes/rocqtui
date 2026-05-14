let match_binding (ev : Input.event) (b : Keys.binding) =
  match ev with
  | Input.Key (cp, mods) ->
    (* Ctrl+letter: cp is the letter, mods.ctrl is true *)
    let kitty_match () =
      let modifier = 1
        + (if mods.shift then 1 else 0)
        + (if mods.alt then 2 else 0)
        + (if mods.ctrl then 4 else 0) in
      List.exists (fun (kc, m) -> kc = cp && m = modifier) b.kitty_codes
    in
    if mods.ctrl && not mods.alt && not mods.shift then begin
      let ctrl_code = if cp >= 97 && cp <= 122 then cp - 96
                      else if cp >= 65 && cp <= 90 then cp - 64
                      else -1 in
      if ctrl_code > 0 then List.mem ctrl_code b.codes || kitty_match ()
      else List.mem cp b.codes || kitty_match ()
    end
    else if not mods.ctrl && not mods.alt && not mods.shift then
      List.mem cp b.codes
    else kitty_match ()
  | Input.Special (key, mods) ->
    (* Map special keys to legacy codes for binding matching *)
    let modifier = 1
      + (if mods.shift then 1 else 0)
      + (if mods.alt then 2 else 0)
      + (if mods.ctrl then 4 else 0) in
    let base_code = match key with
      | Input.Up -> Some 259 | Input.Down -> Some 258
      | Input.Right -> Some 261 | Input.Left -> Some 260
      | Input.Home -> Some 262 | Input.End -> Some 360
      | Input.PageUp -> Some 339 | Input.PageDown -> Some 338
      | Input.Insert -> Some 331 | Input.Delete -> Some 330
      | Input.F n -> Some (264 + n)  (* F1=265, F2=266 etc. *)
      | Input.Backspace -> Some 127
      | Input.Tab -> Some 9
      | Input.Enter -> Some 13
      | Input.Escape -> None  (* Escape handled separately *)
    in
    (match base_code with
     | Some code ->
       if modifier = 1 then List.mem code b.codes
       else
         List.exists (fun (kc, m) ->
           kc = code && m = modifier) b.kitty_codes
     | None -> false)
  | _ -> false

let codepoint_of_event = function
  | Input.Key (cp, _) -> Some cp
  | Input.Special (Input.Tab, _) -> Some 9
  | Input.Special (Input.Enter, _) -> Some 13
  | Input.Special (Input.Backspace, _) -> Some 127
  | Input.Special (Input.Escape, _) -> Some 27
  | _ -> None
