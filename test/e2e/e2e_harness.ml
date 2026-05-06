(* End-to-end test harness for rocqtui's MCP bridge.

   Spawns a headless rocqtui process on a sample .v file, then spawns
   the bridge subprocess connected to its socket. JSON-RPC messages
   travel over the bridge's stdio (matching how an MCP client like
   Claude Code talks to it).

   Each test gets its own temp dir + socket, so they can run in
   parallel without collisions. *)

(* --- Locating built binaries --- *)

let find_binary name env_var rel_path =
  match Sys.getenv_opt env_var with
  | Some p when Sys.file_exists p -> p
  | _ ->
    let cwd = Sys.getcwd () in
    let rec walk dir =
      let candidate = Filename.concat dir rel_path in
      if Sys.file_exists candidate then candidate
      else
        let parent = Filename.dirname dir in
        if parent = dir then
          failwith (Printf.sprintf
            "Cannot locate %s — set %s or run from project root \
             (looked for %s walking up from %s)"
            name env_var rel_path cwd)
        else walk parent
    in
    walk cwd

let rocqtui_bin () =
  find_binary "rocqtui" "ROCQTUI_BIN" "_build/default/bin/main.exe"

let bridge_bin () =
  find_binary "rocqtui_mcp bridge" "ROCQTUI_BRIDGE_BIN"
    "_build/default/bridge/rocqtui_mcp.exe"

(* --- Temp dir + sample file --- *)

let make_tmpdir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  dir

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

(* --- Subprocess management --- *)

type session = {
  rocqtui_pid : int;
  rocqtui_log : Unix.file_descr;     (* stderr/stdout merged *)
  bridge_pid : int;
  bridge_in : out_channel;            (* we write JSON-RPC requests here *)
  bridge_out : in_channel;            (* we read JSON-RPC responses here *)
  bridge_log : Unix.file_descr;
  socket_path : string;
  tmpdir : string;
  mutable next_id : int;
}

let wait_for_socket path timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if Sys.file_exists path then ()
    else if Unix.gettimeofday () > deadline then
      failwith (Printf.sprintf "Timeout waiting for socket %s" path)
    else begin
      Unix.sleepf 0.05;
      loop ()
    end
  in
  loop ()

