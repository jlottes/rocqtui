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
  mutable last_activity : float;  (* timestamp of last tool call *)
  mutable last_goals : string;
  mutable last_verified_end : int;
  mutable last_messages : string list;
  mutable symlinks : string list;  (* symlink paths to clean up *)
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

(* Robust int extraction — handles both `Int and `String "123" *)
let to_int_lenient json =
  match json with
  | `Int n -> n
  | `String s -> (match int_of_string_opt s with Some n -> n | None -> 0)
  | _ -> 0

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
  ("go_to_offset", "Set target to a byte offset (verify up to that point)",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "offset", `Assoc ["type", `String "integer";
                         "description", `String "byte offset in the buffer"];
     ];
     "required", `List [`String "offset"];
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
  ("delete_range", "Delete text between two byte offsets",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "start", `Assoc ["type", `String "integer"];
       "end", `Assoc ["type", `String "integer"];
     ];
     "required", `List [`String "start"; `String "end"];
   ]);
  ("open_file", "Open a file in a new tab",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "filename", `Assoc ["type", `String "string"; "description", `String "Path to the .v file"];
     ];
     "required", `List [`String "filename"];
   ]);
  ("undo", "Undo the last edit",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [];
   ]);
  ("redo", "Redo the last undone edit",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [];
   ]);
  ("offset_of_line", "Convert line and column to byte offset",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "line", `Assoc ["type", `String "integer"; "description", `String "0-based line number"];
       "col", `Assoc ["type", `String "integer"; "description", `String "0-based byte column (default 0)"];
     ];
     "required", `List [`String "line"];
   ]);
  ("get_context", "Get buffer text around a byte offset",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "offset", `Assoc ["type", `String "integer"; "description", `String "center byte offset"];
       "before", `Assoc ["type", `String "integer"; "description", `String "bytes before offset (default 500)"];
       "after", `Assoc ["type", `String "integer"; "description", `String "bytes after offset (default 500)"];
     ];
     "required", `List [`String "offset"];
   ]);
  ("batch_edit", "Apply multiple edits as one undo group. Edits are applied last-to-first (provide them in document order; offsets refer to the original text).",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "edits", `Assoc [
         "type", `String "array";
         "items", `Assoc [
           "type", `String "object";
           "properties", `Assoc [
             "start", `Assoc ["type", `String "integer"];
             "end", `Assoc ["type", `String "integer"];
             "text", `Assoc ["type", `String "string"];
           ];
           "required", `List [`String "start"; `String "end"; `String "text"];
         ];
       ];
     ];
     "required", `List [`String "edits"];
   ]);
  ("replace_text", "Find and replace text in the buffer (no byte offsets needed)",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "old_text", `Assoc ["type", `String "string"; "description",
         `String "Exact text to find in the buffer"];
       "new_text", `Assoc ["type", `String "string"; "description",
         `String "Replacement text"];
       "occurrence", `Assoc ["type", `String "integer"; "description",
         `String "Which occurrence to replace (1-based, default 1). Use 0 for all."];
     ];
     "required", `List [`String "old_text"; `String "new_text"];
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
  ("rocqtui://error", "Current error range and message", "application/json");
  ("rocqtui://line_offsets", "Byte offset of each line start", "application/json");
  ("rocqtui://cursor", "Cursor position", "application/json");
  ("rocqtui://regions", "Verified and target regions", "application/json");
  ("rocqtui://sentences", "Sentence list with status", "application/json");
  ("rocqtui://tabs", "Open tabs", "application/json");
]

(* --- Resource handlers --- *)

(* Parse ?tab=N from URI, return (base_uri, tab) *)
let parse_resource_uri uri mgr =
  match String.split_on_char '?' uri with
  | [base; query] ->
    let params = String.split_on_char '&' query in
    let tab_id = List.find_map (fun p ->
      match String.split_on_char '=' p with
      | ["tab"; v] -> int_of_string_opt v
      | _ -> None
    ) params in
    let tab = match tab_id with
      | Some id ->
        (match Tab.find_by_id mgr id with
         | Some t -> t
         | None -> Tab.active_tab mgr)
      | None -> Tab.active_tab mgr
    in
    (base, tab)
  | _ -> (uri, Tab.active_tab mgr)

let handle_resource uri mgr =
  let (uri, tab) = parse_resource_uri uri mgr in
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
  | "rocqtui://error" ->
    let (err_range, err_msg) = match tab.session with
      | Some s ->
        let range = Session.error_range s in
        let msg = match Session.messages s with
          | m :: _ -> m | [] -> "" in
        (range, msg)
      | None -> (None, "")
    in
    let json = match err_range with
      | Some (s, e) -> `Assoc [
          "start", `Int s; "end", `Int e;
          "message", `String err_msg ]
      | None -> `Null
    in
    Some (`Assoc [
      "contents", `List [
        `Assoc [
          "uri", `String uri;
          "mimeType", `String "application/json";
          "text", `String (Yojson.Safe.to_string json);
        ]
      ]
    ])
  | "rocqtui://line_offsets" ->
    let text = Buffer.text tab.buf in
    let offsets = ref [0] in  (* line 0 starts at offset 0 *)
    String.iteri (fun i c ->
      if c = '\n' then offsets := (i + 1) :: !offsets
    ) text;
    let arr = `List (List.rev_map (fun o -> `Int o) !offsets) in
    Some (`Assoc [
      "contents", `List [
        `Assoc [
          "uri", `String uri;
          "mimeType", `String "application/json";
          "text", `String (Yojson.Safe.to_string arr);
        ]
      ]
    ])
  | _ -> None

let symlink_name = ".rocqtui-mcp.sock"

let create_project_symlink t dir =
  let link = Filename.concat dir symlink_name in
  (try Unix.unlink link with _ -> ());
  (try
     Unix.symlink t.path link;
     if not (List.mem link t.symlinks) then
       t.symlinks <- link :: t.symlinks
   with _ -> ())

(* Return a short context snippet around an edit for verification *)
let edit_context buf pos len =
  let text = Buffer.text buf in
  let total = String.length text in
  let s = max 0 (pos - 30) in
  let e = min total (pos + len + 30) in
  let snippet = String.sub text s (e - s) in
  Printf.sprintf "OK. Context:\n...%s..." snippet

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
  t.last_activity <- Unix.gettimeofday ();
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
    let len = String.length (Buffer.text tab.buf) in
    (match tab.session with
     | Some s -> Session.go_to_offset s len | None -> ());
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "go_to_offset" ->
    let offset = args |> Yojson.Safe.Util.member "offset"
                 |> to_int_lenient in
    (match tab.session with
     | Some s -> Session.go_to_offset s offset | None -> ());
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "insert_text" ->
    let offset = args |> Yojson.Safe.Util.member "offset" |> to_int_lenient in
    let text = args |> Yojson.Safe.Util.member "text" |> Yojson.Safe.Util.to_string in
    Buffer.move_to_byte_offset tab.buf offset;
    String.iter (fun c ->
      if c = '\n' then Buffer.insert_newline tab.buf
      else Buffer.insert_char tab.buf c
    ) text;
    let ctx = edit_context tab.buf offset (String.length text) in
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String ctx]
    ]])
  | "replace_range" ->
    let s = args |> Yojson.Safe.Util.member "start" |> to_int_lenient in
    let e = args |> Yojson.Safe.Util.member "end" |> to_int_lenient in
    let text = args |> Yojson.Safe.Util.member "text" |> Yojson.Safe.Util.to_string in
    Buffer.move_to_byte_offset tab.buf s;
    Buffer.set_anchor tab.buf;
    Buffer.move_to_byte_offset tab.buf e;
    ignore (Buffer.delete_selection tab.buf);
    String.iter (fun c ->
      if c = '\n' then Buffer.insert_newline tab.buf
      else Buffer.insert_char tab.buf c
    ) text;
    let ctx = edit_context tab.buf s (String.length text) in
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String ctx]
    ]])
  | "move_cursor" ->
    let line = args |> Yojson.Safe.Util.member "line" |> to_int_lenient in
    let col = args |> Yojson.Safe.Util.member "col" |> to_int_lenient in
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
    (ok, `Assoc ["content", `List [
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
    let id = args |> Yojson.Safe.Util.member "tab" |> to_int_lenient in
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
  | "delete_range" ->
    let s = args |> Yojson.Safe.Util.member "start" |> to_int_lenient in
    let e = args |> Yojson.Safe.Util.member "end" |> to_int_lenient in
    Buffer.move_to_byte_offset tab.buf s;
    Buffer.set_anchor tab.buf;
    Buffer.move_to_byte_offset tab.buf e;
    ignore (Buffer.delete_selection tab.buf);
    let ctx = edit_context tab.buf s 0 in
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String ctx]
    ]])
  | "open_file" ->
    let filename = args |> Yojson.Safe.Util.member "filename"
                   |> Yojson.Safe.Util.to_string in
    (* Check if already open *)
    let existing = List.find_opt (fun (t : Tab.t) ->
      Buffer.filename t.buf = Some filename
    ) mgr.Tab.tabs in
    (match existing with
     | Some tab ->
       (* Switch to existing tab *)
       (match Tab.index_of_id mgr tab.id with
        | Some idx -> mgr.Tab.active <- idx
        | None -> ());
       (true, `Assoc ["content", `List [
         `Assoc ["type", `String "text"; "text",
           `String (Yojson.Safe.to_string (`Assoc [
             "tab", `Int tab.id;
             "existed", `Bool true;
           ]))]
       ]])
     | None ->
       let (project_dir, project_args) = Project.find_args (Some filename) in
       let new_tab = Tab.create_from_file ~args:project_args filename in
       Tab.add_tab mgr new_tab;
       (match project_dir with
        | Some d -> create_project_symlink t d
        | None -> ());
       (true, `Assoc ["content", `List [
         `Assoc ["type", `String "text"; "text",
           `String (Yojson.Safe.to_string (`Assoc [
             "tab", `Int new_tab.id;
             "existed", `Bool false;
           ]))]
       ]]))
  | "undo" ->
    Buffer.undo tab.buf;
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "redo" ->
    Buffer.redo tab.buf;
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "offset_of_line" ->
    let line = args |> Yojson.Safe.Util.member "line"
               |> to_int_lenient in
    let col = match args |> Yojson.Safe.Util.member "col" with
      | `Int c -> c | _ -> 0 in
    let offset = ref 0 in
    for i = 0 to min (line - 1) (Buffer.line_count tab.buf - 1) do
      offset := !offset + String.length (Buffer.get_line tab.buf i) + 1
    done;
    offset := !offset + col;
    (false, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text",
        `String (string_of_int !offset)]
    ]])
  | "get_context" ->
    let offset = args |> Yojson.Safe.Util.member "offset"
                 |> to_int_lenient in
    let before = match args |> Yojson.Safe.Util.member "before" with
      | `Int n -> n | _ -> 500 in
    let after_ = match args |> Yojson.Safe.Util.member "after" with
      | `Int n -> n | _ -> 500 in
    let text = Buffer.text tab.buf in
    let len = String.length text in
    let s = max 0 (offset - before) in
    let e = min len (offset + after_) in
    let context = String.sub text s (e - s) in
    (false, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text",
        `String (Yojson.Safe.to_string (`Assoc [
          "start", `Int s;
          "end", `Int e;
          "offset", `Int offset;
          "text", `String context;
        ]))]
    ]])
  | "batch_edit" ->
    let edits = args |> Yojson.Safe.Util.member "edits"
                |> Yojson.Safe.Util.to_list in
    (* Parse edits *)
    let parsed = List.map (fun e ->
      let s = e |> Yojson.Safe.Util.member "start" |> to_int_lenient in
      let ed = e |> Yojson.Safe.Util.member "end" |> to_int_lenient in
      let text = e |> Yojson.Safe.Util.member "text"
                 |> Yojson.Safe.Util.to_string in
      (s, ed, text)
    ) edits in
    (* Sort by start offset descending so earlier offsets stay valid *)
    let sorted = List.sort (fun (a, _, _) (b, _, _) -> compare b a) parsed in
    (* Apply each edit *)
    List.iter (fun (s, e, text) ->
      Buffer.move_to_byte_offset tab.buf s;
      Buffer.set_anchor tab.buf;
      Buffer.move_to_byte_offset tab.buf e;
      ignore (Buffer.delete_selection tab.buf);
      String.iter (fun c ->
        if c = '\n' then Buffer.insert_newline tab.buf
        else Buffer.insert_char tab.buf c
      ) text
    ) sorted;
    (true, `Assoc ["content", `List [
      `Assoc ["type", `String "text"; "text", `String "OK"]
    ]])
  | "replace_text" ->
    let old_text = args |> Yojson.Safe.Util.member "old_text"
                   |> Yojson.Safe.Util.to_string in
    let new_text = args |> Yojson.Safe.Util.member "new_text"
                   |> Yojson.Safe.Util.to_string in
    let occurrence = match args |> Yojson.Safe.Util.member "occurrence" with
      | `Null -> 1 | v -> to_int_lenient v in
    let buf_text = Buffer.text tab.buf in
    let old_len = String.length old_text in
    if old_len = 0 then
      (false, `Assoc ["content", `List [
        `Assoc ["type", `String "text"; "text", `String "old_text is empty"]
      ]; "isError", `Bool true])
    else begin
      (* Find all occurrences *)
      let positions = ref [] in
      let i = ref 0 in
      while !i <= String.length buf_text - old_len do
        if String.sub buf_text !i old_len = old_text then begin
          positions := !i :: !positions;
          i := !i + old_len
        end else
          incr i
      done;
      let positions = List.rev !positions in
      let n_found = List.length positions in
      if n_found = 0 then
        (false, `Assoc ["content", `List [
          `Assoc ["type", `String "text"; "text",
            `String "old_text not found in buffer"]
        ]; "isError", `Bool true])
      else begin
        (* Select which positions to replace *)
        let to_replace = if occurrence = 0 then positions
          else if occurrence > 0 && occurrence <= n_found then
            [List.nth positions (occurrence - 1)]
          else [] in
        if to_replace = [] then
          (false, `Assoc ["content", `List [
            `Assoc ["type", `String "text"; "text",
              `String (Printf.sprintf "Occurrence %d not found (have %d)"
                         occurrence n_found)]
          ]; "isError", `Bool true])
        else begin
          (* Apply replacements in reverse order so offsets stay valid *)
          let sorted = List.sort (fun a b -> compare b a) to_replace in
          List.iter (fun pos ->
            Buffer.move_to_byte_offset tab.buf pos;
            Buffer.set_anchor tab.buf;
            Buffer.move_to_byte_offset tab.buf (pos + old_len);
            ignore (Buffer.delete_selection tab.buf);
            String.iter (fun c ->
              if c = '\n' then Buffer.insert_newline tab.buf
              else Buffer.insert_char tab.buf c
            ) new_text
          ) sorted;
          let n_replaced = List.length to_replace in
          (* Return context around the first replacement for verification *)
          let first_pos = List.nth (List.rev sorted) 0 in
          let ctx_start = max 0 (first_pos - 20) in
          let new_buf = Buffer.text tab.buf in
          let ctx_end = min (String.length new_buf)
                          (first_pos + String.length new_text + 20) in
          let context = String.sub new_buf ctx_start (ctx_end - ctx_start) in
          (true, `Assoc ["content", `List [
            `Assoc ["type", `String "text"; "text",
              `String (Printf.sprintf "Replaced %d occurrence(s). Context:\n...%s..."
                         n_replaced context)]
          ]])
        end
      end
    end
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
    (false, Some (json_result id (`Assoc [
      "protocolVersion", `String "2024-11-05";
      "capabilities", capabilities;
      "serverInfo", server_info;
    ])))
  | Some "initialized" ->
    client.initialized <- true;
    (false, None)  (* notification, no response *)
  | Some "tools/list" ->
    let tools = List.map (fun (name, desc, schema) ->
      `Assoc [
        "name", `String name;
        "description", `String desc;
        "inputSchema", schema;
      ]
    ) tool_defs in
    (false, Some (json_result id (`Assoc ["tools", `List tools])))
  | Some "tools/call" ->
    let params = msg |> member "params" in
    let name = params |> member "name" |> to_string in
    let args = params |> member "arguments" in
    let (changed, result) = handle_tool t name args mgr in
    (changed, Some (json_result id result))
  | Some "resources/list" ->
    let resources = List.map (fun (uri, desc, mime) ->
      `Assoc [
        "uri", `String uri;
        "name", `String uri;
        "description", `String desc;
        "mimeType", `String mime;
      ]
    ) resource_defs in
    (false, Some (json_result id (`Assoc ["resources", `List resources])))
  | Some "resources/read" ->
    let params = msg |> member "params" in
    let uri = params |> member "uri" |> to_string in
    (match handle_resource uri mgr with
     | Some result -> (false, Some (json_result id result))
     | None -> (false, Some (json_error id (-32602) ("Unknown resource: " ^ uri))))
  | Some "ping" ->
    (false, Some (json_result id (`Assoc [])))
  | Some m ->
    (false, Some (json_error id (-32601) ("Method not found: " ^ m)))
  | None ->
    (false, Some (json_error id (-32600) "Invalid request"))

(* --- I/O --- *)

let send_to_client client json =
  let s = Yojson.Safe.to_string json ^ "\n" in
  try ignore (Unix.write_substring client.fd s 0 (String.length s))
  with _ -> ()

let notify t method_ params =
  let msg = json_notification method_ params in
  List.iter (fun client ->
    if client.initialized then
      send_to_client client msg
  ) t.clients

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
           let id = try Yojson.Safe.Util.member "id" msg
                    with _ -> `Null in
           (try
              let (changed, response) = dispatch_message t client msg mgr in
              if changed then state_changed := true;
              (match response with
               | Some r -> send_to_client client r
               | None -> ())
            with e ->
              let err = json_error id (-32603)
                ("Internal error: " ^ Printexc.to_string e) in
              send_to_client client err)
         with e ->
           let err = json_error `Null (-32700)
             ("Parse error: " ^ Printexc.to_string e) in
           send_to_client client err)
      end;
      process ()
  in
  process ();
  !state_changed

(* --- Notifications --- *)

let activity_timeout = 5.0  (* seconds of inactivity before clearing indicator *)

let poll_notifications t mgr =
  if t.clients = [] then ()
  else begin
    let tab = Tab.active_tab mgr in
    (* Check for goals changes *)
    let cur_goals = match tab.session with
      | Some s -> (match Session.goals_text s with Some g -> g | None -> "")
      | None -> ""
    in
    if cur_goals <> t.last_goals then begin
      t.last_goals <- cur_goals;
      notify t "notifications/resources/updated"
        (`Assoc ["uri", `String "rocqtui://goals"])
    end;
    (* Check for verified region changes *)
    let cur_vend = match tab.session with
      | Some s -> Session.verified_end s | None -> 0 in
    if cur_vend <> t.last_verified_end then begin
      t.last_verified_end <- cur_vend;
      notify t "notifications/resources/updated"
        (`Assoc ["uri", `String "rocqtui://regions"])
    end;
    (* Check for message changes *)
    let cur_msgs = match tab.session with
      | Some s -> Session.messages s | None -> [] in
    if cur_msgs <> t.last_messages then begin
      t.last_messages <- cur_msgs;
      notify t "notifications/resources/updated"
        (`Assoc ["uri", `String "rocqtui://messages"])
    end;
    (* Timeout active tab indicator *)
    if t.active_tab_ids <> [] then begin
      let now = Unix.gettimeofday () in
      if now -. t.last_activity > activity_timeout then
        t.active_tab_ids <- []
    end
  end

