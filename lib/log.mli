(* Lightweight file logger gated by the ROCQTUI_LOG env var.

   Set ROCQTUI_LOG to a file path to log there, or to "1"/"true"/"yes"
   to log to /tmp/rocqtui.log. Unset / "" / "0" / "false" / "no"
   disables it. No-op and near-zero cost when disabled.

   Each emitted line is prefixed with seconds since process start and
   flushed immediately, so the log survives a hang or crash — important
   for diagnosing stuck-state bugs where the process never exits
   cleanly. The file is truncated on first write, so each run starts
   with a clean log. *)

val enabled : unit -> bool

(* printf-style. Emits one timestamped, flushed line when enabled;
   discards its arguments cheaply when disabled. *)
val logf : ('a, unit, string, unit) format4 -> 'a
