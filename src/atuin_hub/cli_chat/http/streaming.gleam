//// SSE sends for the chat stream. Event names and data shapes are the wire
//// contract with released CLI clients — they must match the Elixir
//// `Streaming` module until that module is deleted at cutover.

import atuin_hub/cli_chat/domain/safety
import atuin_hub/cli_chat/domain/usage.{type Usage}
import atuin_hub/cli_chat/engine/turn.{type ToolCall, type ToolResult}
import atuin_hub/ffi/json
import atuin_hub/ffi/plug.{type PlugConn}
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub fn init_stream(
  conn: PlugConn,
  session_id: String,
) -> Result(PlugConn, String) {
  [
    #("content-type", "text/event-stream"),
    #("cache-control", "no-cache"),
    #("x-accel-buffering", "no"),
    #("x-atuin-ai-session-id", session_id),
  ]
  |> list.try_fold(conn, fn(conn, header) {
    plug.put_resp_header(conn, header.0, header.1)
  })
  |> result.try(plug.send_chunked(_, 200))
}

pub fn send_event(
  conn: PlugConn,
  event_type: String,
  data: Dynamic,
) -> Result(PlugConn, String) {
  let event_str =
    "event: " <> event_type <> "\n" <> "data: " <> json.encode(data) <> "\n\n"

  plug.chunk(conn, event_str)
}

pub fn send_text(conn: PlugConn, text: String) -> Result(PlugConn, String) {
  send_event(
    conn,
    "text",
    dynamic.properties([#(dynamic.string("content"), dynamic.string(text))]),
  )
}

pub fn send_status(conn: PlugConn, status: String) -> Result(PlugConn, String) {
  send_event(
    conn,
    "status",
    dynamic.properties([#(dynamic.string("state"), dynamic.string(status))]),
  )
}

/// Sends a tool call to the client. For suggest_command the input passes
/// through server-side safety validation first, which may override the
/// model's danger assessment.
pub fn send_tool_call(
  conn: PlugConn,
  call: ToolCall,
) -> Result(PlugConn, String) {
  let input = case call.name {
    "suggest_command" -> apply_safety_check(call.input)
    _ -> call.input
  }

  send_event(
    conn,
    "tool_call",
    dynamic.properties([
      #(dynamic.string("id"), dynamic.string(call.id)),
      #(dynamic.string("name"), dynamic.string(call.name)),
      #(dynamic.string("input"), input),
    ]),
  )
}

/// Sends a server-tool result to the client. When `store` succeeds, only
/// a reference goes over the wire — the client replays the reference
/// (`remote: true`) on its next request and the server hydrates it back.
/// When it fails (including the stateless store, which always declines),
/// the full content is sent inline instead so the conversation can still
/// continue.
pub fn send_tool_result(
  conn: PlugConn,
  result: ToolResult,
  store: fn(ToolResult) -> Result(Nil, Nil),
) -> Result(PlugConn, String) {
  let stored = store(result)

  let data = case stored {
    Ok(Nil) ->
      dynamic.properties([
        #(dynamic.string("tool_use_id"), dynamic.string(result.id)),
        #(dynamic.string("remote"), dynamic.bool(True)),
        #(
          dynamic.string("content_length"),
          dynamic.int(string.length(result.result)),
        ),
        #(dynamic.string("is_error"), dynamic.bool(result.is_error)),
      ])
    Error(Nil) ->
      dynamic.properties([
        #(dynamic.string("tool_use_id"), dynamic.string(result.id)),
        #(dynamic.string("content"), dynamic.string(result.result)),
        #(dynamic.string("is_error"), dynamic.bool(result.is_error)),
      ])
  }

  send_event(conn, "tool_result", data)
}

/// The `credits` object is additive to the wire contract: released clients
/// read only `session_id` (and ignore unknown keys), newer TUIs use it to
/// render period usage without a second request. `None` omits the key —
/// a failed snapshot must not change the shape of what old clients parse.
pub fn send_done(
  conn: PlugConn,
  session_id: String,
  usage: Usage,
  credits: Option(Dynamic),
) -> Result(PlugConn, String) {
  let base = [
    #(dynamic.string("session_id"), dynamic.string(session_id)),
    #(dynamic.string("usage"), usage_to_dynamic(usage)),
  ]

  let properties = case credits {
    option.Some(credits) ->
      list.append(base, [#(dynamic.string("credits"), credits)])
    option.None -> base
  }

  send_event(conn, "done", dynamic.properties(properties))
}

pub fn send_error(
  conn: PlugConn,
  message: String,
  code: Option(String),
) -> Result(PlugConn, String) {
  send_event(
    conn,
    "error",
    dynamic.properties([
      #(dynamic.string("message"), dynamic.string(message)),
      #(
        dynamic.string("code"),
        dynamic.string(option.unwrap(code, "internal_error")),
      ),
    ]),
  )
}

// If the model called suggest_command with a command our own keyword scan
// flags, escalate danger to high and append the server warnings to the
// notes — the LLM's self-assessment alone must not be able to present a
// destructive command as safe.
fn apply_safety_check(input: Dynamic) -> Dynamic {
  case decode.run(input, decode.at(["command"], decode.string)) {
    // No command field (conversation-only turn): pass through.
    Error(_) -> input
    Ok(command) ->
      case safety.check_safety(command) {
        safety.Safe -> input
        safety.Unsafe(warnings) -> escalate_danger(input, warnings)
      }
  }
}

fn escalate_danger(input: Dynamic, warnings: List(safety.Warning)) -> Dynamic {
  case decode.run(input, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> input
    Ok(fields) -> {
      let warning_messages =
        warnings
        |> list.map(fn(warning) { warning.message })
        |> string.join("; ")

      let existing_notes =
        dict.get(fields, "danger_notes")
        |> option.from_result
        |> option.then(fn(value) {
          decode.run(value, decode.string) |> option.from_result
        })
        |> option.unwrap("")

      let updated_notes = case existing_notes {
        "" -> "[Server Warning] " <> warning_messages
        notes -> notes <> "\n\n[Server Warning] " <> warning_messages
      }

      fields
      |> dict.insert("danger", dynamic.string("high"))
      |> dict.insert("danger_notes", dynamic.string(updated_notes))
      |> dict.to_list
      |> list.map(fn(field) { #(dynamic.string(field.0), field.1) })
      |> dynamic.properties
    }
  }
}

fn usage_to_dynamic(usage: Usage) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("input_tokens"), dynamic.int(usage.input_tokens)),
    #(dynamic.string("output_tokens"), dynamic.int(usage.output_tokens)),
    #(dynamic.string("total_tokens"), dynamic.int(usage.total_tokens)),
    #(dynamic.string("cached_tokens"), dynamic.int(usage.cached_tokens)),
    #(
      dynamic.string("cache_creation_tokens"),
      dynamic.int(usage.cache_creation_tokens),
    ),
    #(dynamic.string("input_cost"), nullable_float(usage.input_cost)),
    #(dynamic.string("output_cost"), nullable_float(usage.output_cost)),
    #(dynamic.string("total_cost"), nullable_float(usage.total_cost)),
    #(
      dynamic.string("provider_cost"),
      usage.provider_cost
        |> option.map(dynamic.int)
        |> option.unwrap(dynamic.nil()),
    ),
  ])
}

fn nullable_float(value: Option(Float)) -> Dynamic {
  value |> option.map(dynamic.float) |> option.unwrap(dynamic.nil())
}
