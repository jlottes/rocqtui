(** Static dependency graph over the .v files of a Rocq project.

    All paths are project-relative .v paths (e.g. "theory/groups.v");
    the parser converts the .vo paths emitted by [rocq dep] for us. *)

type t

(** Empty graph; useful for tests. *)
val empty : unit -> t

(** Parse the Makefile-style output of [rocq dep -f _RocqProject].
    Each rule [target.vo: source.v dep.vo ...] contributes node
    [target.v] plus an edge [dep.v -> target.v] for every .vo
    dependency. Unrecognised lines are silently skipped. *)
val of_rocq_dep_output : string -> t

(** All nodes (in insertion order). *)
val nodes : t -> string list

val has : t -> string -> bool

(** Project files in dependency order (dependencies before dependents).
    Tie-breaks deterministically by insertion order. Tolerates cycles
    by appending any unsortable remainder in insertion order. *)
val toposort : t -> string list

(** Files that depend transitively on [start] (i.e. would need
    rebuilding if [start] changes). Excludes [start] itself.
    Returns [[]] if [start] is not in the graph. *)
val descendants : t -> string -> string list

(** Files [start] depends on transitively. Excludes [start] itself.
    Returns [[]] if [start] is not in the graph. *)
val ancestors : t -> string -> string list

(** [start] union [ancestors start] union [descendants start]. Empty
    when [start] is not in the graph. *)
val closure_bidirectional : t -> string -> string list

(** Add a single edge. Useful for tests; the parser uses this
    internally. *)
val add_edge : t -> dep:string -> dependent:string -> unit
