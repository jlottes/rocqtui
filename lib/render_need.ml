type t = No | Yes | Full

let state = ref Full

let request () =
  if !state = No then state := Yes

let request_full () =
  state := Full

let take () =
  let v = !state in
  state := No;
  v
