(* Embedded terminal: ties vterm + PTY together.
   Global terminals live in a shared list, rendered as message sub-tabs. *)

type t = {
  vterm : Vterm_lib.Vterm_api.t;
  pty : Vterm_lib.Pty.t;
  mutable title : string;
  mutable closed : bool;
  mutable exit_code : int option;
  mutable reported_buttons : int;  (* bitmask of buttons sent as press *)
  mutable cur_w : int;
  mutable cur_h : int;
}

(* Global terminal list *)
let terminals : t list ref = ref []

(* Clipboard callback: set by editor init. Called when child sends OSC 52. *)
let clipboard_hook : (string -> unit) ref = ref (fun _ -> ())
let set_clipboard_hook f = clipboard_hook := f

(* Find bundled terminfo directory relative to the executable.
   Covers three layouts:
   - dune exec:     _build/default/bin/main.exe     -> ../data/terminfo
   - opam install:  <switch>/bin/rocqtui            -> ../share/rocqtui/terminfo
   - ad hoc:        ./rocqtui with ./data alongside -> ./data/terminfo *)
let terminfo_dir =
  lazy begin
    let exe = Sys.executable_name in
    let bin_dir = Filename.dirname exe in
    let prefix = Filename.dirname bin_dir in
    let candidates = [
      Filename.concat prefix "share/rocqtui/terminfo";
      Filename.concat prefix "data/terminfo";
      Filename.concat bin_dir "data/terminfo";
    ] in
    List.find_opt Sys.file_exists candidates
  end

(* Sniff the parent environment to decide what color-capability env
   vars we should leak into the child. Only sets a var if the parent
   doesn't already have one.

   COLORTERM is truecolor-only by convention, so we only set it when
   the parent is a known-truecolor terminal. FORCE_COLOR is the
   Node/chalk convention (0=off, 1=16, 2=256, 3=truecolor) and is the
   most reliable way to reach tools that ignore terminfo — notably
   Claude Code, which is a Node app. *)
let color_env_additions () =
  let get k = try Some (Sys.getenv k) with Not_found -> None in
  let has k = get k <> None in
  let contains_substring hay needle =
    let lh = String.length hay and ln = String.length needle in
    let rec loop i =
      if i + ln > lh then false
      else if String.sub hay i ln = needle then true
      else loop (i + 1)
    in
    ln = 0 || loop 0
  in
  let term = match get "TERM" with Some s -> s | None -> "" in
  let term_256 = contains_substring term "256color" in
  let ends_with s suf =
    let ls = String.length s and lsuf = String.length suf in
    ls >= lsuf && String.sub s (ls - lsuf) lsuf = suf
  in
  (* TERM values that themselves imply truecolor. The *-direct
     convention is a terminfo standard for 24-bit color entries. *)
  let term_truecolor =
    ends_with term "-direct" ||
    (match term with
     | "xterm-kitty" | "wezterm" | "alacritty" | "xterm-ghostty"
     | "foot" | "contour" | "rio" -> true
     | _ -> false)
  in
  (* These env vars get stripped by SSH unless explicitly allowed, so
     they only help for local sessions. LC_TERMINAL rides the LC_*
     allowlist and does survive SSH. *)
  let truecolor_parent =
    term_truecolor ||
    has "KITTY_WINDOW_ID" ||
    has "ALACRITTY_WINDOW_ID" ||
    has "WEZTERM_EXECUTABLE" ||
    (match get "TERM_PROGRAM" with
     | Some ("iTerm.app" | "WezTerm" | "vscode" | "ghostty" | "Hyper") -> true
     | _ -> false) ||
    (match get "LC_TERMINAL" with
     | Some ("iTerm2" | "WezTerm") -> true
     | _ -> false)
  in
  let acc = [] in
  let acc =
    if has "COLORTERM" then acc
    else if truecolor_parent then ("COLORTERM", "truecolor") :: acc
    else acc
  in
  let acc =
    if has "FORCE_COLOR" then acc
    else if truecolor_parent then ("FORCE_COLOR", "3") :: acc
    else if term_256 then ("FORCE_COLOR", "2") :: acc
    else acc
  in
  acc

