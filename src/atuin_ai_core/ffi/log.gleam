//// Host structured logging via Erlang `logger` (the layer Elixir's
//// Logger frontend feeds). Raw stdio would bypass the host's log
//// pipeline — no severity, invisible to level-based filtering and
//// alerting — so warnings must go through here.

@external(erlang, "atuin_ai_log_ffi", "error")
pub fn error(message: String) -> Nil

@external(erlang, "atuin_ai_log_ffi", "warning")
pub fn warning(message: String) -> Nil

@external(erlang, "atuin_ai_log_ffi", "info")
pub fn info(message: String) -> Nil

@external(erlang, "atuin_ai_log_ffi", "debug")
pub fn debug(message: String) -> Nil
