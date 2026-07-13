//// Pure turn-level domain types and decisions: tool-call classification,
//// session summaries, and human-readable tool summaries.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string

/// A tool invocation requested by the model. `input` is the raw argument
/// object — opaque JSON decoded at the boundary into a string-keyed map.
pub type ToolCall {
  ToolCall(id: String, name: String, input: Dynamic)
}

/// The outcome of executing one server-side tool.
pub type ToolResult {
  ToolResult(id: String, name: String, result: String, is_error: Bool)
}

/// What the model produced for one loop iteration, decoded from the
/// provider response at the boundary.
pub type LlmResponse {
  LlmResponse(
    text: String,
    reasoning: Option(String),
    tool_calls: List(ToolCall),
  )
}

/// How the loop should proceed after a model response.
pub type Disposition {
  /// Neither tools nor text (empty stop, filtered content) — completing
  /// would record a successful turn the client renders as silence, so the
  /// loop retries the same request instead, bounded by the iteration cap.
  EmptyResponse
  /// A plain text response completes the turn.
  TextOnly
  /// suggest_command is the final answer.
  FinalSuggest
  /// Client-side tools need the client to execute; any server tools run
  /// first, before handing off.
  NeedsClientTools(server: List(ToolCall), client: List(ToolCall))
  /// Only server-side tools — execute them and continue the loop.
  ServerToolsOnly(server: List(ToolCall))
}

/// Classifies a model response by what must happen next. `is_server_tool`
/// comes from the instance's registrations — the engine has no compiled-in
/// notion of which tools the server executes.
pub fn classify(
  response: LlmResponse,
  is_server_tool: fn(String) -> Bool,
) -> Disposition {
  let tool_calls = response.tool_calls
  let has_suggest =
    list.any(tool_calls, fn(tool) { tool.name == "suggest_command" })
  let #(server, client_or_suggest) =
    list.partition(tool_calls, fn(tool) { is_server_tool(tool.name) })
  let client =
    list.filter(client_or_suggest, fn(tool) { tool.name != "suggest_command" })

  case tool_calls, string.trim(response.text) {
    [], "" -> EmptyResponse
    [], _text -> TextOnly
    _, _ ->
      case has_suggest, client {
        True, _ -> FinalSuggest
        False, [_, ..] -> NeedsClientTools(server:, client:)
        False, [] -> ServerToolsOnly(server:)
      }
  }
}

/// Metadata for a completed turn. The command fields come from the
/// suggest_command input when the model suggested a command; a text-only
/// completion carries only the turn count.
pub type SessionSummary {
  SessionSummary(
    confidence: Option(String),
    confidence_notes: Option(String),
    danger: Option(String),
    danger_notes: Option(String),
    turn_count: Int,
  )
}

pub fn build_session_summary(
  tool_calls: List(ToolCall),
  turn_count: Int,
) -> SessionSummary {
  let input =
    tool_calls
    |> list.find(fn(tool) { tool.name == "suggest_command" })
    |> result.map(fn(tool) { tool.input })

  SessionSummary(
    confidence: input_field(input, "confidence"),
    confidence_notes: input_field(input, "confidence_notes"),
    danger: input_field(input, "danger"),
    danger_notes: input_field(input, "danger_notes"),
    turn_count: turn_count,
  )
}

fn input_field(input: Result(Dynamic, Nil), key: String) -> Option(String) {
  case input {
    Error(Nil) -> None
    Ok(input) ->
      decode.run(input, decode.at([key], decode.string))
      |> option.from_result
  }
}

/// Attaches a human-readable summary to a tool call, for analytics
/// recording.
pub type SummarizedToolCall {
  SummarizedToolCall(call: ToolCall, summary: String)
}

pub fn summarize(call: ToolCall) -> SummarizedToolCall {
  SummarizedToolCall(call: call, summary: tool_summary(call))
}

// Each tool summarizes a specific input key; a tool whose key is absent
// (including read_file, whose schema says file_path while the summary
// historically looked for path) falls through to the generic line.
fn tool_summary(call: ToolCall) -> String {
  case call.name, input_string(call.input, summary_key(call.name)) {
    "web_search", Ok(query) ->
      "[TOOL] Searched for \"" <> truncate(query, 100) <> "\""
    "web_scrape", Ok(url) -> "[TOOL] Scraped " <> truncate(url, 100)
    "atuin_history", Ok(query) ->
      "[TOOL] Searched history for \"" <> truncate(query, 100) <> "\""
    "atuin_output", Ok(id) ->
      "[TOOL] Read output for history #" <> truncate(id, 40)
    "read_file", Ok(path) ->
      "[TOOL] Read file \"" <> truncate(path, 100) <> "\""
    "suggest_command", Ok(command) ->
      "[TOOL] Suggested command: " <> truncate(command, 500)
    name, _ -> "[TOOL] Called " <> name
  }
}

fn summary_key(name: String) -> String {
  case name {
    "web_search" -> "query"
    "web_scrape" -> "url"
    "atuin_history" -> "query"
    "atuin_output" -> "history_id"
    "read_file" -> "path"
    "suggest_command" -> "command"
    _ -> ""
  }
}

fn input_string(input: Dynamic, key: String) -> Result(String, Nil) {
  decode.run(input, decode.at([key], decode.string))
  |> result.replace_error(Nil)
}

fn truncate(text: String, max_length: Int) -> String {
  case string.length(text) > max_length {
    True -> string.slice(text, 0, max_length) <> "..."
    False -> text
  }
}
