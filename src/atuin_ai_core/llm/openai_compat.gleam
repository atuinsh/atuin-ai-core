//// OpenAI-compatible chat-completions message projection and JSON encoding.
////
//// This module owns the provider-wire shape used by OpenAI-compatible chat
//// completion endpoints, including OpenRouter. The inbound CLI chat request
//// format uses Anthropic-style content blocks; projection into OpenAI-style
//// messages happens here so provider adapters do not encode malformed hybrid
//// messages.

import atuin_ai_core/domain/tools
import atuin_ai_core/ffi/json as dynamic_json
import atuin_ai_core/http/request
import atuin_ai_core/json_schema
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Message {
  SystemMessage(content: List(ContentPart))
  UserMessage(content: List(ContentPart))
  AssistantMessage(
    content: Option(List(ContentPart)),
    tool_calls: List(ToolCall),
  )
  ToolMessage(tool_call_id: String, content: String)
}

pub type ContentPart {
  TextPart(text: String, cache_control: CacheControl)
}

pub type ToolCall {
  ToolCall(id: String, name: String, arguments_json: String)
}

pub type CacheControl {
  NoCache
  Ephemeral
}

/// Assembles the full message list for one LLM call: the system prompt
/// first, then the conversation history, then the volatile turn-context
/// block as a trailing user message (see `domain/prompt.turn_context`).
///
/// `cache_points` indexes count *units* of this assembly — the system
/// prompt is unit 0, each history message is one unit (even when it
/// projects to several wire messages, e.g. tool results), and the
/// turn-context is the last. So `[0, -2]` places breakpoints on the system
/// prompt and the last history message: the cached prefix covers tools +
/// system + history, and the turn context past the breakpoint never
/// invalidates it.
pub fn assemble(
  system system: Option(String),
  messages messages: List(request.Message),
  turn_context turn_context: Option(String),
  cache_points cache_points: List(Int),
) -> List(Message) {
  let messages = normalize_history(messages)
  let units =
    list.flatten([
      case system {
        Some(text) -> [
          fn(should_cache) { [system_message(text, should_cache)] },
        ]
        None -> []
      },
      list.map(messages, fn(message) {
        fn(should_cache) { from_request_message(message, should_cache:) }
      }),
      case turn_context {
        Some(text) -> [
          fn(should_cache) {
            [
              UserMessage([
                TextPart(text:, cache_control: cache_control(should_cache)),
              ]),
            ]
          },
        ]
        None -> []
      },
    ])

  let unit_count = list.length(units)

  units
  |> list.index_map(fn(unit, idx) {
    unit(check_cachepoint(idx, unit_count, cache_points))
  })
  |> list.flatten
}

fn system_message(text: String, should_cache: Bool) -> Message {
  SystemMessage([TextPart(text:, cache_control: cache_control(should_cache))])
}

/// Provider-compat fixups applied to the history before encoding:
///
/// - Assistant messages with no tool calls and no non-blank text are
///   dropped. Old clients echo back (and persist!) an empty assistant turn
///   after a generation that produced no text; providers reject empty
///   content, so one bad generation would otherwise wedge the session with
///   rejections until it expired.
/// - A `suggest_command` call followed directly by a plain user message
///   gets a constant `{"success": true}` tool result injected between
///   them: clients echo the call back without ever sending a result for
///   it, and providers reject dangling tool calls. The result is a
///   constant acknowledgment — the user's follow-up stays in their own
///   message, and an identical result block is friendlier to prompt
///   caching.
fn normalize_history(messages: List(request.Message)) -> List(request.Message) {
  messages
  |> list.filter(fn(message) { !blank_assistant_message(message) })
  |> inject_suggest_command_acks
}

fn blank_assistant_message(message: request.Message) -> Bool {
  case message.role, message.content {
    request.Assistant, request.Text(text) -> string.trim(text) == ""
    request.Assistant, request.Blocks(blocks) ->
      !list.any(blocks, fn(block) {
        case block {
          request.TextBlock(text) -> string.trim(text) != ""
          _ -> True
        }
      })
    request.User, _ -> False
  }
}

