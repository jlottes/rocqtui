(** Step-by-step project-wide search scanner.

    Lives in the main loop alongside [Build] and [Dep_runner]: [start]
    kicks off a scan, [step] is called each tick to consume a small
    batch of files. No threads, no subprocess. *)

type t

val create : unit -> t

(** Begin (or restart) a project-wide scan against [project_dir] /
    [project_file], matching [query] under [flags]. Cancels any
    in-flight scan. *)
val start :
  t ->
  project_dir:string ->
  project_file:string ->
  query:string ->
  flags:Search.flags ->
  unit

(** Cancel an in-flight scan and drop its results. *)
val cancel : t -> unit

(** Run one scan tick. Returns [true] when a file with matches was
    added, or when the scan transitions to finished — the panel
    should re-render in both cases. *)
val step : t -> bool

(** The current result set, or [None] if no scan has ever started. *)
val results : t -> Search_results.t option

(** True while files remain to scan. *)
val scanning : t -> bool
