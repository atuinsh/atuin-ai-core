import atuin_hub/cli_chat/http/request.{
  Assistant, Blocks, Inline, Message, Text, TextBlock, ToolResult, ToolUse, User,
}
import atuin_hub/cli_chat/llm/openai_compat.{
  AssistantMessage, Ephemeral, NoCache, SystemMessage, TextPart, ToolCall,
  ToolMessage, UserMessage, assemble, encode_messages,
}
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{None, Some}

fn obj(entries: List(#(String, Dynamic))) -> Dynamic {
  entries
  |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) })
  |> dynamic.properties
}

fn history_only(
  messages: List(request.Message),
  cache_points: List(Int),
) -> List(openai_compat.Message) {
  assemble(
    system: None,
    messages: messages,
    turn_context: None,
    cache_points: cache_points,
  )
}

pub fn text_messages_encode_content_as_parts_test() {
  let messages = history_only([Message(User, Text("hello"))], [])

  assert messages == [UserMessage([TextPart("hello", NoCache)])]
  assert json.to_string(encode_messages(messages))
    == "[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}]"
}

pub fn assistant_tool_use_becomes_message_level_tool_call_test() {
  let input = obj([#("command", dynamic.string("ls"))])
  let messages =
    history_only(
      [
        Message(
          Assistant,
          Blocks([
            TextBlock("Running command"),
            ToolUse("call_1", "run", input),
          ]),
        ),
      ],
      [],
    )

  assert messages
    == [
      AssistantMessage(
        content: Some([TextPart("Running command", NoCache)]),
        tool_calls: [ToolCall("call_1", "run", "{\"command\":\"ls\"}")],
      ),
    ]
}

pub fn user_tool_result_becomes_tool_message_in_order_test() {
  let messages =
    history_only(
      [
        Message(
          User,
          Blocks([
            TextBlock("before"),
            ToolResult("call_1", Inline("output"), False),
            TextBlock("after"),
          ]),
        ),
      ],
      [],
    )

  assert messages
    == [
      UserMessage([TextPart("before", NoCache)]),
      ToolMessage("call_1", "output"),
      UserMessage([TextPart("after", NoCache)]),
    ]
}

pub fn cache_points_apply_to_original_message_indices_test() {
  let messages =
    history_only(
      [
        Message(User, Text("old")),
        Message(
          User,
          Blocks([
            TextBlock("stable 1"),
            ToolResult("call_1", Inline("output"), False),
            TextBlock("stable 2"),
          ]),
        ),
        Message(User, Text("volatile")),
      ],
      [-2],
    )

  assert messages
    == [
      UserMessage([TextPart("old", NoCache)]),
      UserMessage([TextPart("stable 1", NoCache)]),
      ToolMessage("call_1", "output"),
      UserMessage([TextPart("stable 2", Ephemeral)]),
      UserMessage([TextPart("volatile", NoCache)]),
    ]
}

pub fn cache_control_encodes_on_selected_text_part_test() {
  let messages =
    history_only(
      [Message(User, Text("stable")), Message(User, Text("volatile"))],
      [0],
    )

  assert json.to_string(encode_messages(messages))
    == "[{\"role\":\"user\",\"content\":[{\"cache_control\":{\"type\":\"ephemeral\"},\"type\":\"text\",\"text\":\"stable\"}]},{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"volatile\"}]}]"
}

pub fn system_first_turn_context_last_test() {
  let messages =
    assemble(
      system: Some("be helpful"),
      messages: [Message(User, Text("hi"))],
      turn_context: Some("<turn_context>today</turn_context>"),
      cache_points: [],
    )

  assert messages
    == [
      SystemMessage([TextPart("be helpful", NoCache)]),
      UserMessage([TextPart("hi", NoCache)]),
      UserMessage([TextPart("<turn_context>today</turn_context>", NoCache)]),
    ]
}

// The production breakpoints: [0, -2] must land on the system prompt and
// the last *history* message, leaving the volatile turn context (unit -1)
// uncached so it never invalidates the prefix.
pub fn production_cache_points_mark_system_and_last_history_test() {
  let messages =
    assemble(
      system: Some("be helpful"),
      messages: [
        Message(User, Text("earlier")),
        Message(Assistant, Text("reply")),
        Message(User, Text("latest")),
      ],
      turn_context: Some("<turn_context>today</turn_context>"),
      cache_points: [0, -2],
    )

  assert messages
    == [
      SystemMessage([TextPart("be helpful", Ephemeral)]),
      UserMessage([TextPart("earlier", NoCache)]),
      AssistantMessage(Some([TextPart("reply", NoCache)]), []),
      UserMessage([TextPart("latest", Ephemeral)]),
      UserMessage([TextPart("<turn_context>today</turn_context>", NoCache)]),
    ]
}

// A history message that expands to several wire messages (tool results)
// still counts as one cache-point unit, so -2 stays pinned to the last
// history *message*, not the last wire message.
pub fn multi_wire_message_history_counts_as_one_unit_test() {
  let messages =
    assemble(
      system: Some("be helpful"),
      messages: [
        Message(User, Text("run it")),
        Message(
          User,
          Blocks([
            ToolResult("call_1", Inline("output"), False),
            TextBlock("done"),
          ]),
        ),
      ],
      turn_context: Some("<turn_context>today</turn_context>"),
      cache_points: [0, -2],
    )

  assert messages
    == [
      SystemMessage([TextPart("be helpful", Ephemeral)]),
      UserMessage([TextPart("run it", NoCache)]),
      ToolMessage("call_1", "output"),
      UserMessage([TextPart("done", Ephemeral)]),
      UserMessage([TextPart("<turn_context>today</turn_context>", NoCache)]),
    ]
}

pub fn system_message_encodes_with_cache_control_test() {
  let messages =
    assemble(
      system: Some("be helpful"),
      messages: [],
      turn_context: None,
      cache_points: [0],
    )

  assert json.to_string(encode_messages(messages))
    == "[{\"role\":\"system\",\"content\":[{\"cache_control\":{\"type\":\"ephemeral\"},\"type\":\"text\",\"text\":\"be helpful\"}]}]"
}

// ---------------------------------------------------------------------
// History normalization: provider-compat fixups on the client history.
// ---------------------------------------------------------------------

pub fn blank_assistant_text_message_is_dropped_test() {
  // Old clients echo back an empty assistant turn after a generation that
  // produced no text; providers reject empty-content messages.
  let messages =
    history_only(
      [
        Message(User, Text("how to resume tmux session")),
        Message(Assistant, Text("")),
        Message(Assistant, Text("  \n")),
        Message(User, Text("are you there?")),
      ],
      [],
    )

  assert messages
    == [
      UserMessage([TextPart("how to resume tmux session", NoCache)]),
      UserMessage([TextPart("are you there?", NoCache)]),
    ]
}

pub fn blank_assistant_blocks_message_is_dropped_test() {
  let messages =
    history_only(
      [
        Message(User, Text("hello")),
        Message(Assistant, Blocks([TextBlock("  ")])),
      ],
      [],
    )

  assert messages == [UserMessage([TextPart("hello", NoCache)])]
}

pub fn assistant_with_tool_calls_but_no_text_is_kept_test() {
  let input = obj([#("command", dynamic.string("ls"))])
  let messages =
    history_only(
      [
        Message(
          Assistant,
          Blocks([TextBlock(""), ToolUse("call_1", "run", input)]),
        ),
        Message(User, Blocks([ToolResult("call_1", Inline("ok"), False)])),
      ],
      [],
    )

  assert messages
    == [
      AssistantMessage(content: None, tool_calls: [
        ToolCall("call_1", "run", "{\"command\":\"ls\"}"),
      ]),
      ToolMessage("call_1", "ok"),
    ]
}

pub fn unanswered_suggest_command_gets_constant_ack_test() {
  // Clients echo a suggest_command call back without ever sending a result
  // for it; a plain user follow-up would leave the call dangling, which
  // providers reject. The ack is a constant — the follow-up stays in the
  // user's own message.
  let input = obj([#("command", dynamic.string("find . -size +100M"))])
  let messages =
    history_only(
      [
        Message(User, Text("find large files")),
        Message(
          Assistant,
          Blocks([ToolUse("gen_001", "suggest_command", input)]),
        ),
        Message(User, Text("sort by size too")),
      ],
      [],
    )

  assert messages
    == [
      UserMessage([TextPart("find large files", NoCache)]),
      AssistantMessage(content: None, tool_calls: [
        ToolCall(
          "gen_001",
          "suggest_command",
          "{\"command\":\"find . -size +100M\"}",
        ),
      ]),
      ToolMessage("gen_001", "{\"success\": true}"),
      UserMessage([TextPart("sort by size too", NoCache)]),
    ]
}

pub fn answered_suggest_command_gets_no_ack_test() {
  let input = obj([#("command", dynamic.string("ls"))])
  let messages =
    history_only(
      [
        Message(Assistant, Blocks([ToolUse("gen_1", "suggest_command", input)])),
        Message(User, Blocks([ToolResult("gen_1", Inline("ran it"), False)])),
      ],
      [],
    )

  assert messages
    == [
      AssistantMessage(content: None, tool_calls: [
        ToolCall("gen_1", "suggest_command", "{\"command\":\"ls\"}"),
      ]),
      ToolMessage("gen_1", "ran it"),
    ]
}

pub fn non_suggest_tool_calls_get_no_ack_test() {
  let input = obj([#("query", dynamic.string("gleam"))])
  let messages =
    history_only(
      [
        Message(Assistant, Blocks([ToolUse("ws_1", "web_search", input)])),
        Message(User, Text("never mind")),
      ],
      [],
    )

  assert messages
    == [
      AssistantMessage(content: None, tool_calls: [
        ToolCall("ws_1", "web_search", "{\"query\":\"gleam\"}"),
      ]),
      UserMessage([TextPart("never mind", NoCache)]),
    ]
}

pub fn injected_ack_does_not_shift_trailing_cache_point_test() {
  // -2 must keep pointing at the final history message (the user
  // follow-up); the injected ack lands before it as its own unit.
  let input = obj([#("command", dynamic.string("ls"))])
  let messages =
    history_only(
      [
        Message(Assistant, Blocks([ToolUse("gen_1", "suggest_command", input)])),
        Message(User, Text("thanks")),
      ],
      [-1],
    )

  assert messages
    == [
      AssistantMessage(content: None, tool_calls: [
        ToolCall("gen_1", "suggest_command", "{\"command\":\"ls\"}"),
      ]),
      ToolMessage("gen_1", "{\"success\": true}"),
      UserMessage([TextPart("thanks", Ephemeral)]),
    ]
}
