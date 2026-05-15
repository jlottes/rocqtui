(* NDJSON Unix-socket client for the AI bridge.

   One request per connection. On send: open, write the request line,
   half-close write, register an fd watch with the main loop. As
   response lines arrive, parse and dispatch via the response handler.

   The handle returned by [send] can be canceled — closes the socket
   which causes the bridge to abort the upstream llama-server request. *)

type response =
  | Fim of { insertion : string }
  | Edit of {
      start_line : int;
      start_col : int;
      end_line : int;
      end_col : int;
      replacement : string;
    }
  | Error_resp of { message : string; code : string }
  | Done_resp

type t = {
  mutable fd : Unix.file_descr option;
  mutable watch : Main_loop.watch_id option;
}

let parse_line line : response option =
  match Yojson.Basic.from_string line with
  | j ->
    let open Yojson.Basic.Util in
    (try
       let typ = j |> member "type" |> to_string in
       match typ with
       | "done" -> Some Done_resp
       | "fim" ->
         Some (Fim { insertion = j |> member "insertion" |> to_string })
       | "edit" ->
         let c = j |> member "change" in
         let r = c |> member "range" in
         Some (Edit {
           start_line = r |> member "start_line" |> to_int;
           start_col = r |> member "start_col" |> to_int;
           end_line = r |> member "end_line" |> to_int;
           end_col = r |> member "end_col" |> to_int;
           replacement = c |> member "replacement" |> to_string;
         })
       | "error" ->
         let msg = j |> member "message" |> to_string in
         let code = try j |> member "code" |> to_string with _ -> "internal" in
         Some (Error_resp { message = msg; code })
       | _ -> None
     with _ -> None)
  | exception _ -> None

(* Build the request JSON from raw values. [shape] hints to the
   bridge which response shape to produce ("fim" / "edits" / "auto").
   Defaults to "auto" — bridge picks via its heuristic. *)
let build_request ?(shape="auto") ~req_id ~buffer
    ~cursor_line ~cursor_col ~recent_edits () =
  let edits_json =
    `List (List.map (fun (before, after) ->
      `Assoc [ ("before", `String before); ("after", `String after) ]
    ) recent_edits)
  in
  `Assoc [
    ("req_id", `String req_id);
    ("kind", `String "suggest");
    ("shape", `String shape);
    ("buffer", `String buffer);
    ("cursor", `Assoc [
       ("line", `Int cursor_line);
       ("col", `Int cursor_col);
     ]);
    ("language", `String "rocq");
    ("recent_edits", edits_json);
  ]

let cancel t =
  (match t.watch with
   | Some wid -> Main_loop.remove_watch wid; t.watch <- None
   | None -> ());
  (match t.fd with
   | Some fd -> (try Unix.close fd with _ -> ()); t.fd <- None
   | None -> ())

let send ~socket_path ~request ~on_response =
  let sock =
    try
      let s = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Unix.connect s (Unix.ADDR_UNIX socket_path);
      Some s
    with _ -> None
  in
  match sock with
  | None ->
    on_response (Error_resp { message = "bridge unreachable";
                              code = "backend_unreachable" });
    on_response Done_resp;
    None
  | Some sock ->
    let line = (Yojson.Basic.to_string request) ^ "\n" in
    (try ignore (Unix.write_substring sock line 0 (String.length line))
     with _ -> ());
    (try Unix.shutdown sock Unix.SHUTDOWN_SEND with _ -> ());
    Unix.set_nonblock sock;
    let t = { fd = Some sock; watch = None } in
    let line_buf = Stdlib.Buffer.create 1024 in
    let saw_done = ref false in
    let dispatch line =
      match parse_line line with
      | Some Done_resp -> saw_done := true; on_response Done_resp
      | Some r -> on_response r
      | None -> ()
    in
    let process_buffer () =
      let s = Stdlib.Buffer.contents line_buf in
      let len = String.length s in
      let i = ref 0 in
      let last_nl = ref (-1) in
      let continue = ref true in
      while !continue && !i < len do
        match String.index_from_opt s !i '\n' with
        | Some nl ->
          dispatch (String.sub s !i (nl - !i));
          last_nl := nl;
          i := nl + 1
        | None -> continue := false
      done;
      if !last_nl >= 0 then begin
        let tail = String.sub s (!last_nl + 1) (len - !last_nl - 1) in
        Stdlib.Buffer.clear line_buf;
        Stdlib.Buffer.add_string line_buf tail
      end
    in
    let callback _conditions =
      let bytes = Bytes.create 4096 in
      let alive = ref true in
      let continue = ref true in
      let got_something = ref false in
      while !continue do
        match Unix.read sock bytes 0 4096 with
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          continue := false
        | exception _ ->
          if not !saw_done then
            on_response (Error_resp { message = "read error";
                                       code = "internal" });
          on_response Done_resp;
          got_something := true;
          continue := false;
          alive := false
        | 0 ->
          (* EOF — flush trailing buffered text if any *)
          let tail = Stdlib.Buffer.contents line_buf in
          if String.length (String.trim tail) > 0 then
            (match parse_line tail with
             | Some r -> on_response r
             | None -> ());
          if not !saw_done then on_response Done_resp;
          got_something := true;
          continue := false;
          alive := false
        | n ->
          got_something := true;
          Stdlib.Buffer.add_subbytes line_buf bytes 0 n;
          process_buffer ()
      done;
      if not !alive then begin
        (* Don't call cancel here — we'd remove ourselves from the
           watch list while iterating it. Returning false signals the
           main loop to remove the watch; we close the fd ourselves. *)
        (match t.fd with
         | Some fd -> (try Unix.close fd with _ -> ()); t.fd <- None
         | None -> ());
        t.watch <- None
      end;
      (* Async data arrived (or the request completed): the main loop
         doesn't know to re-render just because a watch callback fired,
         so we ask explicitly. Without this the status indicator and
         ghost text stay stale until the next user input. *)
      if !got_something then Render_need.request ();
      !alive
    in
    let wid = Main_loop.add_watch ~callback sock in
    t.watch <- Some wid;
    Some t
