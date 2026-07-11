//// Decoding and token estimation for the /api/cli/chat request body.
////
//// Clients send messages in a role/content format. Current clients use the
//// Anthropic-style content-block shape: tool calls arrive as `tool_use`
//// blocks inside assistant content, tool results as `tool_result` blocks
//// inside a user message.
////
////     {
////       "messages": [
////         {"role": "user", "content": "list files"},
////         {"role": "assistant", "content": [
////           {"type": "text", "text": "Listing..."},
////           {"type": "tool_use", "id": "t1", "name": "run", "input": {...}}
////         ]},
////         {"role": "user", "content": [
////           {"type": "tool_result", "tool_use_id": "t1", "content": "...",
////            "is_error": false}
////         ]}
////       ]
////     }
////
//// Older clients instead send tool calls in a top-level `tool_calls` array on
//// assistant messages. We normalize those into `ToolUse` blocks at decode
//// time so the rest of the system only ever sees one representation.
////
//// `input` on a tool call stays `Dynamic`: tool input schemas are arbitrary
//// and per-tool, so "any JSON value" is the honest type. Remote tool-result
//// bodies are hydrated here (`hydrate`); projection to the provider wire
//// shape happens in `llm/openai_compat`.

import atuin_hub/ffi/json
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Max tokens for the conversation: 200K context, leaving room for the
/// response.
/// TODO: per model limits based on max context size
const max_conversation_tokens = 180_000

/// Rough estimation: 4 characters per token (conservative).
const chars_per_token = 4

pub type Role {
  User
  Assistant
}

pub type Message {
  Message(role: Role, content: Content)
}

pub type Content {
  Text(String)
  Blocks(List(Block))
}

pub type Block {
  TextBlock(text: String)
  ToolUse(id: String, name: String, input: Dynamic)
  ToolResult(tool_use_id: String, body: ToolResultBody, is_error: Bool)
}

pub type ToolResultBody {
  /// Result content sent inline by the client.
  Inline(content: String)
  /// Result stored server-side, hydrated later by `tool_use_id`. The client
  /// may send the eventual size so we can estimate tokens before hydration.
  Remote(content_length: Option(Int))
}

pub fn messages_decoder() -> Decoder(List(Message)) {
  decode.list(message_decoder())
}

fn message_decoder() -> Decoder(Message) {
  use role <- decode.field("role", role_decoder())
  use content <- decode.optional_field(
    "content",
    None,
    content_decoder() |> decode.map(Some),
  )
  // Legacy clients send tool calls in a top-level `tool_calls` array of the
  // same {id, name, input} shape as a `tool_use` block; normalize them in so
  // callers only deal with content blocks.
  use tool_calls <- decode.optional_field(
    "tool_calls",
    [],
    decode.list(tool_use_decoder()),
  )

  case content, role, tool_calls {
    Some(content), _, _ ->
      decode.success(Message(
        role:,
        content: merge_tool_calls(content, tool_calls),
      ))
    None, Assistant, [_, ..] ->
      decode.success(Message(
        role:,
        content: merge_tool_calls(Text(""), tool_calls),
      ))
    None, _, _ -> decode.failure(Message(role:, content: Text("")), "content")
  }
}

fn role_decoder() -> Decoder(Role) {
  use raw <- decode.then(decode.string)
  case raw {
    "user" -> decode.success(User)
    "assistant" -> decode.success(Assistant)
    _ -> decode.failure(User, "user or assistant")
  }
}

fn content_decoder() -> Decoder(Content) {
  decode.one_of(decode.string |> decode.map(Text), or: [
    decode.list(block_decoder()) |> decode.map(Blocks),
  ])
}

fn block_decoder() -> Decoder(Block) {
  use block_type <- decode.field("type", decode.string)
  case block_type {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(TextBlock(text:))
    }
    "tool_use" -> tool_use_decoder()
    "tool_result" -> tool_result_decoder()
    _ -> decode.failure(TextBlock(""), "a known content block type")
  }
}

fn tool_use_decoder() -> Decoder(Block) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use input <- decode.field("input", decode.dynamic)
  decode.success(ToolUse(id:, name:, input:))
}

fn tool_result_decoder() -> Decoder(Block) {
  use tool_use_id <- decode.field("tool_use_id", decode.string)
  use is_error <- decode.optional_field("is_error", False, decode.bool)
  use body <- decode.then(tool_result_body_decoder())
  decode.success(ToolResult(tool_use_id:, body:, is_error:))
}

fn tool_result_body_decoder() -> Decoder(ToolResultBody) {
  use remote <- decode.optional_field("remote", False, decode.bool)
  case remote {
    True -> {
      use content_length <- decode.optional_field(
        "content_length",
        None,
        decode.optional(decode.int),
      )
      decode.success(Remote(content_length:))
    }
    False -> {
      use content <- decode.field("content", decode.string)
      decode.success(Inline(content:))
    }
  }
}