let start ?(rocq_filename="sample.v") ~rocq_source () =
  let tmpdir = make_tmpdir "rocqtui-e2e-" in
  let v_path = Filename.concat tmpdir rocq_filename in
  write_file v_path rocq_source;
  let socket_path = Filename.concat tmpdir "test.sock" in
  let rocqtui_log_path = Filename.concat tmpdir "rocqtui.log" in
  let bridge_log_path = Filename.concat tmpdir "bridge.log" in
  let rocqtui_log =
    Unix.openfile rocqtui_log_path
      [Unix.O_RDWR; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let rocqtui_pid =
    Unix.create_process (rocqtui_bin ())
      [| rocqtui_bin (); "--headless";
         "--socket-path"; socket_path;
         v_path |]
      (Unix.openfile "/dev/null" [Unix.O_RDONLY] 0)
      rocqtui_log rocqtui_log
  in
  (try wait_for_socket socket_path 10.0
   with e ->
     (try Unix.kill rocqtui_pid Sys.sigterm with _ -> ());
     raise e);
  (* Now spawn the bridge. We give it pipes for stdin (we write requests)
     and stdout (we read responses). Stderr → log file. *)
  let bridge_in_r, bridge_in_w = Unix.pipe ~cloexec:true () in
  let bridge_out_r, bridge_out_w = Unix.pipe ~cloexec:true () in
  let bridge_log =
    Unix.openfile bridge_log_path
      [Unix.O_RDWR; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  Unix.clear_close_on_exec bridge_in_r;
  Unix.clear_close_on_exec bridge_out_w;
  let bridge_pid =
    Unix.create_process (bridge_bin ())
      [| bridge_bin (); socket_path |]
      bridge_in_r bridge_out_w bridge_log
  in
  Unix.close bridge_in_r;
  Unix.close bridge_out_w;
  let bridge_in = Unix.out_channel_of_descr bridge_in_w in
  let bridge_out = Unix.in_channel_of_descr bridge_out_r in
  { rocqtui_pid; rocqtui_log;
    bridge_pid; bridge_in; bridge_out; bridge_log;
    socket_path; tmpdir;
    next_id = 1 }

let dump_logs s =
  let dump label fd =
    Unix.lseek fd 0 Unix.SEEK_SET |> ignore;
    let buf = Buffer.create 4096 in
    let bytes = Bytes.create 4096 in
    let rec loop () =
      let n = try Unix.read fd bytes 0 4096 with _ -> 0 in
      if n > 0 then begin
        Buffer.add_subbytes buf bytes 0 n;
        loop ()
      end
    in
    loop ();
    let s = Buffer.contents buf in
    if s <> "" then begin
      Printf.eprintf "=== %s ===\n%s\n" label s;
      if not (String.length s > 0 && s.[String.length s - 1] = '\n') then
        Printf.eprintf "\n"
    end
  in
  dump "rocqtui log" s.rocqtui_log;
  dump "bridge log" s.bridge_log

let stop ?(rm_tmpdir=true) s =
  (try close_out s.bridge_in with _ -> ());
  (try close_in s.bridge_out with _ -> ());
  let kill pid =
    (try Unix.kill pid Sys.sigterm with _ -> ());
    let deadline = Unix.gettimeofday () +. 3.0 in
    let rec wait () =
      match Unix.waitpid [Unix.WNOHANG] pid with
      | 0, _ ->
        if Unix.gettimeofday () > deadline then
          (try Unix.kill pid Sys.sigkill with _ -> ())
        else begin
          Unix.sleepf 0.05;
          wait ()
        end
      | _ -> ()
    in
    wait ()
  in
  kill s.bridge_pid;
  kill s.rocqtui_pid;
  Unix.close s.rocqtui_log;
  Unix.close s.bridge_log;
  if rm_tmpdir then begin
    let cmd = Printf.sprintf "rm -rf %s"
      (Filename.quote s.tmpdir) in
    ignore (Sys.command cmd)
  end

(* --- JSON-RPC over the bridge --- *)

let send_raw s json =
  let line = Yojson.Safe.to_string json in
  if Sys.getenv_opt "ROCQTUI_E2E_TRACE" <> None then
    Printf.eprintf "-> %s\n%!" line;
  output_string s.bridge_in line;
  output_char s.bridge_in '\n';
  flush s.bridge_in

let recv_raw s =
  let line = input_line s.bridge_out in
  if Sys.getenv_opt "ROCQTUI_E2E_TRACE" <> None then
    Printf.eprintf "<- %s\n%!" line;
  line

let request s ?(params=`Null) method_ =
  let id = s.next_id in
  s.next_id <- id + 1;
  let req = `Assoc [
    "jsonrpc", `String "2.0";
    "id", `Int id;
    "method", `String method_;
    "params", params;
  ] in
  send_raw s req;
  let line = recv_raw s in
  Yojson.Safe.from_string line

let initialize s =
  let req = `Assoc [
    "jsonrpc", `String "2.0";
    "id", `Int 0;
    "method", `String "initialize";
    "params", `Assoc [
      "protocolVersion", `String "2024-11-05";
      "capabilities", `Assoc [];
      "clientInfo", `Assoc [
        "name", `String "rocqtui-e2e";
        "version", `String "0.0";
      ];
    ];
  ] in
  send_raw s req;
  let _ = recv_raw s in
  let notif = `Assoc [
    "jsonrpc", `String "2.0";
    "method", `String "notifications/initialized";
    "params", `Assoc [];
  ] in
  send_raw s notif

let call_tool s ?(args=`Assoc []) name =
  request s "tools/call"
    ~params:(`Assoc [
      "name", `String name;
      "arguments", args;
    ])

(* Extract the textual content of a tools/call response, treating it as
   the bridge's response JSON object (which is the tool's "structured"
   result, not the raw JSON-RPC envelope). The bridge wraps tool output
   in {result: { ... }} per JSON-RPC. *)
let result_of response =
  match response with
  | `Assoc fields ->
    (match List.assoc_opt "result" fields with
     | Some r -> r
     | None ->
       failwith (Printf.sprintf "No result in response: %s"
         (Yojson.Safe.to_string response)))
  | _ -> failwith "Response not an object"

let extract_content_text result =
  let open Yojson.Safe.Util in
  match member "content" result with
  | `List ((`Assoc c) :: _) ->
    (match List.assoc_opt "text" c with
     | Some (`String txt) -> Some txt
     | _ -> None)
  | _ -> None

(* Bridge tools return [{content: [{type:"text", text:"<json>"}]}].
   The text is the tool's response object encoded as JSON. On a tool
   error the text is a plain-language message and [isError:true] is set;
   we surface that as a Failure rather than parsing the text. *)
let structured_response result =
  let open Yojson.Safe.Util in
  let is_error = match member "isError" result with
    | `Bool true -> true | _ -> false
  in
  if is_error then begin
    let text = match extract_content_text result with
      | Some t -> t | None -> Yojson.Safe.to_string result in
    failwith ("tool returned isError=true: " ^ text)
  end;
  match extract_content_text result with
  | Some txt ->
    (try Yojson.Safe.from_string txt
     with Yojson.Json_error _ ->
       failwith ("tool result text is not JSON: " ^ txt))
  | None -> result

(* --- Assertions --- *)

let fail msg = failwith ("assertion failed: " ^ msg)

let assert_contains ~haystack ~needle =
  let h = String.length haystack in
  let n = String.length needle in
  if n = 0 then ()
  else
    let found = ref false in
    let i = ref 0 in
    while not !found && !i + n <= h do
      if String.sub haystack !i n = needle then found := true;
      incr i
    done;
    if not !found then
      fail (Printf.sprintf "expected %S to contain %S"
        (if String.length haystack > 200
         then String.sub haystack 0 200 ^ "...[truncated]"
         else haystack)
        needle)

let assert_not_equal_strings ~a ~b ~msg =
  if a = b then fail msg
