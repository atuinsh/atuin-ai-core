import atuin_hub/cli_chat/engine/loop
import atuin_hub/cli_chat/engine/turn
import atuin_hub/cli_chat/http/driver
import atuin_hub/cli_chat/http/request
import atuin_hub/cli_chat/http/trace
import atuin_hub/cli_chat/llm/openrouter
import dream_http_client/client as dream
import gleam/dynamic
import gleam/option.{None, Some}

fn context(messages: List(request.Message)) -> driver.Context {
  driver.Context(
    session_id: "session",
    options: driver.OpenRouter(
      openrouter.OpenRouterOptions(
        api_key: "",
        model: "test-model",
        session_id: None,
        referer: None,
        title: None,
        anthropic_betas: [],
        model_options: None,
        provider_options: None,
        cache_points: [],
      ),
    ),
    base_request: dream.new,
    system: Some("system"),
    messages:,
    turn_context: None,
    tools: [],
    is_server_tool: fn(_name) { False },
    execute_tool: fn(call) {
      turn.ToolResult(
        id: call.id,
        name: call.name,
        result: "no tools in tests",
        is_error: True,
      )
    },
    store_tool_result: fn(_result) { Error(Nil) },
    trace: fn(_event) { Nil },
    credits: fn(_usage) { None },
    content_policy: trace.MetadataOnly,
  )
}

// The loop's conversation is the inherited transcript plus appended tool
// exchanges; the driver re-encodes the inherited prefix from its typed
// originals and converts the appended suffix into request messages.
pub fn conversation_includes_appended_tool_exchange_test() {
  let inherited = [
    request.Message(request.User, request.Text("find the docs")),
  ]
  let input =
    dynamic.properties([
      #(dynamic.string("query"), dynamic.string("gleam actors")),
    ])

  let conversation = [
    loop.Inherited(role: loop.User),
    loop.AssistantToolUse(text: "Searching...", tool_calls: [
      turn.ToolCall(id: "t1", name: "web_search", input: input),
    ]),
    loop.ToolResultMessage(tool_call_id: "t1", content: "<results/>"),
  ]

  assert driver.conversation_messages(context(inherited), conversation)
    == [
      request.Message(request.User, request.Text("find the docs")),
      request.Message(
        request.Assistant,
        request.Blocks([
          request.TextBlock("Searching..."),
          request.ToolUse(id: "t1", name: "web_search", input: input),
        ]),
      ),
      request.Message(
        request.User,
        request.Blocks([
          request.ToolResult(
            tool_use_id: "t1",
            body: request.Inline("<results/>"),
            is_error: False,
          ),
        ]),
      ),
    ]
}

// A tool-bearing response with no text yields no empty text block.
pub fn appended_assistant_message_without_text_has_no_text_block_test() {
  let input = dynamic.properties([])
  let conversation = [
    loop.AssistantToolUse(text: "", tool_calls: [
      turn.ToolCall(id: "t1", name: "web_search", input: input),
    ]),
  ]

  assert driver.conversation_messages(context([]), conversation)
    == [
      request.Message(
        request.Assistant,
        request.Blocks([
          request.ToolUse(id: "t1", name: "web_search", input: input),
        ]),
      ),
    ]
}
