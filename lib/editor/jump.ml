let push (ctx : Editor_context.t) (tab : Tab.t) =
  let (line, col) = Buffer.cursor tab.buf in
  let file = match Buffer.filename tab.buf with
    | Some f -> f | None -> "" in
  ctx.jump_stack <- { Editor_context.jp_tab_id = tab.id; jp_file = file;
                      jp_line = line; jp_col = col } :: ctx.jump_stack

let pop (ctx : Editor_context.t) =
  match ctx.jump_stack with
  | [] -> None
  | jp :: rest ->
    ctx.jump_stack <- rest;
    Some jp
