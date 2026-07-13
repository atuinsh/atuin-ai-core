//// Fireworks AI adapter. Fireworks serves an OpenAI-compatible
//// chat-completions endpoint (https://docs.fireworks.ai/tools-sdks/
//// openai-compatibility), so the message projection and SSE decoding are
//// shared with OpenRouter via `openai_compat`; only the host, auth, and
//// request body differ. Usage arrives in the final stream chunk (the one
//// carrying `finish_reason`) without needing `stream_options`.
////
//// Prompt caching on Fireworks is automatic but only matches when a
//// previously cached prompt is a strict byte-prefix of the new one — no
//// `cache_control` breakpoints, no partial matching at a mid-prompt
//// divergence, not even at a message boundary (measured against both a
//// dedicated deployment and serverless; a ~1,300-token shared prefix with
//// a divergent tail reports cached_tokens: 0). The assembly here is shaped
//// for that: see `assemble_messages`.

import atuin_ai_core/llm/client.{type ClientRequest}
import atuin_ai_core/llm/openai_compat
import dream_http_client/client as dream
import gleam/http
import gleam/json
import gleam/option.{type Option, None, Some}

pub type FireworksOptions {
  FireworksOptions(
    /// Fireworks model identifier, e.g.
    /// "accounts/fireworks/models/llama-v3p1-70b-instruct".
    model: String,
    api_key: String,
    /// Sent as `x-session-affinity`: Fireworks prompt caches are
    /// per-replica, so a session's requests must land on the same replica
    /// to hit the cached prefix.
    session_id: Option(String),
  )
}

pub fn prepare_request(
  options: FireworksOptions,
  req: ClientRequest,
) -> ClientRequest {
  let dream_req =
    req.inner
    |> dream.method(http.Post)
    |> dream.scheme(http.Https)
    |> dream.host("api.fireworks.ai")
    |> dream.path("/inference/v1/chat/completions")
    |> dream.add_header("authorization", "Bearer " <> options.api_key)
    |> dream.add_header("content-type", "application/json")

  let dream_req = case options.session_id {
    None -> dream_req
    Some(session_id) ->
      dream.add_header(dream_req, "x-session-affinity", session_id)
  }

  let body =
    [
      #("stream", json.bool(True)),
      #("model", json.string(options.model)),
      #("messages", openai_compat.encode_messages(assemble_messages(req))),
    ]
    |> openai_compat.add_tools_field(req.tools)
    |> json.object()

  let dream_req = dream_req |> dream.body(json.to_string(body))

  client.ClientRequest(..req, inner: dream_req)
}

/// Assembles the message list with the volatile turn-context block as the
/// FIRST user message instead of the trailing one the Anthropic-oriented
/// layout uses. With it trailing, no call's prompt is ever a strict
/// extension of the previous one (the next call inserts messages before
/// it), so Fireworks' prefix cache — and the cache-read credit discount
/// users get from it — never applies. Up front, every request within one
/// turn's tool loop extends the previous prompt byte-for-byte, and a
/// follow-up turn extends it too whenever the block's contents (UTC date,
/// pwd, last_command) haven't changed. A turn whose block did change pays
/// one cold prompt and re-primes the cache for its own loop. Measured over
/// 5-turn sessions: 0% cached trailing, ~75% cached leading with an
/// unchanged block. Capturing the changed-block case too would require the
/// transcript to retain each turn's block in place (append-only history) —
/// a client-side change.
pub fn assemble_messages(req: ClientRequest) -> List(openai_compat.Message) {
  openai_compat.assemble_leading_context(
    system: req.system,
    messages: req.messages,
    turn_context: req.turn_context,
  )
}
