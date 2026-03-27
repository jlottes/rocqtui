(** MCP (Model Context Protocol) server for rocqtui.
    Exposes IDE state as resources and operations as tools. *)

type t

(** Create the MCP server, listening on a Unix socket.
    [socket_path] defaults to /tmp/rocqtui-mcp-{pid}.sock *)
val create : ?socket_path:string -> unit -> t

(** Get the socket fd for inclusion in the select loop. *)
val server_fd : t -> Unix.file_descr

(** Get all client fds to watch. *)
val client_fds : t -> Unix.file_descr list

(** Accept new connections and read from existing clients.
    Call from the main loop when fds are ready.
    Returns true if any state-changing tool was invoked. *)
val handle_ready : t -> Unix.file_descr list -> Tab.manager -> bool

(** Send a notification to all connected clients. *)
val notify : t -> string -> Yojson.Safe.t -> unit

(** Clean up: close socket, remove socket file. *)
val shutdown : t -> unit

(** Get the socket path (for display/connection info). *)
val socket_path : t -> string