fn inject_suggest_command_acks(
  messages: List(request.Message),
) -> List(request.Message) {
  case messages {
    [assistant, next, ..rest] ->
      case unanswered_suggest_command(assistant, next) {
        Some(id) -> [
          assistant,
          suggest_command_ack(id),
          ..inject_suggest_command_acks([next, ..rest])
        ]
        None -> [assistant, ..inject_suggest_command_acks([next, ..rest])]
      }
    _ -> messages
  }
}

fn unanswered_suggest_command(
  message: request.Message,
  next: request.Message,
) -> Option(String) {
  case message.role, message.content, next.role, next.content {
    request.Assistant, request.Blocks(blocks), request.User, request.Text(_) ->
      blocks
      |> list.find_map(fn(block) {
        case block {
          request.ToolUse(id, "suggest_command", _input) -> Ok(id)
          _ -> Error(Nil)
        }
      })
      |> option.from_result
    _, _, _, _ -> None
  }
}

fn suggest_command_ack(tool_use_id: String) -> request.Message {
  request.Message(
    role: request.User,
    content: request.Blocks([
      request.ToolResult(
        tool_use_id:,
        body: request.Inline("{\"success\": true}"),
        is_error: False,
      ),
    ]),
  )
}

fn from_request_message(
  message: request.Message,
  should_cache should_cache: Bool,
) -> List(Message) {
  case message.role, message.content {
    request.User, request.Text(text) -> [
      UserMessage([
        TextPart(text:, cache_control: cache_control(should_cache)),
      ]),
    ]
    request.User, request.Blocks(blocks) ->
      user_messages_from_blocks(blocks, should_cache:)

    request.Assistant, request.Text(text) -> [
      AssistantMessage(
        content: Some([
          TextPart(text:, cache_control: cache_control(should_cache)),
        ]),
        tool_calls: [],
      ),
    ]
    request.Assistant, request.Blocks(blocks) -> {
      // Blank text blocks would encode as empty text parts, which
      // providers reject even alongside tool calls.
      let blocks =
        list.filter(blocks, fn(block) {
          case block {
            request.TextBlock(text) -> string.trim(text) != ""
            _ -> True
          }
        })
      let parts = content_parts_from_blocks(blocks, should_cache:)
      let tool_calls = tool_calls_from_blocks(blocks)

      case parts, tool_calls {
        [], [] -> []
        _, _ -> [
          AssistantMessage(
            content: optional_content(parts),
            tool_calls: tool_calls,
          ),
        ]
      }
    }
  }
}

fn content_parts_from_blocks(
  blocks: List(request.Block),
  should_cache should_cache: Bool,
) -> List(ContentPart) {
  content_parts_from_blocks_loop(
    blocks,
    should_cache: should_cache,
    text_count: count_text_blocks(blocks),
    text_index: 0,
  )
}

fn content_parts_from_blocks_loop(
  blocks: List(request.Block),
  should_cache should_cache: Bool,
  text_count text_count: Int,
  text_index text_index: Int,
) -> List(ContentPart) {
  case blocks {
    [] -> []
    [block, ..rest] ->
      case block {
        request.TextBlock(text) -> [
          TextPart(
            text: text,
            cache_control: cache_control(
              should_cache && text_index == text_count - 1,
            ),
          ),
          ..content_parts_from_blocks_loop(
            rest,
            should_cache: should_cache,
            text_count: text_count,
            text_index: text_index + 1,
          )
        ]
        _ ->
          content_parts_from_blocks_loop(
            rest,
            should_cache: should_cache,
            text_count: text_count,
            text_index: text_index,
          )
      }
  }
}

fn count_text_blocks(blocks: List(request.Block)) -> Int {
  blocks
  |> list.filter(fn(block) {
    case block {
      request.TextBlock(_) -> True
      _ -> False
    }
  })
  |> list.length
}

