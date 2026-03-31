(* Editor context: dependencies injected from main.ml.
   Replaces callback refs and global setters. *)

type t = {
  switch_tab : int -> unit;
  open_files : unit -> string list;
  modal : Modal.t;
  mutable status_extra : string;
  mutable init_error : string;
  mutable theme_name : string;
}

let create
    ~switch_tab
    ~open_files
    () =
  { switch_tab;
    open_files;
    modal = Modal.create ();
    status_extra = "";
    init_error = "";
    theme_name = "solarized-dark" }
