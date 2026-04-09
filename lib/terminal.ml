(* Embedded terminal: ties vterm + PTY together.
   Global terminals live in a shared list, rendered as message sub-tabs. *)

type t = {
  vterm : Vterm_lib.Vterm_api.t;
  pty : Vterm_lib.Pty.t;
  mutable title : string;
  mutable closed : bool;
  mutable exit_code : int option;
  mutable reported_buttons : int;  (* bitmask of buttons sent as press *)
}

(* Global terminal list *)
let terminals : t list ref = ref []

let create ?(cmd = "") ?(args = []) ?(env = []) ~w ~h () =
  let cmd = if cmd = "" then
    (try Sys.getenv "SHELL" with Not_found -> "/bin/bash")
  else cmd in
  let env = ("TERM", "glterm") :: env in
  let vterm = Vterm_lib.Vterm_api.create ~backlog:(32 * 1024 * 1024)
    ~fwdlog:(1024 * 1024) ~w ~h ~wrap_mode:0 in
  let pty = Vterm_lib.Pty.spawn ~cmd ~args ~env ~w ~h in
  let t = { vterm; pty; title = "Terminal"; closed = false;
            exit_code = None;
            reported_buttons = 0 } in
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
      (* TODO: clipboard, mouse_changed *)
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
  if not t.closed then begin
    Vterm_lib.Vterm_api.resize t.vterm ~w ~h;
    Vterm_lib.Pty.set_size t.pty ~w ~h
  end

let render t (grid : Grid.t) ~row ~col ~width ~height =
  let nrows = Vterm_lib.Vterm_api.prepare_rows t.vterm in
  for y = 0 to min nrows height - 1 do
    let cells = Vterm_lib.Vterm_api.get_row t.vterm y in
    let sentinel = Vterm_lib.Vterm_api.get_row_sentinel t.vterm y in
    let grid_row = row + y in
    if grid_row < grid.rows then begin
      (* Render cells *)
      let x = ref 0 in
      Array.iter (fun (cell : Vterm_lib.Vterm_api.row_cell) ->
        let gc = col + !x in
        if gc < col + width && gc < grid.cols then begin
          let grid_cell = grid.cells.(grid_row).(gc) in
          grid_cell.text <- cell.text;
          grid_cell.width <- cell.width;
          grid_cell.attr <- (Obj.magic cell.attr : Grid.attr)
        end;
        x := !x + cell.width
      ) cells;
      (* Fill trailing blank from sentinel *)
      let end_x = !x in
      let bg_attr = match sentinel with
        | Some (attr, _) -> (Obj.magic attr : Grid.attr)
        | None -> Grid.default_attr
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
