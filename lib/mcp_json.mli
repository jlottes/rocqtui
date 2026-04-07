(** JSON-RPC 2.0 helpers for MCP protocol. *)

(** {2 Message construction} *)

val error : Yojson.Safe.t -> int -> string -> Yojson.Safe.t
val result : Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
val notification : string -> Yojson.Safe.t -> Yojson.Safe.t
val request : Yojson.Safe.t -> string -> Yojson.Safe.t -> Yojson.Safe.t

(** {2 Error codes} *)

val parse_error : int
val invalid_request : int
val method_not_found : int
val invalid_params : int
val internal_error : int

(** {2 Extraction helpers} *)

val to_int_lenient : Yojson.Safe.t -> int
val to_string_opt : Yojson.Safe.t -> string option
val to_bool_opt : Yojson.Safe.t -> bool option
val member : string -> Yojson.Safe.t -> Yojson.Safe.t
val member_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option

(** {2 MCP tool response helpers} *)

val tool_result : string -> Yojson.Safe.t
val tool_result_json : Yojson.Safe.t -> Yojson.Safe.t
val tool_error : string -> Yojson.Safe.t

(** {2 MCP resource response helpers} *)

val resource_result : string -> string -> Yojson.Safe.t

(** {2 Serialization} *)

val to_line : Yojson.Safe.t -> string
val of_line : string -> Yojson.Safe.t option
