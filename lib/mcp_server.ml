(* MCP server for rocqtui.
   Implements JSON-RPC 2.0 over Unix socket.
   Exposes IDE state as MCP resources and operations as MCP tools. *)

type client = {
  fd : Unix.file_descr;
  mutable buf : string;  (* accumulated input *)
  mutable initialized : bool;
}

type t = {
  server_fd : Unix.file_descr;
  path : string;
  mutable clients : client list;
  mutable active_tab_ids : int list;  (* tab IDs Claude is working on *)
  mutable spinner_frame : int;
}

let spinner_chars = [| "·"; "✶"; "✢"; "✻" |]

let spinner_char t =
  t.spinner_frame <- (t.spinner_frame + 1) mod Array.length spinner_chars;
  spinner_chars.(t.spinner_frame)

let is_tab_active t idx = List.mem idx t.active_tab_ids

let mark_tab_active t idx =
  if not (List.mem idx t.active_tab_ids) then
    t.active_tab_ids <- idx :: t.active_tab_ids

let [@warning "-32"] unmark_tab_active t idx =
  t.active_tab_ids <- List.filter (fun i -> i <> idx) t.active_tab_ids

(* --- JSON-RPC helpers --- *)

let json_error id code msg =
  `Assoc [
    "jsonrpc", `String "2.0";
    "id", id;
    "error", `Assoc [
      "code", `Int code;
      "message", `String msg;
    ]
  ]

let json_result id result =
  `Assoc [
    "jsonrpc", `String "2.0";
    "id", id;
    "result", result;
  ]

let json_notification method_ params =
  `Assoc [
    "jsonrpc", `String "2.0";
    "method", `String method_;
    "params", params;
  ]

(* --- MCP Protocol --- *)

let server_info = `Assoc [
  "name", `String "rocqtui";
  "version", `String "0.1.0";
]

let capabilities = `Assoc [
  "tools", `Assoc [];
  "resources", `Assoc [];
]

let tool_defs = [
  ("step_forward", "Advance the target by one sentence",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [];
   ]);
  ("step_backward", "Retract the target by one sentence",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [];
   ]);
  ("go_to_end", "Set target to end of file",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [];
   ]);
  ("insert_text", "Insert text at a byte offset in the buffer",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "offset", `Assoc ["type", `String "integer"; "description", `String "byte offset"];
       "text", `Assoc ["type", `String "string"];
     ];
     "required", `List [`String "offset"; `String "text"];
   ]);
  ("replace_range", "Replace text between two byte offsets",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "start", `Assoc ["type", `String "integer"];
       "end", `Assoc ["type", `String "integer"];
       "text", `Assoc ["type", `String "string"];
     ];
     "required", `List [`String "start"; `String "end"; `String "text"];
   ]);
  ("move_cursor", "Move the cursor to a position",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "line", `Assoc ["type", `String "integer"; "description", `String "0-based line"];
       "col", `Assoc ["type", `String "integer"; "description", `String "0-based byte column"];
     ];
     "required", `List [`String "line"; `String "col"];
   ]);
  ("query", "Run a Rocq query (e.g. 'About nat.', 'Print plus.')",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "command", `Assoc ["type", `String "string"];
       "options", `Assoc [
         "type", `String "object";
         "description", `String "Temporary printing options to set before the query. Restored after.";
         "properties", `Assoc [
           "implicit", `Assoc ["type", `String "boolean"];
           "all", `Assoc ["type", `String "boolean"];
           "notations", `Assoc ["type", `String "boolean"];
           "coercions", `Assoc ["type", `String "boolean"];
           "universes", `Assoc ["type", `String "boolean"];
           "existential", `Assoc ["type", `String "boolean"];
         ];
       ];
     ];
     "required", `List [`String "command"];
   ]);
  ("interrupt", "Send interrupt (SIGINT) to rocqtop",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [];
   ]);
  ("save", "Save the current file",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [];
   ]);
  ("get_goals", "Get current goals with custom printing options",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "options", `Assoc [
         "type", `String "object";
         "description", `String "Printing options for this query";
         "properties", `Assoc [
           "implicit", `Assoc ["type", `String "boolean"];
           "all", `Assoc ["type", `String "boolean"];
           "notations", `Assoc ["type", `String "boolean"];
         ];
       ];
     ];
   ]);
  ("switch_tab", "Switch to a specific tab by ID",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "tab", `Assoc ["type", `String "integer"; "description", `String "Unique tab ID"];
     ];
     "required", `List [`String "tab"];
   ]);
  ("is_busy", "Check if rocqtui is busy (stepping in progress)",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [];
   ]);
]

let resource_defs = [
  ("rocqtui://buffer", "Current file content", "text/plain");
  ("rocqtui://goals", "Current goal state", "text/plain");
  ("rocqtui://messages", "Messages from rocqtop", "text/plain");
  ("rocqtui://cursor", "Cursor position", "application/json");
  ("rocqtui://regions", "Verified and target regions", "application/json");
  ("rocqtui://sentences", "Sentence list with status", "application/json");
  ("rocqtui://tabs", "Open tabs", "application/json");
]

(* --- Resource handlers --- *)

let handle_resource uri mgr =
  let tab = Tab.active_tab mgr in
  match uri with
  | "rocqtui://buffer" ->
    Some (`Assoc [
      "contents", `List [
        `Assoc [
          "uri", `String uri;
          "mimeType", `String "text/plain";
          "text", `String (Buffer.text tab.buf);
        ]
      ]
    ])
  | "rocqtui://goals" ->
    let text = match tab.session with
      | Some s ->
        (match Session.goals_text s with
         | Some t -> t
         | None -> "No proof in progress.")
      | None -> "No session."
    in
    Some (`Assoc [
      "contents", `List [
        `Assoc [
          "uri", `String uri;
          "mimeType", `String "text/plain";
          "text", `String text;
        ]
      ]
    ])
  | "rocqtui://messages" ->
    let msgs = match tab.session with
      | Some s -> Session.messages s
      | None -> []
    in
    Some (`Assoc [
      "contents", `List [
        `Assoc [
          "uri", `String uri;
          "mimeType", `String "text/plain";
          "text", `String (String.concat "\n" msgs);
        ]
      ]
    ])
  | "rocqtui://cursor" ->
    let (line, col) = Buffer.cursor tab.buf in
    Some (`Assoc [
      "contents", `List [
        `Assoc [
          "uri", `String uri;
          "mimeType", `String "application/json";
          "text", `String (Yojson.Safe.to_string (`Assoc [
            "line", `Int line;
            "col", `Int col;
          ]));
        ]
      ]
    ])
  | "rocqtui://regions" ->
    let vend = match tab.session with
      | Some s -> Session.verified_end s | None -> 0 in
    let tend = match tab.session with
      | Some s -> Session.pending_end s | None -> 0 in
    Some (`Assoc [
      "contents", `List [
        `Assoc [
          "uri", `String uri;
          "mimeType", `String "application/json";
          "text", `String (Yojson.Safe.to_string (`Assoc [
            "verified_end", `Int vend;
            "target_end", `Int tend;
          ]));
        ]
      ]
    ])
  | "rocqtui://sentences" ->
    let ranges = match tab.session with
      | Some s -> Session.sentence_ranges s | None -> [] in
    let sentences = List.map (fun (sd : Session.sentence_display) ->
      `Assoc [
        "start", `Int sd.sd_start;
        "end", `Int sd.sd_end;
        "status", `String (match sd.sd_status with
          | Session.Processing -> "processing"
          | Session.Verified -> "verified"
          | Session.Error msg -> "error: " ^ msg);
      ]
    ) ranges in
    Some (`Assoc [
      "contents", `List [
        `Assoc [
          "uri", `String uri;
          "mimeType", `String "application/json";
          "text", `String (Yojson.Safe.to_string (`List sentences));
        ]
      ]
    ])
  | "rocqtui://tabs" ->
    let tabs = List.mapi (fun i (t : Tab.t) ->
      `Assoc [
        "id", `Int t.id;
        "index", `Int i;
        "filename", (match Buffer.filename t.buf with
          | Some f -> `String f | None -> `Null);
        "modified", `Bool (Buffer.modified t.buf);
        "active", `Bool (i = mgr.active);
      ]
    ) mgr.Tab.tabs in
    Some (`Assoc [
      "contents", `List [
        `Assoc [
          "uri", `String uri;
          "mimeType", `String "application/json";
          "text", `String (Yojson.Safe.to_string (`List tabs));
        ]
      ]
    ])
  | _ -> None

(* --- Tool handlers --- *)

let resolve_tab args mgr =
  let open Yojson.Safe.Util in
  match args |> member "tab" with
  | `Int id ->
    (match Tab.find_by_id mgr id with
     | Some tab -> tab, id
     | None -> Tab.active_tab mgr, (Tab.active_tab mgr).Tab.id)
  | _ ->
    let tab = Tab.active_tab mgr in
    tab, tab.Tab.id

let handle_tool t name args mgr =
  let (tab, tab_idx) = resolve_tab args mgr in
  mark_tab_active t tab_idx;
  match name with
  | "step_forward" ->
    (match tab.session with
     | Some s -> Session.step_forward s | None -> ());
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "step_backward" ->
    (match tab.session with
     | Some s -> Session.step_backward s | None -> ());
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "go_to_end" ->
    let text = Buffer.text tab.buf in
    let len = String.length text in
    Buffer.move_to_byte_offset tab.buf len;
    (match tab.session with
     | Some s -> Session.go_to_cursor s | None -> ());
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "insert_text" ->
    let offset = args |> Yojson.Safe.Util.member "offset" |> Yojson.Safe.Util.to_int in
    let text = args |> Yojson.Safe.Util.member "text" |> Yojson.Safe.Util.to_string in
    Buffer.move_to_byte_offset tab.buf offset;
    String.iter (fun c ->
      if c = '\n' then Buffer.insert_newline tab.buf
      else Buffer.insert_char tab.buf c
    ) text;
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "replace_range" ->
    let s = args |> Yojson.Safe.Util.member "start" |> Yojson.Safe.Util.to_int in
    let e = args |> Yojson.Safe.Util.member "end" |> Yojson.Safe.Util.to_int in
    let text = args |> Yojson.Safe.Util.member "text" |> Yojson.Safe.Util.to_string in
    (* Delete range then insert *)
    let full = Buffer.text tab.buf in
    let before = String.sub full 0 s in
    let after = String.sub full e (String.length full - e) in
    let new_text = before ^ text ^ after in
    (* Reload buffer from new text *)
    Buffer.move_to_byte_offset tab.buf 0;
    (* Simple approach: clear and reload *)
    let lines = String.split_on_char '\n' new_text in
    ignore lines; (* TODO: proper replace *)
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK (replace_range TODO)"]
    ]])
  | "move_cursor" ->
    let line = args |> Yojson.Safe.Util.member "line" |> Yojson.Safe.Util.to_int in
    let col = args |> Yojson.Safe.Util.member "col" |> Yojson.Safe.Util.to_int in
    Buffer.move_to tab.buf line col;
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "query" ->
    let open Yojson.Safe.Util in
    let cmd = args |> member "command" |> to_string in
    let options = args |> member "options" in
    (match tab.session with
     | Some s ->
       let temp_opts = match options with
         | `Assoc _ ->
           let opt name rocq_name =
             match options |> member name with
             | `Bool v -> Some (rocq_name, Interface.BoolValue v)
             | _ -> None
           in
           List.filter_map Fun.id [
             opt "implicit" ["Printing"; "Implicit"];
             opt "all" ["Printing"; "All"];
             opt "notations" ["Printing"; "Notations"];
             opt "coercions" ["Printing"; "Coercions"];
             opt "universes" ["Printing"; "Universes"];
             opt "existential" ["Printing"; "Existential"; "Instances"];
           ]
         | _ -> []
       in
       if temp_opts <> [] then
         Session.with_options s temp_opts (fun () -> Session.query s cmd)
       else
         Session.query s cmd
     | None -> ());
    let msgs = match tab.session with
      | Some s -> Session.messages s | None -> [] in
    (false, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String (String.concat "\n" msgs)]
    ]])
  | "interrupt" ->
    (match tab.session with
     | Some s ->
       (try Unix.kill (Session.pid s) Sys.sigint with _ -> ())
     | None -> ());
    (false, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "save" ->
    let ok = Buffer.save tab.buf in
    (false, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text",
        `String (if ok then "Saved" else "Failed")]
    ]])
  | "get_goals" ->
    let open Yojson.Safe.Util in
    let options = args |> member "options" in
    (match tab.session with
     | Some s ->
       let parse_opts () = match options with
         | `Assoc _ ->
           let opt name rocq_name =
             match options |> member name with
             | `Bool v -> Some (rocq_name, Interface.BoolValue v)
             | _ -> None
           in
           List.filter_map Fun.id [
             opt "implicit" ["Printing"; "Implicit"];
             opt "all" ["Printing"; "All"];
             opt "notations" ["Printing"; "Notations"];
           ]
         | _ -> []
       in
       let temp_opts = parse_opts () in
       let goals_text = ref "No proof in progress." in
       let fetch () =
         match Session.fetch_goals_text s with
         | Some t -> goals_text := t
         | None -> ()
       in
       if temp_opts <> [] then
         Session.with_options s temp_opts fetch
       else
         fetch ();
       (false, `Assoc ["content", `List [
         `Assoc ["type", `String "text"; "text", `String !goals_text]
       ]])
     | None ->
       (false, `Assoc ["content", `List [
         `Assoc ["type", `String "text"; "text", `String "No session."]
       ]]))
  | "switch_tab" ->
    let id = args |> Yojson.Safe.Util.member "tab" |> Yojson.Safe.Util.to_int in
    (match Tab.index_of_id mgr id with
     | Some idx ->
       mgr.Tab.active <- idx;
       (true, `Assoc ["content", `List [
         `Assoc ["type", `String "text"; "text", `String "OK"]
       ]])
     | None ->
       (false, `Assoc ["content", `List [
         `Assoc ["type", `String "text"; "text", `String "Unknown tab ID"]
       ]; "isError", `Bool true]))
  | "is_busy" ->
    let busy = match tab.session with
      | Some s -> Session.is_busy s | None -> false in
    (false, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text",
        `String (if busy then "true" else "false")]
    ]])
  | _ ->
    (false, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String ("Unknown tool: " ^ name)]
    ]; "isError", `Bool true])

