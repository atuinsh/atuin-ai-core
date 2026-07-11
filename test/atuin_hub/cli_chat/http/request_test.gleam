import atuin_hub/cli_chat/http/request.{
  Assistant, Blocks, ConversationTooLarge, Estimated, Inline, Message, Remote,
  Text, TextBlock, ToolResult, ToolUse, User,
}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn obj(entries: List(#(String, Dynamic))) -> Dynamic {
  entries
  |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) })
  |> dynamic.properties
}

fn msg(role: String, content: String) -> Dynamic {
  obj([#("role", dynamic.string(role)), #("content", dynamic.string(content))])
}

fn decode_messages(messages: Dynamic) {
  decode.run(messages, request.messages_decoder())
}

pub fn decodes_string_messages_test() {
  let messages =
    dynamic.list([msg("user", "list files"), msg("assistant", "here's how")])
  assert decode_messages(messages)
    == Ok([
      Message(User, Text("list files")),
      Message(Assistant, Text("here's how")),
    ])
}

pub fn decodes_empty_block_content_test() {
  let messages =
    dynamic.list([
      obj([#("role", dynamic.string("user")), #("content", dynamic.list([]))]),
    ])
  assert decode_messages(messages) == Ok([Message(User, Blocks([]))])
}

pub fn decodes_text_and_tool_use_blocks_test() {
  let blocks =
    dynamic.list([
      obj([#("type", dynamic.string("text")), #("text", dynamic.string("hi"))]),
      obj([
        #("type", dynamic.string("tool_use")),
        #("id", dynamic.string("t1")),
        #("name", dynamic.string("run")),
        #("input", obj([#("command", dynamic.string("ls"))])),
      ]),
    ])
  let message =
    obj([#("role", dynamic.string("assistant")), #("content", blocks)])

  // `input` is Dynamic, so match structurally rather than by equality.
  let assert Ok([Message(Assistant, Blocks([first, second]))]) =
    decode_messages(dynamic.list([message]))
  assert first == TextBlock("hi")
  let assert ToolUse("t1", "run", _input) = second
}

pub fn decodes_inline_tool_result_test() {
  let block =
    obj([
      #("type", dynamic.string("tool_result")),
      #("tool_use_id", dynamic.string("t1")),
      #("content", dynamic.string("output")),
      #("is_error", dynamic.bool(False)),
    ])
  let messages =
    dynamic.list([
      obj([
        #("role", dynamic.string("user")),
        #("content", dynamic.list([block])),
      ]),
    ])
  assert decode_messages(messages)
    == Ok([Message(User, Blocks([ToolResult("t1", Inline("output"), False)]))])
}

pub fn decodes_remote_tool_result_test() {
  let block =
    obj([
      #("type", dynamic.string("tool_result")),
      #("tool_use_id", dynamic.string("t1")),
      #("remote", dynamic.bool(True)),
      #("is_error", dynamic.bool(True)),
      #("content_length", dynamic.int(42)),
    ])
  let messages =
    dynamic.list([
      obj([
        #("role", dynamic.string("user")),
        #("content", dynamic.list([block])),
      ]),
    ])
  assert decode_messages(messages)
    == Ok([Message(User, Blocks([ToolResult("t1", Remote(Some(42)), True)]))])
}

pub fn normalizes_legacy_tool_calls_test() {
  // Legacy clients send tool calls top-level alongside string content; they
  // should fold into a leading text block plus a tool_use block.
  let message =
    obj([
      #("role", dynamic.string("assistant")),
      #("content", dynamic.string("calling")),
      #(
        "tool_calls",
        dynamic.list([
          obj([
            #("id", dynamic.string("t1")),
            #("name", dynamic.string("run")),
            #("input", obj([#("a", dynamic.string("b"))])),
          ]),
        ]),
      ),
    ])

  let assert Ok([Message(Assistant, Blocks([text, tool]))]) =
    decode_messages(dynamic.list([message]))
  assert text == TextBlock("calling")
  let assert ToolUse("t1", "run", _input) = tool
}

pub fn decodes_assistant_tool_call_without_content_test() {
  // Older clients may omit content for a tool-call-only assistant turn.
  let message =
    obj([
      #("role", dynamic.string("assistant")),
      #(
        "tool_calls",
        dynamic.list([
          obj([
            #("id", dynamic.string("t1")),
            #("name", dynamic.string("run")),
            #("input", obj([#("a", dynamic.string("b"))])),
          ]),
        ]),
      ),
    ])

  let assert Ok([Message(Assistant, Blocks([tool]))]) =
    decode_messages(dynamic.list([message]))
  let assert ToolUse("t1", "run", _input) = tool
}

pub fn rejects_missing_content_test() {
  let messages = dynamic.list([obj([#("role", dynamic.string("user"))])])
  let assert Error(_) = decode_messages(messages)
}

pub fn rejects_non_list_test() {
  let assert Error(_) = decode_messages(dynamic.string("nope"))
}

pub fn rejects_non_map_message_test() {
  let assert Error(_) = decode_messages(dynamic.list([dynamic.string("hi")]))
}

pub fn rejects_missing_role_test() {
  let messages = dynamic.list([obj([#("content", dynamic.string("hi"))])])
  let assert Error(_) = decode_messages(messages)
}

pub fn rejects_invalid_role_test() {
  let assert Error(_) = decode_messages(dynamic.list([msg("system", "sneaky")]))
}

pub fn estimate_counts_string_content_test() {
  // 8 chars + 8 chars = 16 chars -> 4 tokens
  let messages = [
    Message(User, Text("12345678")),
    Message(Assistant, Text("12345678")),
  ]
  assert request.estimate_tokens(messages) == Estimated(4)
}

pub fn estimate_counts_tool_use_input_test() {
  // text "1234" (4) + input {"a":"bc"} JSON-encodes to 10 chars = 14 -> 3
  let input = obj([#("a", dynamic.string("bc"))])
  let message =
    Message(Assistant, Blocks([TextBlock("1234"), ToolUse("t1", "run", input)]))
  assert request.estimate_tokens([message]) == Estimated(3)
}

pub fn estimate_counts_inline_tool_result_test() {
  // text "1234" (4) + inline result "5678" (4) = 8 -> 2 tokens
  let message =
    Message(
      User,
      Blocks([TextBlock("1234"), ToolResult("t1", Inline("5678"), False)]),
    )
  assert request.estimate_tokens([message]) == Estimated(2)
}

pub fn estimate_counts_remote_content_length_test() {
  // Remote results count their declared content_length: 80,000 / 4 = 20,000
  let message =
    Message(User, Blocks([ToolResult("t1", Remote(Some(80_000)), False)]))
  assert request.estimate_tokens([message]) == Estimated(20_000)
}

pub fn estimate_rejects_oversized_test() {
  // 800,000 chars -> 200,000 tokens > 180,000 limit
  let big = string.repeat("abcdefgh", 100_000)
  assert request.estimate_tokens([Message(User, Text(big))])
    == ConversationTooLarge
}

pub fn hydrate_resolves_remote_results_test() {
  let messages = [
    Message(User, Text("run it")),
    Message(
      User,
      Blocks([
        TextBlock("here"),
        ToolResult("t1", Remote(Some(40)), False),
        ToolResult("t2", Inline("already inline"), False),
      ]),
    ),
  ]

  let hydrated =
    request.hydrate(messages, fn(tool_use_id) {
      case tool_use_id {
        "t1" -> Some("stored content")
        _ -> None
      }
    })

  assert hydrated
    == [
      Message(User, Text("run it")),
      Message(
        User,
        Blocks([
          TextBlock("here"),
          ToolResult("t1", Inline("stored content"), False),
          ToolResult("t2", Inline("already inline"), False),
        ]),
      ),
    ]
}

pub fn hydrate_missing_result_degrades_to_placeholder_test() {
  let messages = [
    Message(User, Blocks([ToolResult("gone", Remote(Some(10)), True)])),
  ]

  let hydrated = request.hydrate(messages, fn(_) { None })

  assert hydrated
    == [
      Message(
        User,
        Blocks([
          ToolResult("gone", Inline("[Tool result no longer available]"), True),
        ]),
      ),
    ]
}
