type color = int

type t = {
  name : string;
  bg : color;
  keyword_fg : color;
  tactic_fg : color;
  comment_fg : color;
  string_fg : color;
  bullet_fg : color;
  number_fg : color;
  default_fg : color;
  verified_bg : color;
  verified_fg : color;
  error_bg : color;
  error_fg : color;
  processing_bg : color;
  processing_fg : color;
  status_bg : color;
  status_fg : color;
  border_fg : color;
  selection_bg : color;
  selection_fg : color;
}

(* --- Solarized color palette (256-color approximations) --- *)
(* Base colors *)
let sol_base03  = 234  (* #002b36 - darkest bg *)
let sol_base02  = 235  (* #073642 - dark bg *)
let sol_base01  = 240  (* #586e75 - dark content / light emphasis *)
let sol_base00  = 241  (* #657b83 *)
let sol_base0   = 244  (* #839496 - default text *)
let sol_base1   = 245  (* #93a1a1 - light content *)
let _sol_base2  = 254  (* #eee8d5 *)
let _sol_base3  = 230  (* #fdf6e3 - lightest bg *)
let sol_yellow  = 136  (* #b58900 *)
let sol_orange  = 166  (* #cb4b16 *)
let sol_red     = 160  (* #dc322f *)
let sol_magenta = 125  (* #d33682 *)
let _sol_violet = 61   (* #6c71c4 *)
let sol_blue    = 33   (* #268bd2 *)
let sol_cyan    = 37   (* #2aa198 *)
let _sol_green  = 64   (* #859900 *)

let solarized_dark = {
  name = "solarized-dark";
  bg = sol_base03;
  keyword_fg = sol_blue;
  tactic_fg = sol_cyan;
  comment_fg = sol_base01;
  string_fg = sol_yellow;
  bullet_fg = sol_orange;
  number_fg = sol_magenta;
  default_fg = sol_base0;
  verified_bg = sol_base02;
  verified_fg = sol_base1;
  error_bg = sol_red;
  error_fg = sol_base03;
  processing_bg = sol_base02;
  processing_fg = sol_yellow;
  status_bg = sol_base02;
  status_fg = sol_base1;
  border_fg = sol_base01;
  selection_bg = sol_base01;
  selection_fg = sol_base03;
}

let solarized_light = {
  name = "solarized-light";
  bg = 230;  (* sol_base3 *)
  keyword_fg = sol_blue;
  tactic_fg = sol_cyan;
  comment_fg = sol_base1;
  string_fg = sol_yellow;
  bullet_fg = sol_orange;
  number_fg = sol_magenta;
  default_fg = sol_base00;
  verified_bg = 254;  (* sol_base2 *)
  verified_fg = sol_base01;
  error_bg = sol_red;
  error_fg = 230;
  processing_bg = 254;
  processing_fg = sol_yellow;
  status_bg = 254;
  status_fg = sol_base01;
  border_fg = sol_base1;
  selection_bg = sol_base1;
  selection_fg = 230;
}

(* Classic: basic 8-color theme, works on any terminal *)
let classic = {
  name = "classic";
  bg = -1;
  keyword_fg = 4;   (* blue *)
  tactic_fg = 6;    (* cyan *)
  comment_fg = 2;   (* green *)
  string_fg = 3;    (* yellow *)
  bullet_fg = 1;    (* red *)
  number_fg = 5;    (* magenta *)
  default_fg = -1;
  verified_bg = 2;  (* green *)
  verified_fg = 0;  (* black *)
  error_bg = 1;     (* red *)
  error_fg = 7;     (* white *)
  processing_bg = 3; (* yellow *)
  processing_fg = 0; (* black *)
  status_bg = 6;    (* cyan *)
  status_fg = 0;    (* black *)
  border_fg = 6;    (* cyan *)
  selection_bg = 4;  (* blue *)
  selection_fg = 7;  (* white *)
}

(* Monokai-inspired *)
let monokai = {
  name = "monokai";
  bg = 235;
  keyword_fg = 197;  (* pinkish red *)
  tactic_fg = 81;    (* light blue *)
  comment_fg = 242;  (* gray *)
  string_fg = 186;   (* light yellow *)
  bullet_fg = 208;   (* orange *)
  number_fg = 141;   (* purple *)
  default_fg = 252;
  verified_bg = 237;
  verified_fg = 252;
  error_bg = 196;
  error_fg = 255;
  processing_bg = 58;
  processing_fg = 252;
  status_bg = 238;
  status_fg = 252;
  border_fg = 245;
  selection_bg = 239;
  selection_fg = 255;
}

(* Nord *)
let nord = {
  name = "nord";
  bg = 236;       (* polar night *)
  keyword_fg = 110; (* frost blue *)
  tactic_fg = 108;  (* frost green *)
  comment_fg = 60;  (* muted *)
  string_fg = 107;  (* aurora green *)
  bullet_fg = 173;  (* aurora orange *)
  number_fg = 139;  (* aurora purple *)
  default_fg = 253;
  verified_bg = 238;
  verified_fg = 253;
  error_bg = 131;   (* aurora red *)
  error_fg = 253;
  processing_bg = 238;
  processing_fg = 222; (* aurora yellow *)
  status_bg = 238;
  status_fg = 253;
  border_fg = 60;
  selection_bg = 60;
  selection_fg = 253;
}

let default = solarized_dark

let themes = [classic; solarized_dark; solarized_light; monokai; nord]

let available = List.map (fun t -> t.name) themes

let find name =
  match List.find_opt (fun t -> t.name = name) themes with
  | Some t -> t
  | None -> default

(* Legacy color pair assignments — kept for API compat *)
let pair_selection = 31

(* --- Grid.attr equivalents --- *)

type grid_attrs = {
  ga_keyword : Grid.attr;
  ga_tactic : Grid.attr;
  ga_comment : Grid.attr;
  ga_string : Grid.attr;
  ga_bullet : Grid.attr;
  ga_number : Grid.attr;
  ga_default : Grid.attr;
  (* Region variants *)
  ga_keyword_v : Grid.attr;
  ga_tactic_v : Grid.attr;
  ga_comment_v : Grid.attr;
  ga_string_v : Grid.attr;
  ga_bullet_v : Grid.attr;
  ga_number_v : Grid.attr;
  ga_default_v : Grid.attr;
  ga_keyword_p : Grid.attr;
  ga_tactic_p : Grid.attr;
  ga_comment_p : Grid.attr;
  ga_string_p : Grid.attr;
  ga_bullet_p : Grid.attr;
  ga_number_p : Grid.attr;
  ga_default_p : Grid.attr;
  (* UI *)
  ga_verified : Grid.attr;
  ga_processing : Grid.attr;
  ga_error : Grid.attr;
  ga_status : Grid.attr;
  ga_border : Grid.attr;
  ga_selection : Grid.attr;
  ga_tab_active : Grid.attr;
  ga_tab_inactive : Grid.attr;
}

let gc (c : int) : Grid.color =
  if c = -1 then Grid.Default else Grid.Color256 c

let make_attr ?(bold=false) fg bg : Grid.attr =
  { Grid.fg = gc fg; bg = gc bg; bold; dim = false;
    reverse = false; underline = false }

let grid_attrs_of_theme (theme : t) : grid_attrs =
  let a fg bg = make_attr fg bg in
  let ab fg bg = make_attr ~bold:true fg bg in
  { ga_keyword = ab theme.keyword_fg theme.bg;
    ga_tactic = a theme.tactic_fg theme.bg;
    ga_comment = a theme.comment_fg theme.bg;
    ga_string = a theme.string_fg theme.bg;
    ga_bullet = ab theme.bullet_fg theme.bg;
    ga_number = a theme.number_fg theme.bg;
    ga_default = a theme.default_fg theme.bg;
    ga_keyword_v = ab theme.keyword_fg theme.verified_bg;
    ga_tactic_v = a theme.tactic_fg theme.verified_bg;
    ga_comment_v = a theme.comment_fg theme.verified_bg;
    ga_string_v = a theme.string_fg theme.verified_bg;
    ga_bullet_v = ab theme.bullet_fg theme.verified_bg;
    ga_number_v = a theme.number_fg theme.verified_bg;
    ga_default_v = a theme.default_fg theme.verified_bg;
    ga_keyword_p = ab theme.keyword_fg theme.processing_bg;
    ga_tactic_p = a theme.tactic_fg theme.processing_bg;
    ga_comment_p = a theme.comment_fg theme.processing_bg;
    ga_string_p = a theme.string_fg theme.processing_bg;
    ga_bullet_p = ab theme.bullet_fg theme.processing_bg;
    ga_number_p = a theme.number_fg theme.processing_bg;
    ga_default_p = a theme.processing_fg theme.processing_bg;
    ga_verified = a theme.verified_fg theme.verified_bg;
    ga_processing = a theme.processing_fg theme.processing_bg;
    ga_error = a theme.error_fg theme.error_bg;
    ga_status = a theme.status_fg theme.status_bg;
    ga_border = a theme.border_fg theme.bg;
    ga_selection = a theme.selection_fg theme.selection_bg;
    ga_tab_active = ab theme.status_fg theme.status_bg;
    ga_tab_inactive = a theme.border_fg theme.bg;
  }

let current_attrs : grid_attrs ref = ref (grid_attrs_of_theme default)

let attrs () = !current_attrs

let apply theme =
  (* No curses color pairs needed — just update Grid attrs *)
  current_attrs := grid_attrs_of_theme theme