(* --- Message dispatch --- *)

let dispatch_message t client msg mgr =
  let open Yojson.Safe.Util in
  let id = msg |> member "id" in
  let method_ = msg |> member "method" |> to_string_option in
  match method_ with
  | Some "initialize" ->
    Some (json_result id (`Assoc [
      "protocolVersion", `String "2024-11-05";
      "capabilities", capabilities;
      "serverInfo", server_info;
    ]))
  | Some "initialized" ->
    client.initialized <- true;
    None  (* notification, no response *)
  | Some "tools/list" ->
    let tools = List.map (fun (name, desc, schema) ->
      `Assoc [
        "name", `String name;
        "description", `String desc;
        "inputSchema", schema;
      ]
    ) tool_defs in
    Some (json_result id (`Assoc ["tools", `List tools]))
  | Some "tools/call" ->
    let params = msg |> member "params" in
    let name = params |> member "name" |> to_string in
    let args = params |> member "arguments" in
    let (_, result) = handle_tool t name args mgr in
    Some (json_result id result)
  | Some "resources/list" ->
    let resources = List.map (fun (uri, desc, mime) ->
      `Assoc [
        "uri", `String uri;
        "name", `String uri;
        "description", `String desc;
        "mimeType", `String mime;
      ]
    ) resource_defs in
    Some (json_result id (`Assoc ["resources", `List resources]))
  | Some "resources/read" ->
    let params = msg |> member "params" in
    let uri = params |> member "uri" |> to_string in
    (match handle_resource uri mgr with
     | Some result -> Some (json_result id result)
     | None -> Some (json_error id (-32602) ("Unknown resource: " ^ uri)))
  | Some "ping" ->
    Some (json_result id (`Assoc []))
  | Some m ->
    Some (json_error id (-32601) ("Method not found: " ^ m))
  | None ->
    Some (json_error id (-32600) "Invalid request")

(* --- I/O --- *)

let send_to_client client json =
  let s = Yojson.Safe.to_string json ^ "\n" in
  try ignore (Unix.write_substring client.fd s 0 (String.length s))
  with _ -> ()

let process_client_data t client mgr =
  let state_changed = ref false in
  (* Split on newlines — each line is a JSON-RPC message *)
  let rec process () =
    match String.index_opt client.buf '\n' with
    | None -> ()
    | Some i ->
      let line = String.sub client.buf 0 i in
      client.buf <- String.sub client.buf (i + 1)
        (String.length client.buf - i - 1);
      if String.length line > 0 then begin
        (try
           let msg = Yojson.Safe.from_string line in
           match dispatch_message t client msg mgr with
           | Some response ->
             send_to_client client response
           | None -> ()
         with e ->
           let err = json_error `Null (-32700)
             ("Parse error: " ^ Printexc.to_string e) in
           send_to_client client err)
      end;
      process ()
  in
  process ();
  !state_changed

(* --- Public API --- *)

let create ?(socket_path="") () =
  let path = if socket_path = "" then
    Printf.sprintf "/tmp/rocqtui-mcp-%d.sock" (Unix.getpid ())
  else socket_path
  in
  (try Unix.unlink path with _ -> ());
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_UNIX path);
  Unix.listen fd 5;
  Unix.set_nonblock fd;
  { server_fd = fd; path; clients = [];
    active_tab_ids = []; spinner_frame = 0 }