fn tool_calls_from_blocks(blocks: List(request.Block)) -> List(ToolCall) {
  blocks
  |> list.filter_map(fn(block) {
    case block {
      request.ToolUse(id, name, input) ->
        Ok(ToolCall(
          id: id,
          name: name,
          arguments_json: dynamic_json.encode(input),
        ))
      _ -> Error(Nil)
    }
  })
}

fn user_messages_from_blocks(
  blocks: List(request.Block),
  should_cache should_cache: Bool,
) -> List(Message) {
  user_messages_from_blocks_loop(
    blocks,
    should_cache: should_cache,
    text_count: count_text_blocks(blocks),
    text_index: 0,
    pending_parts: [],
    messages: [],
  )
}

fn user_messages_from_blocks_loop(
  blocks: List(request.Block),
  should_cache should_cache: Bool,
  text_count text_count: Int,
  text_index text_index: Int,
  pending_parts pending_parts: List(ContentPart),
  messages messages: List(Message),
) -> List(Message) {
  case blocks {
    [] ->
      messages
      |> flush_user_message(pending_parts)
      |> list.reverse

    [block, ..rest] ->
      case block {
        request.TextBlock(text) ->
          user_messages_from_blocks_loop(
            rest,
            should_cache: should_cache,
            text_count: text_count,
            text_index: text_index + 1,
            pending_parts: [
              TextPart(
                text: text,
                cache_control: cache_control(
                  should_cache && text_index == text_count - 1,
                ),
              ),
              ..pending_parts
            ],
            messages: messages,
          )

        request.ToolResult(tool_use_id, body, _is_error) -> {
          let messages = flush_user_message(messages, pending_parts)

          user_messages_from_blocks_loop(
            rest,
            should_cache: should_cache,
            text_count: text_count,
            text_index: text_index,
            pending_parts: [],
            messages: [
              ToolMessage(
                tool_call_id: tool_use_id,
                content: tool_result_body_to_string(body),
              ),
              ..messages
            ],
          )
        }

        _ ->
          user_messages_from_blocks_loop(
            rest,
            should_cache: should_cache,
            text_count: text_count,
            text_index: text_index,
            pending_parts: pending_parts,
            messages: messages,
          )
      }
  }
}

fn flush_user_message(
  messages: List(Message),
  pending_parts: List(ContentPart),
) -> List(Message) {
  case pending_parts {
    [] -> messages
    _ -> [UserMessage(list.reverse(pending_parts)), ..messages]
  }
}

fn tool_result_body_to_string(body: request.ToolResultBody) -> String {
  case body {
    request.Inline(text) -> text
    request.Remote(_length) -> "TODO: fetch remote content"
  }
}

fn optional_content(parts: List(ContentPart)) -> Option(List(ContentPart)) {
  case parts {
    [] -> None
    _ -> Some(parts)
  }
}

fn cache_control(should_cache: Bool) -> CacheControl {
  case should_cache {
    True -> Ephemeral
    False -> NoCache
  }
}

pub fn encode_messages(messages: List(Message)) -> json.Json {
  messages
  |> list.map(encode_message)
  |> json.preprocessed_array
}

pub fn encode_message(message: Message) -> json.Json {
  let pairs = case message {
    SystemMessage(content) -> [
      #("role", json.string("system")),
      #("content", encode_content(content)),
    ]
    UserMessage(content) -> [
      #("role", json.string("user")),
      #("content", encode_content(content)),
    ]
    AssistantMessage(content, tool_calls) -> {
      [
        #("role", json.string("assistant")),
        #("content", encode_optional_content(content)),
      ]
      |> maybe_add_tool_calls(tool_calls)
    }
    ToolMessage(tool_call_id, content) -> [
      #("role", json.string("tool")),
      #("tool_call_id", json.string(tool_call_id)),
      #("content", json.string(content)),
    ]
  }

  json.object(pairs)
}

