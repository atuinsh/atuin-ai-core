//// Host structured logging via Erlang `logger` (the layer Elixir's
//// Logger frontend feeds). Raw stdio would bypass the host's log
//// pipeline — no severity, invisible to level-based filtering and
//// alerting — so warnings must go through here.

@external(erlang, "log_ffi", "warning")
pub fn warning(message: String) -> Nil
