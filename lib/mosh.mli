(** Detect whether rocqtui is running under mosh.

    Result is cached on first call.  Override with the [ROCQTUI_MOSH] env
    var ("0"/"false" to force off, any other value to force on, unset to
    auto-detect via /proc). *)

val is_active : unit -> bool
