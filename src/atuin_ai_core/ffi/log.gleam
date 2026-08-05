//// Host structured logging via Erlang `logger` (the layer Elixir's
//// Logger frontend feeds). Raw stdio would bypass the host's log
//// pipeline — no severity, invisible to level-based filtering and
//// alerting — so warnings must go through here.

import gleam/list
import gleam/string

@external(erlang, "atuin_ai_log_ffi", "error")
pub fn error(message: String) -> Nil

@external(erlang, "atuin_ai_log_ffi", "warning")
pub fn warning(message: String) -> Nil

@external(erlang, "atuin_ai_log_ffi", "info")
pub fn info(message: String) -> Nil

@external(erlang, "atuin_ai_log_ffi", "debug")
pub fn debug(message: String) -> Nil

/// Encodes an untrusted value (e.g. a provider-supplied error message)
/// for safe interpolation into a log line: common whitespace controls
/// become visible escapes and every other C0/DEL control character is
/// dropped, so the value can't forge additional log lines or inject
/// terminal control sequences. Apply at the log site — stored copies
/// (usage records, traces) keep the raw value.
pub fn escape(value: String) -> String {
  value
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
  |> string.to_utf_codepoints
  |> list.filter(fn(cp) {
    let n = string.utf_codepoint_to_int(cp)
    n >= 0x20 && n != 0x7F
  })
  |> string.from_utf_codepoints
}