let server_fd t = t.server_fd

let client_fds t = List.map (fun c -> c.fd) t.clients

let handle_ready t ready_fds mgr =
  let state_changed = ref false in
  (* Accept new connections *)
  if List.mem t.server_fd ready_fds then begin
    (try
       let client_fd, _ = Unix.accept ~cloexec:true t.server_fd in
       Unix.set_nonblock client_fd;
       t.clients <- { fd = client_fd; buf = ""; initialized = false }
                    :: t.clients
     with Unix.Unix_error (Unix.EAGAIN, _, _) -> ()
        | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) -> ())
  end;
  (* Read from clients *)
  let dead = ref [] in
  List.iter (fun client ->
    if List.mem client.fd ready_fds then begin
      let chunk = Bytes.create 4096 in
      (try
         let n = Unix.read client.fd chunk 0 4096 in
         if n = 0 then
           dead := client :: !dead
         else begin
           client.buf <- client.buf ^ Bytes.sub_string chunk 0 n;
           if process_client_data t client mgr then
             state_changed := true
         end
       with
       | Unix.Unix_error (Unix.EAGAIN, _, _) -> ()
       | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) -> ()
       | _ -> dead := client :: !dead)
    end
  ) t.clients;
  (* Remove dead clients *)
  List.iter (fun c ->
    (try Unix.close c.fd with _ -> ());
    t.clients <- List.filter (fun c2 -> c2.fd != c.fd) t.clients
  ) !dead;
  (* Clear active tabs if no clients remain *)
  if t.clients = [] then
    t.active_tab_ids <- [];
  !state_changed

let notify t method_ params =
  let msg = json_notification method_ params in
  List.iter (fun client ->
    if client.initialized then
      send_to_client client msg
  ) t.clients

let shutdown t =
  List.iter (fun c -> try Unix.close c.fd with _ -> ()) t.clients;
  (try Unix.close t.server_fd with _ -> ());
  (try Unix.unlink t.path with _ -> ())

let socket_path t = t.path

let has_clients t = t.clients <> []
