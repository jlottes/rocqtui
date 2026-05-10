type color = Grid.color

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

  (* Search-match overlays *)
  search_match_bg : color;
  search_current_bg : color;
  search_current_fg : color;
}

(* Shorthand constructors *)
let c n = Grid.Color256 n  (* 256-color *)
let d = Grid.Default        (* terminal default *)
let rgb r g b = Grid.TrueColor (r, g, b)

(* --- Solarized color palette --- *)
let sol_base03  = c 234    (* #002b36 - darkest bg *)
let sol_base02  = c 235    (* #073642 - dark bg *)
let sol_base01  = c 240    (* #586e75 - dark content / light emphasis *)
let sol_base00  = c 241    (* #657b83 *)
let _sol_base0  = c 244    (* #839496 - default text *)
let sol_base1   = c 245    (* #93a1a1 - light content *)
let _sol_base2  = c 254    (* #eee8d5 *)
let _sol_base3  = c 230    (* #fdf6e3 - lightest bg *)
let sol_yellow  = c 136    (* #b58900 *)
let sol_orange  = c 166    (* #cb4b16 *)
let sol_red     = c 160    (* #dc322f *)
let sol_magenta = c 125    (* #d33682 *)
let _sol_violet = c 61     (* #6c71c4 *)
let sol_blue    = c 33   (* #268bd2 *)
let sol_cyan    = c 37   (* #2aa198 *)
let _sol_green  = c 64   (* #859900 *)

let solarized_dark = {
  name = "solarized-dark";
  bg = d;
  keyword_fg = sol_blue;
  tactic_fg = sol_cyan;
  comment_fg = sol_base01;
  string_fg = sol_yellow;
  bullet_fg = sol_orange;
  number_fg = sol_magenta;
  default_fg = d;
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
  search_match_bg = sol_base02;
  search_current_bg = sol_yellow;
  search_current_fg = sol_base03;
}

let solarized_light = {
  name = "solarized-light";
  bg = c 230;
  keyword_fg = sol_blue;
  tactic_fg = sol_cyan;
  comment_fg = sol_base1;
  string_fg = sol_yellow;
  bullet_fg = sol_orange;
  number_fg = sol_magenta;
  default_fg = sol_base00;
  verified_bg = rgb 0xe0 0xee 0xd0;  (* sol_base3 + subtle green tint *)
  verified_fg = sol_base01;
  error_bg = sol_red;
  error_fg = c 230;
  processing_bg = rgb 0xee 0xe8 0xc5;  (* sol_base3 + subtle warm tint *)
  processing_fg = sol_base01;
  status_bg = c 254;
  status_fg = sol_base01;
  border_fg = sol_base1;
  selection_bg = sol_base1;
  selection_fg = c 230;
  search_match_bg = c 254;  (* sol_base2 — subtle warm tint *)
  search_current_bg = sol_yellow;
  search_current_fg = sol_base03;
}

(* Classic: basic 8-color theme, works on any terminal *)
let classic = {
  name = "classic";
  bg = d;
  keyword_fg = c 4;   (* blue *)
  tactic_fg = c 6;    (* cyan *)
  comment_fg = c 2;   (* green *)
  string_fg = c 3;    (* yellow *)
  bullet_fg = c 1;    (* red *)
  number_fg = c 5;    (* magenta *)
  default_fg = d;
  verified_bg = c 2;  (* green *)
  verified_fg = c 0;  (* black *)
  error_bg = c 1;     (* red *)
  error_fg = c 7;     (* white *)
  processing_bg = c 3; (* yellow *)
  processing_fg = c 0; (* black *)
  status_bg = c 6;    (* cyan *)
  status_fg = c 0;    (* black *)
  border_fg = c 6;    (* cyan *)
  selection_bg = c 4;  (* blue *)
  selection_fg = c 7;  (* white *)
  search_match_bg = c 6;  (* cyan *)
  search_current_bg = c 3;  (* yellow *)
  search_current_fg = c 0;  (* black *)
}

(* Monokai-inspired *)
let monokai = {
  name = "monokai";
  bg = c 235;
  keyword_fg = c 197;
  tactic_fg = c 81;
  comment_fg = c 242;
  string_fg = c 186;
  bullet_fg = c 208;
  number_fg = c 141;
  default_fg = c 252;
  verified_bg = rgb 0x30 0x38 0x28;  (* monokai bg + green tint *)
  verified_fg = c 252;
  error_bg = c 196;
  error_fg = c 255;
  processing_bg = rgb 0x38 0x34 0x20;  (* monokai bg + warm tint *)
  processing_fg = c 252;
  status_bg = c 238;
  status_fg = c 252;
  border_fg = c 245;
  selection_bg = c 239;
  selection_fg = c 255;
  search_match_bg = c 238;
  search_current_bg = c 220;  (* yellow *)
  search_current_fg = c 235;
}

(* Nord *)
let nord = {
  name = "nord";
  bg = c 236;
  keyword_fg = c 110;
  tactic_fg = c 108;
  comment_fg = c 60;
  string_fg = c 107;
  bullet_fg = c 173;
  number_fg = c 139;
  default_fg = c 253;
  verified_bg = rgb 0x30 0x38 0x40;  (* nord bg + subtle blue-green tint *)
  verified_fg = c 253;
  error_bg = c 131;
  error_fg = c 253;
  processing_bg = rgb 0x38 0x36 0x30;  (* nord bg + warm tint *)
  processing_fg = c 253;
  status_bg = c 238;
  status_fg = c 253;
  border_fg = c 60;
  selection_bg = c 60;
  selection_fg = c 253;
  search_match_bg = c 59;
  search_current_bg = c 179;  (* warm yellow *)
  search_current_fg = c 236;
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
  ga_search_match : Grid.attr;
  ga_search_current : Grid.attr;
  ga_tab_active : Grid.attr;
  ga_tab_inactive : Grid.attr;
  ga_gutter : Grid.attr;
  ga_marker_error : Grid.attr;
  ga_marker_warning : Grid.attr;
}

let make_attr ?(bold=false) ?(dim=false) (fg : color) (bg : color) : Grid.attr =
  { Grid.fg = fg; bg; bold; dim;
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
    ga_default_v = a theme.verified_fg theme.verified_bg;
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
    ga_search_match = a theme.default_fg theme.search_match_bg;
    ga_search_current = ab theme.search_current_fg theme.search_current_bg;
    ga_tab_active = ab theme.status_fg theme.status_bg;
    ga_tab_inactive = a theme.border_fg theme.status_bg;
    ga_gutter = make_attr theme.border_fg theme.bg;
    ga_marker_error = make_attr ~bold:true theme.error_bg theme.bg;
    ga_marker_warning = make_attr ~bold:true theme.string_fg theme.bg;
  }

let current_attrs : grid_attrs ref = ref (grid_attrs_of_theme default)

let attrs () = !current_attrs

let apply theme =
  (* No curses color pairs needed — just update Grid attrs *)
  current_attrs := grid_attrs_of_theme theme
