//// JSON encoding via Erlang/OTP's built-in `json` module (the same encoder
//// `gleam_json` is built on), so it runs without the Elixir runtime — e.g.
//// under `gleam test` — rather than calling into the host app's Jason.

import gleam/dynamic.{type Dynamic}

@external(erlang, "atuin_ai_json_ffi", "encode")
pub fn encode(value: Dynamic) -> String