fn encode_content(content: List(ContentPart)) -> json.Json {
  content
  |> list.map(encode_content_part)
  |> json.preprocessed_array
}

fn encode_optional_content(content: Option(List(ContentPart))) -> json.Json {
  case content {
    None -> json.null()
    Some(content) -> encode_content(content)
  }
}

fn encode_content_part(part: ContentPart) -> json.Json {
  let pairs = case part {
    TextPart(text, cache_control) -> {
      [
        #("type", json.string("text")),
        #("text", json.string(text)),
      ]
      |> maybe_add_cache_control(cache_control)
    }
  }

  json.object(pairs)
}

fn maybe_add_cache_control(
  pairs: List(#(String, json.Json)),
  cache_control: CacheControl,
) -> List(#(String, json.Json)) {
  case cache_control {
    NoCache -> pairs
    Ephemeral -> [
      #("cache_control", json.object([#("type", json.string("ephemeral"))])),
      ..pairs
    ]
  }
}

fn maybe_add_tool_calls(
  pairs: List(#(String, json.Json)),
  tool_calls: List(ToolCall),
) -> List(#(String, json.Json)) {
  case tool_calls {
    [] -> pairs
    _ -> [
      #(
        "tool_calls",
        json.preprocessed_array(list.map(tool_calls, encode_tool_call)),
      ),
      ..pairs
    ]
  }
}

fn encode_tool_call(tool_call: ToolCall) -> json.Json {
  case tool_call {
    ToolCall(id, name, arguments_json) ->
      json.object([
        #("id", json.string(id)),
        #("type", json.string("function")),
        #(
          "function",
          json.object([
            #("name", json.string(name)),
            #("arguments", json.string(arguments_json)),
          ]),
        ),
      ])
  }
}

/// Assembles with the volatile turn-context block as the FIRST user
/// message and no cache_control breakpoints: the layout for providers
/// whose prompt caching is automatic prefix matching (Fireworks, and the
/// self-hosted engines behind custom OpenAI-compatible endpoints), where
/// a trailing block would keep any request from strictly extending the
/// previous one. See the fireworks module docs for the measured rationale.
pub fn assemble_leading_context(
  system system: Option(String),
  messages messages: List(request.Message),
  turn_context turn_context: Option(String),
) -> List(Message) {
  let messages = case turn_context {
    None -> messages
    Some(context) -> [
      request.Message(role: request.User, content: request.Text(context)),
      ..messages
    ]
  }

  assemble(system:, messages:, turn_context: None, cache_points: [])
}

/// Appends the `tools` array to a request body when the request carries
/// tool definitions.
pub fn add_tools_field(
  body: List(#(String, json.Json)),
  tools: Option(List(tools.ToolDefinition)),
) -> List(#(String, json.Json)) {
  case tools {
    None -> body
    Some(tools) -> {
      let tools_json =
        tools
        |> list.map(encode_tool)
        |> json.preprocessed_array

      [#("tools", tools_json), ..body]
    }
  }
}

/// The OpenAI-compatible wire form of a tool definition. Pub so provider
/// adapters build their `tools` array from it and `trace_payloads` can
/// measure the exact wire size of the tool block a request carries.
pub fn encode_tool(tool: tools.ToolDefinition) -> json.Json {
  [
    #("type", json.string("function")),
    #("function", encode_tool_inner(tool)),
  ]
  |> json.object
}

fn encode_tool_inner(tool: tools.ToolDefinition) -> json.Json {
  let tools.JsonSchema(schema) = tool.parameter_schema

  [
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #("parameters", json_schema.to_json(schema)),
  ]
  |> json.object
}

fn check_cachepoint(
  idx: Int,
  message_count: Int,
  cache_points: List(Int),
) -> Bool {
  list.any(cache_points, fn(point) {
    case point >= 0 {
      True -> point == idx
      False -> point + message_count == idx
    }
  })
}
