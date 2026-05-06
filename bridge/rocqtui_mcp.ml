(* OCaml MCP bridge for rocqtui.
   Speaks MCP (JSON-RPC 2.0 over stdio) to Claude Code,
   and communicates with rocqtui via Unix domain socket.
   Implements high-level proving tools by orchestrating low-level ones. *)

open Rocqtui_lib

(* --- Socket discovery --- *)

let find_socket () =
  let rec walk dir =
    let candidate = Filename.concat dir ".rocqtui-mcp.sock" in
    if Sys.file_exists candidate then
      Some (Unix.readlink candidate)
    else
      let parent = Filename.dirname dir in
      if parent = dir then None
      else walk parent
  in
  walk (Sys.getcwd ())

(* --- Socket I/O --- *)

type connection = {
  fd : Unix.file_descr;
  ic : in_channel;
  mutable next_id : int;
}

let connect path =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX path);
  let ic = Unix.in_channel_of_descr fd in
  { fd; ic; next_id = 100000 }

let send_json conn json =
  let s = Yojson.Safe.to_string json ^ "\n" in
  let _ = Unix.write_substring conn.fd s 0 (String.length s) in
  ()

let recv_json conn =
  try Some (Yojson.Safe.from_string (input_line conn.ic))
  with End_of_file -> None
     | _ -> None