(* --- Stale socket cleanup --- *)

let cleanup_stale_sockets () =
  let prefix = "rocqtui-mcp-" in
  let prefix_len = String.length prefix in
  try
    let dir = Unix.opendir "/tmp" in
    (try while true do
       let entry = Unix.readdir dir in
       if String.length entry > prefix_len
          && String.sub entry 0 prefix_len = prefix
          && Filename.check_suffix entry ".sock" then begin
         let base = Filename.chop_suffix entry ".sock" in
         let pid_str = String.sub base prefix_len
                         (String.length base - prefix_len) in
         match int_of_string_opt pid_str with
         | Some pid ->
           let alive = try Unix.kill pid 0; true with _ -> false in
           if not alive then
             (try Unix.unlink ("/tmp/" ^ entry) with _ -> ())
         | None -> ()
       end
     done with End_of_file -> ());
    Unix.closedir dir
  with _ -> ()

(* --- Public API --- *)

let create ?(socket_path="") () =
  cleanup_stale_sockets ();
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
    active_tab_ids = []; spinner_frame = 0;
    last_activity = 0.0;
    last_goals = ""; last_verified_end = 0; last_messages = [];
    symlinks = [] }

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
  (* Send notifications for state changes *)
  poll_notifications t mgr;
  !state_changed

let shutdown t =
  List.iter (fun c -> try Unix.close c.fd with _ -> ()) t.clients;
  (try Unix.close t.server_fd with _ -> ());
  (try Unix.unlink t.path with _ -> ());
  List.iter (fun link -> try Unix.unlink link with _ -> ()) t.symlinks

let socket_path t = t.path

let has_clients t = t.clients <> []