let create ?(cmd = "") ?(args = []) ?(env = []) ?(cwd = "") ~w ~h () =
  let cmd = if cmd = "" then
    (try Sys.getenv "SHELL" with Not_found -> "/bin/bash")
  else cmd in
  let env = ("TERM", "glterm") :: env in
  let env = match Lazy.force terminfo_dir with
    | Some path -> ("TERMINFO_DIRS", path) :: env
    | None -> env
  in
  let env = color_env_additions () @ env in
  let vterm = Vterm_lib.Vterm_api.create ~backlog:(32 * 1024 * 1024)
    ~fwdlog:(1024 * 1024) ~w ~h ~wrap_mode:1 in
  let pty = Vterm_lib.Pty.spawn ~cmd ~args ~env ~w ~h ~cwd () in
  let t = { vterm; pty; title = "Terminal"; closed = false;
            exit_code = None;
            reported_buttons = 0;
            cur_w = w; cur_h = h } in
  terminals := !terminals @ [t];
  t

let destroy t =
  terminals := List.filter (fun t' -> t' != t) !terminals;
  Vterm_lib.Pty.close t.pty;
  Vterm_lib.Vterm_api.destroy t.vterm

let all () = !terminals

let fds () =
  List.filter_map (fun t ->
    if t.closed then None
    else Some (Vterm_lib.Pty.fd t.pty, t)
  ) !terminals