(* Send a JSON-RPC request and wait for matching response. *)
let call conn method_ params =
  conn.next_id <- conn.next_id + 1;
  let id = conn.next_id in
  let msg = `Assoc [
    "jsonrpc", `String "2.0";
    "id", `Int id;
    "method", `String method_;
    "params", params;
  ] in
  send_json conn msg;
  (* Read responses until we get ours (skip notifications) *)
  let rec wait () =
    match recv_json conn with
    | None -> None
    | Some resp ->
      let resp_id = Mcp_json.member "id" resp in
      if resp_id = `Int id then
        Some (Mcp_json.member "result" resp, Mcp_json.member "error" resp)
      else
        wait ()  (* skip notifications *)
  in
  wait ()

(* --- Low-level tool/resource calls --- *)

let call_tool conn name args =
  call conn "tools/call" (`Assoc [
    "name", `String name;
    "arguments", args;
  ])

(* Inspect a tools/call response for a region-buffer rejection.
   Returns Some (reason, message) if the call returned isError:true with
   a rejection_reason field, None otherwise. *)
let extract_rejection result =
  match result with
  | Some (`Assoc fields, _) ->
    let is_error = match List.assoc_opt "isError" fields with
      | Some (`Bool true) -> true | _ -> false in
    if not is_error then None
    else
      let reason = match List.assoc_opt "rejection_reason" fields with
        | Some (`String s) -> Some s | _ -> None in
      (match reason with
       | None -> None
       | Some r ->
         let msg = match List.assoc_opt "content" fields with
           | Some (`List ((`Assoc c) :: _)) ->
             (match List.assoc_opt "text" c with
              | Some (`String s) -> s | _ -> "")
           | _ -> ""
         in
         Some (r, msg))
  | _ -> None

(* Like call_tool but raises a tool_error if the call was rejected by
   the region-buffer gateway. Used for buffer-mutating low-level calls. *)
let call_tool_or_reject conn name args =
  let result = call_tool conn name args in
  (match extract_rejection result with
   | Some (reason, msg) ->
     raise (Failure (Yojson.Safe.to_string
       (Mcp_json.tool_error
          (Printf.sprintf "%s rejected: %s (%s)" name msg reason))))
   | None -> ());
  result

let read_resource conn uri =
  match call conn "resources/read" (`Assoc ["uri", `String uri]) with
  | Some (`Assoc result, _) ->
    (match List.assoc_opt "contents" result with
     | Some (`List ((`Assoc c) :: _)) ->
       (match List.assoc_opt "text" c with
        | Some (`String t) -> t
        | _ -> "")
     | _ -> "")
  | _ -> ""

(* --- State reading --- *)

type state = {
  buffer : string;
  verified_end : int;
  target_end : int;
  is_busy : bool;
  goals : string option;
  messages : string list;
  error : (int * int * string) option;  (* start, end, message *)
  sentences : (int * int * string) list;  (* start, end, status *)
  locked : bool;
}

let parse_state json_str =
  let json = Yojson.Safe.from_string json_str in
  let open Yojson.Safe.Util in
  let error = match json |> member "error" with
    | `Assoc _ as e ->
      Some (e |> member "start" |> to_int,
            e |> member "end" |> to_int,
            e |> member "message" |> to_string)
    | _ -> None
  in
  let sentences = match json |> member "sentences" with
    | `List l -> List.map (fun s ->
        (s |> member "start" |> to_int,
         s |> member "end" |> to_int,
         s |> member "status" |> to_string)
      ) l
    | _ -> []
  in
  let messages = match json |> member "messages" with
    | `List l -> List.filter_map (fun m ->
        match m with `String s -> Some s | _ -> None) l
    | _ -> []
  in
  { buffer = json |> member "buffer" |> to_string;
    verified_end = json |> member "verified_end" |> to_int;
    target_end = json |> member "target_end" |> to_int;
    is_busy = json |> member "is_busy" |> to_bool;
    goals = (match json |> member "goals" with
             | `String s -> Some s | _ -> None);
    messages;
    error;
    sentences;
    locked = json |> member "locked" |> to_bool;
  }

let get_state conn ?(tab=(-1)) () =
  let uri = if tab >= 0 then
    Printf.sprintf "rocqtui://state?tab=%d" tab
  else "rocqtui://state" in
  parse_state (read_resource conn uri)

(* If [args] carries a [display] options block, replace [state.goals] with
   a fresh render via the [get_goals] MCP tool. The [rocqtui://state]
   resource only carries the IDE's persistent rendering, so per-call
   display options would otherwise be silently dropped. *)
let apply_display conn args ?tab state =
  match Yojson.Safe.Util.member "display" args with
  | `Assoc _ as opts ->
    let tool_args =
      let base = ["options", opts] in
      match tab with
      | Some n -> ("tab", `Int n) :: base
      | None -> base
    in
    (match call_tool conn "get_goals" (`Assoc tool_args) with
     | Some (`Assoc fields, _) ->
       (match List.assoc_opt "content" fields with
        | Some (`List ((`Assoc c) :: _)) ->
          (match List.assoc_opt "text" c with
           | Some (`String t) -> { state with goals = Some t }
           | _ -> state)
        | _ -> state)
     | _ -> state)
  | _ -> state

(* --- Poll until idle --- *)

let poll_interval = 0.05  (* 50ms *)
let poll_timeout = 60.0

let poll_until_idle conn ?tab () =
  let start = Unix.gettimeofday () in
  let rec loop () =
    let st = get_state conn ?tab () in
    if not st.is_busy then st
    else if Unix.gettimeofday () -. start > poll_timeout then st
    else begin
      Unix.sleepf poll_interval;
      loop ()
    end
  in
  loop ()

(* --- Common response builder --- *)

let build_response state =
  let text = state.buffer in
  let boundary = state.verified_end in
  let has_goals = state.goals <> None in
  let ctx_before = Context.before text ~boundary ~has_goals () in
  let ctx_after = Context.after text ~boundary () in
  let last_sent = Context.last_sentence text ~boundary in
  let vline = Text_match.line_of_offset text boundary in
  let msgs = match state.messages with
    | [] -> `Null
    | l -> `String (String.concat "\n" l) in
  `Assoc [
    "verified_end_line", `Int vline;
    "last_sentence", (match last_sent with
      | Some s -> `String s | None -> `Null);
    "goals", (match state.goals with
      | Some g -> `String g | None -> `Null);
    "context_before", `String ctx_before;
    "context_after", `String ctx_after;
    "messages", msgs;
  ]

let merge_json (base : Yojson.Safe.t) (extra : (string * Yojson.Safe.t) list) =
  match base with
  | `Assoc fields -> `Assoc (fields @ extra)
  | _ -> `Assoc extra

(* --- High-level tool implementations --- *)

let handle_verify_to conn args state =
  let open Yojson.Safe.Util in
  let before_text = args |> member "before_text" |> to_string_option in
  let after_text = args |> member "after_text" |> to_string_option in
  let line = match args |> member "line" with
    | `Int n -> Some n | _ -> None in
  let tab = match args |> member "tab" with
    | `Int n -> Some n | _ -> None in
  let text = state.buffer in
  let offset = match before_text, line with
    | None, None ->
      (* No args: go to beginning *)
      0
    | Some needle, _ ->
      (match Text_match.find_unique ~haystack:text ~needle
               ?after_text ?line () with
       | Text_match.Unique off ->
         (* go_to_offset already snaps to sentence boundary at or before *)
         off
       | Text_match.No_match ->
         let err = Mcp_json.tool_error "No match found for before_text" in
         raise (Failure (Yojson.Safe.to_string err))
       | Text_match.Ambiguous lines ->
         let lines_str = String.concat ", "
           (List.map string_of_int lines) in
         let err = Mcp_json.tool_error
           (Printf.sprintf "Ambiguous: before_text matches at lines %s. \
                            Use 'line' or 'after_text' to disambiguate."
              lines_str) in
         raise (Failure (Yojson.Safe.to_string err)))
    | None, Some target_line ->
      (* Line only: compute byte offset *)
      let off = ref 0 in
      let lines = String.split_on_char '\n' text in
      let n = ref 1 in
      List.iter (fun l ->
        if !n < target_line then begin
          off := !off + String.length l + 1;
          incr n
        end
      ) lines;
      !off
  in
  (* Call go_to_offset *)
  ignore (call_tool conn "go_to_offset"
    (`Assoc ["offset", `Int offset]));
  let final = poll_until_idle conn ?tab () in
  let final = apply_display conn args ?tab final in
  let resp = build_response final in
  (* Check for errors *)
  let extra = match final.error with
    | Some (_, _, msg) ->
      let failed = match final.sentences with
        | [] -> None
        | l -> let last = List.nth l (List.length l - 1) in
          let (s, e, _) = last in
          Some (String.trim (String.sub text s (e - s)))
      in
      [ "error", `String msg;
        "failed_sentence", (match failed with
          | Some s -> `String s | None -> `Null) ]
    | None ->
      [ "error", `Null; "failed_sentence", `Null ]
  in
  merge_json resp extra

let handle_proof_insert conn args state =
  let open Yojson.Safe.Util in
  let insert_text = args |> member "text" |> to_string in
  let tab = match args |> member "tab" with
    | `Int n -> Some n | _ -> None in
  (* Validate: must contain complete sentences *)
  let sents = Sentence.split insert_text in
  if sents = [] then
    raise (Failure (Yojson.Safe.to_string
      (Mcp_json.tool_error "No complete sentences found in text")));
  let last_sent_end = match List.rev sents with
    | (_, e) :: _ -> e | [] -> 0 in
  let trimmed_tail = String.trim
    (String.sub insert_text last_sent_end
       (String.length insert_text - last_sent_end)) in
  if trimmed_tail <> "" then
    raise (Failure (Yojson.Safe.to_string
      (Mcp_json.tool_error
         (Printf.sprintf "Trailing text after last sentence: %S" trimmed_tail))));
  (* Ensure separation *)
  let text = state.buffer in
  let vend = state.verified_end in
  let needs_space =
    vend > 0
    && not (Sentence.is_space text.[vend - 1])
    && String.length insert_text > 0
    && not (Sentence.is_space insert_text.[0]) in
  let actual_text = if needs_space then " " ^ insert_text else insert_text in
  let old_vend = vend in
  (* Insert text *)
  ignore (call_tool_or_reject conn "insert_text"
    (`Assoc [
      "offset", `Int vend;
      "text", `String actual_text;
    ]));
  (* Set target to end of inserted text *)
  let new_target = vend + String.length actual_text in
  ignore (call_tool conn "go_to_offset"
    (`Assoc ["offset", `Int new_target]));
  let final = poll_until_idle conn ?tab () in
  (* Determine what verified and what failed *)
  let final_vend = final.verified_end in
  let verified_text = if final_vend > old_vend then
    String.sub final.buffer old_vend (final_vend - old_vend)
  else "" in
  let (failed_sentence, error_msg) = match final.error with
    | Some (s, e, msg) ->
      let fs = if e <= String.length final.buffer then
        Some (String.trim (String.sub final.buffer s (e - s)))
      else None in
      (fs, Some msg)
    | None -> (None, None)
  in
  (* Delete unverified inserted text *)
  let delete_from = final_vend in
  let delete_to = old_vend + String.length actual_text in
  if delete_to > delete_from then begin
    ignore (call_tool_or_reject conn "delete_range"
      (`Assoc ["start", `Int delete_from; "end", `Int delete_to]));
    (* Re-read state after deletion *)
    ignore (poll_until_idle conn ?tab ())
  end;
  let final2 = get_state conn ?tab () in
  let final2 = apply_display conn args ?tab final2 in
  let resp = build_response final2 in
  merge_json resp [
    "verified_text", `String verified_text;
    "failed_sentence", (match failed_sentence with
      | Some s -> `String s | None -> `Null);
    "error", (match error_msg with
      | Some s -> `String s | None -> `Null);
  ]

let handle_proof_forward conn args state =
  let open Yojson.Safe.Util in
  let sentences_text = args |> member "sentences" |> to_string in
  let tab = match args |> member "tab" with
    | `Int n -> Some n | _ -> None in
  let text = state.buffer in
  let vend = state.verified_end in
  (* Match against buffer text after verified_end *)
  let remaining = String.length text - vend in
  let chunk = if remaining > 0 then
    String.sub text vend (min remaining (String.length sentences_text * 3))
  else "" in
  let norm_chunk = Text_match.normalize chunk in
  let norm_sents = Text_match.normalize sentences_text in
  let nlen = String.length norm_sents in
  if nlen = 0 || String.length norm_chunk < nlen
     || String.sub norm_chunk 0 nlen <> norm_sents then begin
    let preview = Context.after text ~boundary:vend ~max_bytes:200 () in
    raise (Failure (Yojson.Safe.to_string
      (Mcp_json.tool_error
         (Printf.sprintf "Text does not match buffer after verified boundary.\n\
                          Expected: %S\nActual: %S" sentences_text preview))))
  end;
  (* Find the end of the matched text in original buffer *)
  let matched_sents = Sentence.split chunk in
  let target_end = ref vend in
  let sent_bytes = ref 0 in
  List.iter (fun (_, e) ->
    let e_abs = vend + e in
    let so_far = String.sub text vend (e_abs - vend) in
    let norm_so_far = Text_match.normalize so_far in
    if String.length norm_so_far <= nlen then begin
      target_end := e_abs;
      sent_bytes := String.length norm_so_far
    end
  ) matched_sents;
  if !sent_bytes < nlen then
    target_end := vend + String.length chunk;
  ignore (call_tool conn "go_to_offset"
    (`Assoc ["offset", `Int !target_end]));
  let final = poll_until_idle conn ?tab () in
  let final_vend = final.verified_end in
  let verified_text = if final_vend > vend then
    String.sub final.buffer vend (final_vend - vend)
  else "" in
  let (failed_sentence, error_msg) = match final.error with
    | Some (s, e, msg) ->
      let fs = if e <= String.length final.buffer then
        Some (String.trim (String.sub final.buffer s (e - s)))
      else None in
      (fs, Some msg)
    | None -> (None, None)
  in
  let final = apply_display conn args ?tab final in
  let resp = build_response final in
  merge_json resp [
    "verified_text", `String verified_text;
    "failed_sentence", (match failed_sentence with
      | Some s -> `String s | None -> `Null);
    "error", (match error_msg with
      | Some s -> `String s | None -> `Null);
  ]

let handle_proof_rewind conn args state =
  let open Yojson.Safe.Util in
  let sentences_text = args |> member "sentences" |> to_string in
  let delete = match args |> member "delete" with
    | `Bool b -> b | _ -> true in
  let tab = match args |> member "tab" with
    | `Int n -> Some n | _ -> None in
  let text = state.buffer in
  let vend = state.verified_end in
  (* Match against tail of verified region *)
  match Text_match.tail_matches ~text ~tail_end:vend ~pattern:sentences_text with
  | None ->
    let tail_preview = if vend > 200 then
      String.sub text (vend - 200) 200
    else if vend > 0 then
      String.sub text 0 vend
    else "" in
    raise (Failure (Yojson.Safe.to_string
      (Mcp_json.tool_error
         (Printf.sprintf "Text does not match tail of verified region.\n\
                          Expected (tail): %S\nActual tail: %S"
            sentences_text tail_preview))))
  | Some match_start ->
    let rewound_text = String.sub text match_start (vend - match_start) in
    let sents = Sentence.split rewound_text in
    let count = List.length sents in
    (* Rewind *)
    ignore (call_tool conn "go_to_offset"
      (`Assoc ["offset", `Int match_start]));
    ignore (poll_until_idle conn ?tab ());
    (* Delete if requested *)
    if delete then begin
      ignore (call_tool_or_reject conn "delete_range"
        (`Assoc ["start", `Int match_start; "end", `Int vend]));
      ignore (poll_until_idle conn ?tab ())
    end;
    let final = get_state conn ?tab () in
    let final = apply_display conn args ?tab final in
    let resp = build_response final in
    merge_json resp [
      "count", `Int count;
      "rewound_text", `String rewound_text;
    ]

let handle_query conn args _state =
  let open Yojson.Safe.Util in
  let command = args |> member "command" |> to_string in
  let options = args |> member "display" in
  let tool_args = `Assoc (
    ("command", `String command) ::
    (match options with
     | `Assoc _ -> ["options", options]
     | _ -> [])
  ) in
  ignore (call_tool conn "query" tool_args);
  let tab = match args |> member "tab" with
    | `Int n -> Some n | _ -> None in
  let final = get_state conn ?tab () in
  let final = apply_display conn args ?tab final in
  build_response final

let handle_save conn args _state =
  let tab_args = match Yojson.Safe.Util.member "tab" args with
    | `Int _ as t -> `Assoc ["tab", t]
    | _ -> `Assoc [] in
  match call_tool conn "save" tab_args with
  | Some (result, _) -> result
  | None -> Mcp_json.tool_error "No response from save"

let handle_open_file conn args _state =
  let open Yojson.Safe.Util in
  let filename = args |> member "filename" |> to_string in
  match call_tool conn "open_file" (`Assoc ["filename", `String filename]) with
  | Some (result, _) -> result
  | None -> Mcp_json.tool_error "No response from open_file"

let handle_build_deps conn args _state =
  let tab_args = match Yojson.Safe.Util.member "tab" args with
    | `Int _ as t -> `Assoc ["tab", t]
    | _ -> `Assoc [] in
  ignore (call_tool conn "build_deps" tab_args);
  (* Poll until build finishes — check is_busy *)
  let tab = match Yojson.Safe.Util.member "tab" args with
    | `Int n -> Some n | _ -> None in
  (* Build is separate from session busy; poll for build output *)
  (* For now, return immediately with the start confirmation *)
  (* TODO: poll build status *)
  let final = get_state conn ?tab () in
  build_response final

(* --- Tool dispatch --- *)

let tool_defs = [
  ("verify_to", "Move the verified boundary to a text-identified position",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "before_text", `Assoc ["type", `String "string";
         "description", `String "Text before the desired boundary"];
       "after_text", `Assoc ["type", `String "string";
         "description", `String "Text after the boundary (disambiguates)"];
       "line", `Assoc ["type", `String "integer";
         "description", `String "1-based line number hint"];
       "display", `Assoc ["type", `String "object"];
       "tab", `Assoc ["type", `String "integer"];
     ];
   ]);
  ("proof_insert", "Insert sentences at verified boundary, verify, clean up failures",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "text", `Assoc ["type", `String "string";
         "description", `String "Complete sentences to insert"];
       "display", `Assoc ["type", `String "object"];
       "tab", `Assoc ["type", `String "integer"];
     ];
     "required", `List [`String "text"];
   ]);
  ("proof_forward", "Verify existing sentences after the verified boundary",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "sentences", `Assoc ["type", `String "string";
         "description", `String "Text that must match buffer after verified boundary"];
       "display", `Assoc ["type", `String "object"];
       "tab", `Assoc ["type", `String "integer"];
     ];
     "required", `List [`String "sentences"];
   ]);
  ("proof_rewind", "Rewind verified sentences, optionally deleting them",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "sentences", `Assoc ["type", `String "string";
         "description", `String "Text matching tail of verified region"];
       "delete", `Assoc ["type", `String "boolean";
         "description", `String "Delete the rewound text (default true)"];
       "display", `Assoc ["type", `String "object"];
       "tab", `Assoc ["type", `String "integer"];
     ];
     "required", `List [`String "sentences"];
   ]);
  ("query", "Run a Rocq query (About, Print, Search, Check, etc.)",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "command", `Assoc ["type", `String "string";
         "description", `String "e.g. 'About nat.' or 'Search (_ + _ = _).'"];
       "display", `Assoc ["type", `String "object"];
       "tab", `Assoc ["type", `String "integer"];
     ];
     "required", `List [`String "command"];
   ]);
  ("save", "Save the current file",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "tab", `Assoc ["type", `String "integer"];
     ];
   ]);
  ("open_file", "Open a file (or switch to it if already open)",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "filename", `Assoc ["type", `String "string"];
     ];
     "required", `List [`String "filename"];
   ]);
  ("build_deps", "Build dependencies of the current file",
   `Assoc [
     "type", `String "object";
     "properties", `Assoc [
       "tab", `Assoc ["type", `String "integer"];
     ];
   ]);
]

let resource_defs = [
  ("rocqtui://proof_status", "Current proof state (goals, context, verified position)");
  ("rocqtui://buffer", "Full buffer text");
  ("rocqtui://tabs", "List of open tabs");
]

(* --- MCP message dispatch --- *)

let dispatch conn msg =
  let open Yojson.Safe.Util in
  let id = msg |> member "id" in
  let method_ = msg |> member "method" |> to_string_option in
  match method_ with
  | Some "initialize" ->
    Some (Mcp_json.result id (`Assoc [
      "protocolVersion", `String "2024-11-05";
      "capabilities", `Assoc [
        "tools", `Assoc [];
        "resources", `Assoc [];
      ];
      "serverInfo", `Assoc [
        "name", `String "rocqtui-mcp";
        "version", `String "0.2.0";
      ];
    ]))
  | Some "initialized" -> None  (* notification *)
  | Some "notifications/initialized" -> None
  | Some "tools/list" ->
    let tools = List.map (fun (name, desc, schema) ->
      `Assoc [
        "name", `String name;
        "description", `String desc;
        "inputSchema", schema;
      ]
    ) tool_defs in
    Some (Mcp_json.result id (`Assoc ["tools", `List tools]))
  | Some "tools/call" ->
    let params = msg |> member "params" in
    let name = params |> member "name" |> to_string in
    let args = params |> member "arguments" in
    let tab = match args |> member "tab" with
      | `Int n -> Some n | _ -> None in
    (* Lock for mutating tools *)
    let needs_lock = List.mem name
      ["verify_to"; "proof_insert"; "proof_forward"; "proof_rewind"] in
    if needs_lock then
      ignore (call_tool conn "lock" (match tab with
        | Some t -> `Assoc ["tab", `Int t] | None -> `Assoc []));
    let result =
      (try
         let state = get_state conn ?tab () in
         let r = match name with
           | "verify_to" -> handle_verify_to conn args state
           | "proof_insert" -> handle_proof_insert conn args state
           | "proof_forward" -> handle_proof_forward conn args state
           | "proof_rewind" -> handle_proof_rewind conn args state
           | "query" -> handle_query conn args state
           | "save" -> handle_save conn args state
           | "open_file" -> handle_open_file conn args state
           | "build_deps" -> handle_build_deps conn args state
           | _ -> Mcp_json.tool_error ("Unknown tool: " ^ name)
         in
         Mcp_json.tool_result_json r
       with
       | Failure msg ->
         (try Yojson.Safe.from_string msg
          with _ -> Mcp_json.tool_error msg)
       | exn ->
         Mcp_json.tool_error (Printexc.to_string exn))
    in
    if needs_lock then
      ignore (call_tool conn "unlock" (match tab with
        | Some t -> `Assoc ["tab", `Int t] | None -> `Assoc []));
    Some (Mcp_json.result id result)
  | Some "resources/list" ->
    let resources = List.map (fun (uri, desc) ->
      `Assoc [
        "uri", `String uri;
        "name", `String uri;
        "description", `String desc;
        "mimeType", `String "application/json";
      ]
    ) resource_defs in
    Some (Mcp_json.result id (`Assoc ["resources", `List resources]))
  | Some "resources/read" ->
    let params = msg |> member "params" in
    let uri = params |> member "uri" |> to_string in
    let base_uri = match String.split_on_char '?' uri with
      | base :: _ -> base | [] -> uri in
    (match base_uri with
     | "rocqtui://proof_status" ->
       let tab = match String.split_on_char '?' uri with
         | [_; query] ->
           (match String.split_on_char '=' query with
            | ["tab"; v] -> (match int_of_string_opt v with
              | Some n -> Some n | None -> None)
            | _ -> None)
         | _ -> None in
       let state = get_state conn ?tab () in
       let resp = build_response state in
       Some (Mcp_json.result id
         (Mcp_json.resource_result uri
            (Yojson.Safe.to_string resp)))
     | "rocqtui://buffer" ->
       let text = read_resource conn uri in
       Some (Mcp_json.result id (Mcp_json.resource_result uri text))
     | "rocqtui://tabs" ->
       let text = read_resource conn "rocqtui://tabs" in
       Some (Mcp_json.result id (Mcp_json.resource_result uri text))
     | _ ->
       Some (Mcp_json.error id Mcp_json.invalid_params
               ("Unknown resource: " ^ uri)))
  | Some "ping" ->
    Some (Mcp_json.result id (`Assoc []))
  | Some m ->
    Some (Mcp_json.error id Mcp_json.method_not_found
            ("Method not found: " ^ m))
  | None ->
    Some (Mcp_json.error id Mcp_json.invalid_request "Invalid request")

(* --- Main loop --- *)

let () =
  (* Find and connect to rocqtui *)
  let sock_path = match Sys.argv with
    | [| _; path |] -> path
    | _ ->
      match find_socket () with
      | Some p -> p
      | None ->
        Printf.eprintf "Cannot find .rocqtui-mcp.sock. \
                         Is rocqtui running?\n%!";
        exit 1
  in
  let conn = connect sock_path in
  (* Main loop: read JSON-RPC from stdin, dispatch, write to stdout *)
  (try while true do
     let line = input_line stdin in
     if String.length line > 0 then begin
       match Mcp_json.of_line line with
       | Some msg ->
         (match dispatch conn msg with
          | Some resp ->
            print_string (Mcp_json.to_line resp);
            flush stdout
          | None -> ())
       | None ->
         let err = Mcp_json.error `Null Mcp_json.parse_error
                     "Failed to parse JSON" in
         print_string (Mcp_json.to_line err);
         flush stdout
     end
   done
   with End_of_file -> ());
  Unix.close conn.fd
