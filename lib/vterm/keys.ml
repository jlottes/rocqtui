(* Key identity codes matching keys.h in the vendored vterm.
   Text keys use their Unicode codepoint; functional keys use PUA
   codepoints following the kitty keyboard protocol where defined. *)

(* basic control keys *)
let escape    = 27
let enter     = 13
let tab       = 9
let backspace = 127

(* navigation and arrow keys (our PUA assignments, 57344-57354) *)
let up        = 57344
let down      = 57345
let right     = 57346
let left      = 57347
let home      = 57348
let end_      = 57349
let insert    = 57350
let delete    = 57351
let page_up   = 57352
let page_down = 57353

(* F1-F12 (our PUA assignments, 57364-57375) *)
let f1  = 57364
let f2  = 57365
let f3  = 57366
let f4  = 57367
let f5  = 57368
let f6  = 57369
let f7  = 57370
let f8  = 57371
let f9  = 57372
let f10 = 57373
let f11 = 57374
let f12 = 57375

(* F13-F20 (kitty-assigned) *)
let f13 = 57376
let f14 = 57377
let f15 = 57378
let f16 = 57379
let f17 = 57380
let f18 = 57381
let f19 = 57382
let f20 = 57383