// Fold any legacy top-level tool calls into the message content so callers see
// a single representation. Existing string content becomes a leading text
// block; an empty string contributes nothing.
fn merge_tool_calls(content: Content, tool_calls: List(Block)) -> Content {
  case tool_calls {
    [] -> content
    _ -> {
      let blocks = case content {
        Text("") -> []
        Text(text) -> [TextBlock(text)]
        Blocks(blocks) -> blocks
      }
      Blocks(list.append(blocks, tool_calls))
    }
  }
}

/// Resolves `Remote` tool-result bodies to inline content through the
/// given lookup (storage-backed in production; see `http/tool_results`).
/// A result that can't be found — expired, or never stored — degrades to
/// a placeholder rather than failing the request, matching the historical
/// behavior.
pub fn hydrate(
  messages: List(Message),
  lookup: fn(String) -> Option(String),
) -> List(Message) {
  list.map(messages, fn(message) {
    case message.content {
      Text(_) -> message
      Blocks(blocks) ->
        Message(
          ..message,
          content: Blocks(list.map(blocks, hydrate_block(_, lookup))),
        )
    }
  })
}

fn hydrate_block(block: Block, lookup: fn(String) -> Option(String)) -> Block {
  case block {
    ToolResult(tool_use_id:, body: Remote(_), is_error:) -> {
      let content =
        lookup(tool_use_id)
        |> option.unwrap("[Tool result no longer available]")
      ToolResult(tool_use_id:, body: Inline(content), is_error:)
    }
    _ -> block
  }
}

/// Re-encodes a message into its wire shape, for trace payloads. Legacy
/// top-level `tool_calls` were normalized into blocks at decode time, so
/// re-encoding always produces the block form.
pub fn to_dynamic(message: Message) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("role"), dynamic.string(role_string(message.role))),
    #(dynamic.string("content"), content_to_dynamic(message.content)),
  ])
}

fn role_string(role: Role) -> String {
  case role {
    User -> "user"
    Assistant -> "assistant"
  }
}

fn content_to_dynamic(content: Content) -> Dynamic {
  case content {
    Text(text) -> dynamic.string(text)
    Blocks(blocks) -> dynamic.list(list.map(blocks, block_to_dynamic))
  }
}

fn block_to_dynamic(block: Block) -> Dynamic {
  case block {
    TextBlock(text:) ->
      dynamic.properties([
        #(dynamic.string("type"), dynamic.string("text")),
        #(dynamic.string("text"), dynamic.string(text)),
      ])
    ToolUse(id:, name:, input:) ->
      dynamic.properties([
        #(dynamic.string("type"), dynamic.string("tool_use")),
        #(dynamic.string("id"), dynamic.string(id)),
        #(dynamic.string("name"), dynamic.string(name)),
        #(dynamic.string("input"), input),
      ])
    ToolResult(tool_use_id:, body:, is_error:) ->
      dynamic.properties([
        #(dynamic.string("type"), dynamic.string("tool_result")),
        #(dynamic.string("tool_use_id"), dynamic.string(tool_use_id)),
        #(dynamic.string("is_error"), dynamic.bool(is_error)),
        ..case body {
          Inline(content:) -> [
            #(dynamic.string("content"), dynamic.string(content)),
          ]
          Remote(content_length:) -> [
            #(dynamic.string("remote"), dynamic.bool(True)),
            #(
              dynamic.string("content_length"),
              content_length
                |> option.map(dynamic.int)
                |> option.unwrap(dynamic.nil()),
            ),
          ]
        }
      ])
  }
}

pub type TokenEstimate {
  Estimated(tokens: Int)
  ConversationTooLarge
}

/// Estimates token count for the conversation with the 4-chars-per-token
/// heuristic, rejecting conversations over the limit.
pub fn estimate_tokens(messages: List(Message)) -> TokenEstimate {
  let total_chars =
    messages
    |> list.map(count_message_chars)
    |> int.sum

  let estimated_tokens = total_chars / chars_per_token

  case estimated_tokens > max_conversation_tokens {
    True -> ConversationTooLarge
    False -> Estimated(estimated_tokens)
  }
}

fn count_message_chars(message: Message) -> Int {
  case message.content {
    Text(text) -> string.length(text)
    Blocks(blocks) -> blocks |> list.map(count_block_chars) |> int.sum
  }
}

fn count_block_chars(block: Block) -> Int {
  case block {
    TextBlock(text:) -> string.length(text)
    ToolUse(input:, ..) -> string.length(json.encode(input))
    ToolResult(body:, ..) ->
      case body {
        Inline(content:) -> string.length(content)
        Remote(content_length:) -> option.unwrap(content_length, 0)
      }
  }
}
