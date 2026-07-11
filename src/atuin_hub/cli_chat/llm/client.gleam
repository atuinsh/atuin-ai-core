import atuin_hub/cli_chat/domain/tools.{type ToolDefinition}
import atuin_hub/cli_chat/http/request.{type Message}
import dream_http_client/client as dream
import gleam/option.{type Option}

/// A provider-agnostic chat request: the HTTP request being built plus the
/// domain data a provider adapter encodes onto it.
///
/// `system` and `turn_context` are kept separate from `messages` because
/// they are per-call framing, not conversation history: the adapter places
/// the system prompt first and the turn-context block last, and neither is
/// ever stored back into the conversation.
pub type ClientRequest {
  ClientRequest(
    inner: dream.ClientRequest,
    system: Option(String),
    messages: List(Message),
    turn_context: Option(String),
    tools: Option(List(ToolDefinition)),
  )
}
