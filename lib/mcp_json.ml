(* JSON-RPC 2.0 helpers for MCP protocol.
   Shared between the MCP server (mcp_server.ml) and the OCaml bridge. *)

(* --- Message construction --- *)

let error id code msg =
  `Assoc [
    "jsonrpc", `String "2.0";
    "id", id;
    "error", `Assoc [
      "code", `Int code;
      "message", `String msg;
    ]
  ]

let result id value =
  `Assoc [
    "jsonrpc", `String "2.0";
    "id", id;
    "result", value;
  ]

let notification method_ params =
  `Assoc [
    "jsonrpc", `String "2.0";
    "method", `String method_;
    "params", params;
  ]

let request id method_ params =
  `Assoc [
    "jsonrpc", `String "2.0";
    "id", id;
    "method", `String method_;
    "params", params;
  ]

(* --- Error codes --- *)

let parse_error = -32700
let invalid_request = -32600
let method_not_found = -32601
let invalid_params = -32602
let internal_error = -32603

(* --- Extraction helpers --- *)

(* Robust int extraction — handles both `Int and `String "123" *)
let to_int_lenient = function
  | `Int n -> n
  | `String s -> (match int_of_string_opt s with Some n -> n | None -> 0)
  | _ -> 0

let to_string_opt = function
  | `String s -> Some s
  | _ -> None

let to_bool_opt = function
  | `Bool b -> Some b
  | _ -> None

let member key = function
  | `Assoc l -> (match List.assoc_opt key l with Some v -> v | None -> `Null)
  | _ -> `Null

let member_opt key = function
  | `Assoc l -> List.assoc_opt key l
  | _ -> None

(* --- MCP tool response helpers --- *)

(* Wrap text as an MCP tool result content block. *)
let tool_result text =
  `Assoc [
    "content", `List [
      `Assoc [
        "type", `String "text";
        "text", `String text;
      ]
    ]
  ]

(* Wrap JSON as an MCP tool result. *)
let tool_result_json json =
  `Assoc [
    "content", `List [
      `Assoc [
        "type", `String "text";
        "text", `String (Yojson.Safe.to_string json);
      ]
    ]
  ]

(* MCP tool error result. *)
let tool_error text =
  `Assoc [
    "content", `List [
      `Assoc [
        "type", `String "text";
        "text", `String text;
      ]
    ];
    "isError", `Bool true;
  ]

(* --- MCP resource response helpers --- *)

let resource_result uri text =
  `Assoc [
    "contents", `List [
      `Assoc [
        "uri", `String uri;
        "text", `String text;
      ]
    ]
  ]

(* --- Serialization --- *)

let to_line json =
  Yojson.Safe.to_string json ^ "\n"

let of_line line =
  try Some (Yojson.Safe.from_string line)
  with _ -> None
