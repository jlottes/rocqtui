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
  keyword_fg = Curses.Color.blue;
  tactic_fg = Curses.Color.cyan;
  comment_fg = Curses.Color.green;
  string_fg = Curses.Color.yellow;
  bullet_fg = Curses.Color.red;
  number_fg = Curses.Color.magenta;
  default_fg = -1;
  verified_bg = Curses.Color.green;
  verified_fg = Curses.Color.black;
  error_bg = Curses.Color.red;
  error_fg = Curses.Color.white;
  processing_bg = Curses.Color.yellow;
  processing_fg = Curses.Color.black;
  status_bg = Curses.Color.cyan;
  status_fg = Curses.Color.black;
  border_fg = Curses.Color.cyan;
  selection_bg = Curses.Color.blue;
  selection_fg = Curses.Color.white;
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

(* Color pair assignments — must match highlight.ml constants *)
let pair_verified = 1
let pair_processing = 2
let pair_error = 3
let pair_status = 4
let pair_border = 5
let pair_keyword = 6
let pair_tactic = 7
let pair_comment = 8
let pair_string = 9
let pair_bullet = 10
let pair_number = 11
(* Verified-region syntax variants *)
let pair_keyword_v = 16
let pair_tactic_v = 17
let pair_comment_v = 18
let pair_string_v = 19
let pair_bullet_v = 20
let pair_number_v = 21
let pair_default_v = 22
(* Processing-region syntax variants *)
let pair_keyword_p = 24
let pair_tactic_p = 25
let pair_comment_p = 26
let pair_string_p = 27
let pair_bullet_p = 28
let pair_number_p = 29
let pair_default_p = 30
let pair_selection = 31

let apply theme =
  let _ = Curses.use_default_colors () in
  (* UI pairs *)
  let _ = Curses.init_pair pair_verified theme.verified_fg theme.verified_bg in
  let _ = Curses.init_pair pair_processing theme.processing_fg theme.processing_bg in
  let _ = Curses.init_pair pair_error theme.error_fg theme.error_bg in
  let _ = Curses.init_pair pair_status theme.status_fg theme.status_bg in
  let _ = Curses.init_pair pair_border theme.border_fg theme.bg in
  (* Syntax pairs — normal background *)
  let _ = Curses.init_pair pair_keyword theme.keyword_fg theme.bg in
  let _ = Curses.init_pair pair_tactic theme.tactic_fg theme.bg in
  let _ = Curses.init_pair pair_comment theme.comment_fg theme.bg in
  let _ = Curses.init_pair pair_string theme.string_fg theme.bg in
  let _ = Curses.init_pair pair_bullet theme.bullet_fg theme.bg in
  let _ = Curses.init_pair pair_number theme.number_fg theme.bg in
  (* Syntax pairs — verified background *)
  let _ = Curses.init_pair pair_keyword_v theme.keyword_fg theme.verified_bg in
  let _ = Curses.init_pair pair_tactic_v theme.tactic_fg theme.verified_bg in
  let _ = Curses.init_pair pair_comment_v theme.comment_fg theme.verified_bg in
  let _ = Curses.init_pair pair_string_v theme.string_fg theme.verified_bg in
  let _ = Curses.init_pair pair_bullet_v theme.bullet_fg theme.verified_bg in
  let _ = Curses.init_pair pair_number_v theme.number_fg theme.verified_bg in
  let _ = Curses.init_pair pair_default_v theme.default_fg theme.verified_bg in
  (* Syntax pairs — processing background *)
  let _ = Curses.init_pair pair_keyword_p theme.keyword_fg theme.processing_bg in
  let _ = Curses.init_pair pair_tactic_p theme.tactic_fg theme.processing_bg in
  let _ = Curses.init_pair pair_comment_p theme.comment_fg theme.processing_bg in
  let _ = Curses.init_pair pair_string_p theme.string_fg theme.processing_bg in
  let _ = Curses.init_pair pair_bullet_p theme.bullet_fg theme.processing_bg in
  let _ = Curses.init_pair pair_number_p theme.number_fg theme.processing_bg in
  let _ = Curses.init_pair pair_default_p theme.processing_fg theme.processing_bg in
  let _ = Curses.init_pair pair_selection theme.selection_fg theme.selection_bg in
  ()