let poll t =
  if t.closed then false
  else begin
    let buf = Bytes.create 4096 in
    let changed = ref false in
    let rec drain () =
      let n = Vterm_lib.Pty.read t.pty buf 0 4096 in
      if n > 0 then begin
        Vterm_lib.Vterm_api.proc t.vterm buf ~off:0 ~len:n;
        changed := true;
        drain ()
      end else if n = 0 && !changed then
        (* Could be EAGAIN after reading some data — that's fine *)
        ()
      else ()
    in
    (try drain ()
     with Unix.Unix_error _ -> ());
    if !changed then begin
      let out = Vterm_lib.Vterm_api.sync t.vterm in
      (* Write feedback to PTY *)
      (match out.feedback with
       | Some fb -> Vterm_lib.Pty.write t.pty (Bytes.to_string fb)
       | None -> ());
      (* Update title *)
      (match out.title with
       | Some name -> t.title <- name
       | None -> ());
      (* Clipboard: OSC 52 from child *)
      (match out.clipboard with
       | Some text -> !clipboard_hook text
       | None -> ())
    end;
    (* Check if child exited *)
    if not t.closed then begin
      match Unix.waitpid [WNOHANG] (Vterm_lib.Pty.pid t.pty) with
      | (pid, status) when pid > 0 ->
        t.closed <- true;
        t.exit_code <- (match status with
          | Unix.WEXITED code -> Some code
          | Unix.WSIGNALED _ -> Some (-1)
          | Unix.WSTOPPED _ -> None)
      | _ -> ()
      | exception Unix.Unix_error _ -> ()
    end;
    !changed
  end

let resize t ~w ~h =
  if not t.closed && w > 0 && h > 0
     && (w <> t.cur_w || h <> t.cur_h) then begin
    t.cur_w <- w;
    t.cur_h <- h;
    Vterm_lib.Vterm_api.resize t.vterm ~w ~h;
    Vterm_lib.Pty.set_size t.pty ~w ~h
  end

(* Copy a vterm's display into a grid region. Takes the vterm directly
   (rather than a [t]) so the transparency test can drive it without a
   PTY behind it. *)
let render_vterm vterm (grid : Grid.t) ~row ~col ~width ~height =
  if width <= 0 || height <= 0 then () else
  let nrows = Vterm_lib.Vterm_api.prepare_rows vterm in
  for y = 0 to min nrows height - 1 do
    let cells = Vterm_lib.Vterm_api.get_row vterm y in
    let sentinel = Vterm_lib.Vterm_api.get_row_sentinel vterm y in
    let grid_row = row + y in
    if grid_row < grid.rows then begin
      (* Render cells *)
      let x = ref 0 in
      (* Track the most recently written wide/normal cell so width=0
         cells (combining marks, ZWJ emoji clusters, RI flag pairs)
         can append to the actual leader rather than the right-half
         continuation slot of a wide char — those get skipped on emit. *)
      let leader_gc = ref (-1) in
      Array.iter (fun (cell : Vterm_lib.Vterm_api.row_cell) ->
        let gc = col + !x in
        if cell.width = 0 then begin
          let target = if !leader_gc >= 0 then !leader_gc else gc - 1 in
          if target >= col && target < grid.cols then begin
            let base = (Obj.magic cell.attr : Grid.attr) in
            let attr =
              if cell.selected then { base with reverse = not base.reverse }
              else base
            in
            Grid.append_combining grid ~row:grid_row ~col:target ~attr cell.text
          end
        end else if gc < col + width && gc < grid.cols then begin
          let base = (Obj.magic cell.attr : Grid.attr) in
          let attr =
            if cell.selected then { base with reverse = not base.reverse }
            else base
          in
          (* vterm encodes tabs as a single cell with code=ENC_TAB
             (16, see term.h) and dynamic width 1..8 that pads to the
             next multiple of 8. Expand into [cell.width] single-space
             cells so the host cursor advances correctly and stale
             grid content doesn't show through. *)
          let is_tab =
            String.length cell.text = 1 && cell.text.[0] = '\x10'
          in
          if is_tab then begin
            for i = 0 to cell.width - 1 do
              let cgc = gc + i in
              if cgc < col + width && cgc < grid.cols then begin
                let cc = grid.cells.(grid_row).(cgc) in
                cc.text <- " ";
                cc.width <- 1;
                cc.attr <- attr
              end
            done;
            (* Last expanded space is the leader for any trailing followers. *)
            leader_gc := min (gc + cell.width - 1) (grid.cols - 1)
          end else begin
            let grid_cell = grid.cells.(grid_row).(gc) in
            grid_cell.text <- cell.text;
            grid_cell.width <- cell.width;
            grid_cell.attr <- attr;
            grid_cell.followers <- [];
            (* Wide char: mark continuation cell *)
            if cell.width = 2 && gc + 1 < col + width && gc + 1 < grid.cols then begin
              let next = grid.cells.(grid_row).(gc + 1) in
              next.text <- "";
              next.width <- 0;
              next.attr <- attr;
              next.followers <- []
            end;
            leader_gc := gc
          end;
          x := !x + cell.width
        end
      ) cells;
      (* Fill trailing blank from sentinel *)
      let end_x = !x in
      let (bg_base, sentinel_selected) = match sentinel with
        | Some (attr, _, sel) -> ((Obj.magic attr : Grid.attr), sel)
        | None -> (Grid.default_attr, false)
      in
      let bg_attr =
        if sentinel_selected then { bg_base with reverse = not bg_base.reverse }
        else bg_base
      in
      for c = end_x to width - 1 do
        let gc = col + c in
        if gc < grid.cols then begin
          let grid_cell = grid.cells.(grid_row).(gc) in
          grid_cell.text <- " ";
          grid_cell.width <- 1;
          grid_cell.attr <- bg_attr
        end
      done
    end
  done

let render t grid ~row ~col ~width ~height =
  render_vterm t.vterm grid ~row ~col ~width ~height

let title t =
  if t.closed then
    match t.exit_code with
    | Some code -> Printf.sprintf "%s (exited %d)" t.title code
    | None -> t.title ^ " (closed)"
  else t.title

let is_closed t = t.closed
let vterm t = t.vterm
let pty t = t.pty
let reported_buttons t = t.reported_buttons
let set_reported_buttons t v = t.reported_buttons <- v

let send t s =
  if String.length s > 0 then begin
    if Vterm_lib.Vterm_api.is_scrolled t.vterm then
      ignore (Vterm_lib.Vterm_api.scroll_to_end t.vterm false);
    Vterm_lib.Pty.write t.pty s
  end
