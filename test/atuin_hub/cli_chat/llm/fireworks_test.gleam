import atuin_hub/cli_chat/http/request
import atuin_hub/cli_chat/llm/client
import atuin_hub/cli_chat/llm/fireworks
import atuin_hub/cli_chat/llm/openai_compat.{
  NoCache, SystemMessage, TextPart, UserMessage,
}
import dream_http_client/client as dream
import gleam/option.{None, Some}

// Fireworks' prompt cache only matches strict prefix extensions, so the
// volatile turn-context block must sit at a stable early position: with it
// trailing (the Anthropic-oriented layout), a session's next request
// inserts messages *before* it and no prompt ever extends the previous
// one. This pins the cache-critical ordering: system, then turn context,
// then the conversation.
pub fn turn_context_leads_the_conversation_test() {
  let req =
    client.ClientRequest(
      inner: dream.new,
      system: Some("system prompt"),
      messages: [
        request.Message(role: request.User, content: request.Text("hello")),
        request.Message(role: request.Assistant, content: request.Text("hi!")),
        request.Message(role: request.User, content: request.Text("follow-up")),
      ],
      turn_context: Some("<turn_context>pwd</turn_context>"),
      tools: None,
    )

  assert fireworks.assemble_messages(req)
    == [
      SystemMessage([TextPart("system prompt", NoCache)]),
      UserMessage([
        TextPart("<turn_context>pwd</turn_context>", NoCache),
      ]),
      UserMessage([TextPart("hello", NoCache)]),
      openai_compat.AssistantMessage(
        content: Some([TextPart("hi!", NoCache)]),
        tool_calls: [],
      ),
      UserMessage([TextPart("follow-up", NoCache)]),
    ]
}

// No turn context: the conversation is passed through unchanged, and no
// cache_control breakpoints are emitted anywhere (Fireworks caching is
// automatic; the field isn't part of the OpenAI wire shape).
pub fn no_turn_context_passes_messages_through_test() {
  let req =
    client.ClientRequest(
      inner: dream.new,
      system: None,
      messages: [
        request.Message(role: request.User, content: request.Text("hello")),
      ],
      turn_context: None,
      tools: None,
    )

  assert fireworks.assemble_messages(req)
    == [UserMessage([TextPart("hello", NoCache)])]
}
