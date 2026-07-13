//// The privacy contract for trace payloads: every builder's exact key set
//// under each policy. A new payload field fails here until it is
//// deliberately allowlisted — under MetadataOnly no key may carry user
//// content, only identifiers, counts, and byte sizes.

import atuin_ai_core/domain/config
import atuin_ai_core/domain/prompt
import atuin_ai_core/domain/tools/web_search
import atuin_ai_core/domain/usage
import atuin_ai_core/engine/loop
import atuin_ai_core/engine/turn
import atuin_ai_core/http/request
import atuin_ai_core/http/trace.{FullContent, MetadataOnly}
import atuin_ai_core/http/trace_payloads
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// ---------------------------------------------------------------------
// Fixtures: every content-bearing field populated, so a leak would show.
// ---------------------------------------------------------------------

const secret = "SECRET-user-content"

fn messages() -> List(request.Message) {
  [
    request.Message(request.User, request.Text(secret)),
    request.Message(request.Assistant, request.Text("assistant " <> secret)),
  ]
}

fn full_config() -> config.Config {
  config.Config(
    ..config.default(),
    prompt_fn: Some("concise"),
    user_contexts: [config.UserContext("/home/me/" <> secret, secret)],
    skills: [config.SkillSummary(secret, secret)],
    skills_overflow: Some(secret),
  )
}

fn full_context() -> prompt.PromptContext {
  prompt.PromptContext(
    os: Some("macos"),
    distro: None,
    shell: Some("zsh"),
    preferred_language: Some("en"),
    pwd: Some("/home/me/" <> secret),
    last_command: Some("echo " <> secret),
  )
}

fn tool_calls() -> List(turn.ToolCall) {
  [
    turn.ToolCall(
      id: "t1",
      name: "web_search",
      input: dynamic.properties([
        #(dynamic.string("query"), dynamic.string(secret)),
      ]),
    ),
  ]
}

fn turn_usage() -> usage.Usage {
  usage.Usage(
    input_tokens: 10,
    output_tokens: 20,
    total_tokens: 30,
    cached_tokens: 1,
    cache_creation_tokens: 2,
    input_cost: None,
    output_cost: None,
    total_cost: None,
    provider_cost: Some(5),
    upstream_cost: None,
  )
}

fn session_summary() -> turn.SessionSummary {
  turn.SessionSummary(
    confidence: Some("high"),
    confidence_notes: Some(secret),
    danger: Some("low"),
    danger_notes: Some(secret),
    turn_count: 3,
  )
}

// ---------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------

fn as_dict(payload: Dynamic) -> Dict(String, Dynamic) {
  let assert Ok(fields) =
    decode.run(payload, decode.dict(decode.string, decode.dynamic))
  fields
}

fn keys(payload: Dynamic) -> List(String) {
  payload |> as_dict |> dict.keys |> list.sort(string.compare)
}

fn nested(payload: Dynamic, key: String) -> Dynamic {
  let assert Ok(value) = dict.get(as_dict(payload), key)
  value
}

/// No value anywhere in the payload tree may contain the secret. Guards
/// against content escaping through a field the key-set asserts don't
/// inspect (e.g. a nested object or list).
fn assert_no_secret(payload: Dynamic) -> Nil {
  let encoded = string.inspect(payload)
  assert !string.contains(encoded, secret)
  Nil
}

// ---------------------------------------------------------------------
// client_request
// ---------------------------------------------------------------------

fn client_request(policy) -> Dynamic {
  trace_payloads.client_request(
    policy:,
    messages: messages(),
    config: full_config(),
    context: full_context(),
    invocation_id: Some("inv-1"),
    client_version: Some("1.2.3"),
    model_alias: "max",
    model: "openrouter:anthropic/claude-sonnet-5",
  )
}

pub fn client_request_metadata_only_key_set_test() {
  let payload = client_request(MetadataOnly)

  assert keys(payload)
    == [
      "capabilities", "client_version", "config", "context", "invocation_id",
      "message_count", "messages_bytes",
    ]

  assert keys(nested(payload, "config"))
    == [
      "model", "model_alias", "prompt_fn", "run_preference", "skill_count",
      "skills_bytes", "skills_overflow_bytes", "user_context_count",
      "user_contexts_bytes",
    ]

  assert keys(nested(payload, "context"))
    == ["distro", "os", "preferred_language", "shell"]

  assert_no_secret(payload)
}

pub fn client_request_full_content_key_set_test() {
  let payload = client_request(FullContent)

  assert keys(payload)
    == [
      "capabilities", "client_version", "config", "context", "invocation_id",
      "message_count", "messages", "messages_bytes",
    ]

  assert keys(nested(payload, "config"))
    == [
      "model", "model_alias", "prompt_fn", "run_preference", "skill_count",
      "skills", "skills_bytes", "skills_overflow", "skills_overflow_bytes",
      "user_context_count", "user_contexts", "user_contexts_bytes",
    ]

  assert keys(nested(payload, "context"))
    == ["distro", "last_command", "os", "preferred_language", "pwd", "shell"]
}

pub fn client_request_metadata_counts_and_sizes_test() {
  let payload = client_request(MetadataOnly)

  let assert Ok(count) =
    decode.run(nested(payload, "message_count"), decode.int)
  assert count == 2

  let assert Ok(bytes) =
    decode.run(nested(payload, "messages_bytes"), decode.int)
  assert bytes > string.byte_size(secret)
}

// ---------------------------------------------------------------------
// llm_request
// ---------------------------------------------------------------------

fn llm_request(policy) -> Dynamic {
  trace_payloads.llm_request(
    policy:,
    iteration: 1,
    model: "anthropic/claude-sonnet-5",
    messages: messages(),
    system: Some("system prompt: " <> secret),
    turn_context: Some("turn context: " <> secret),
    tools: [web_search.web_search()],
  )
}

pub fn llm_request_metadata_only_key_set_test() {
  let payload = llm_request(MetadataOnly)

  assert keys(payload)
    == [
      "iteration", "message_count", "messages_bytes", "model",
      "system_prompt_bytes", "tool_count", "tool_names", "tools_bytes",
      "turn_context_bytes",
    ]

  assert_no_secret(payload)
}

pub fn llm_request_full_content_key_set_test() {
  assert keys(llm_request(FullContent))
    == [
      "iteration", "message_count", "messages", "messages_bytes", "model",
      "system_prompt", "system_prompt_bytes", "tool_count", "tool_names",
      "tools", "tools_bytes", "turn_context", "turn_context_bytes",
    ]
}

pub fn llm_request_sizes_test() {
  let payload = llm_request(MetadataOnly)
  let system = "system prompt: " <> secret

  let assert Ok(system_bytes) =
    decode.run(nested(payload, "system_prompt_bytes"), decode.int)
  assert system_bytes == string.byte_size(system)

  let assert Ok(tools_bytes) =
    decode.run(nested(payload, "tools_bytes"), decode.int)
  assert tools_bytes > 0

  let assert Ok(names) =
    decode.run(nested(payload, "tool_names"), decode.list(decode.string))
  assert names == ["web_search"]
}

// ---------------------------------------------------------------------
// llm_response
// ---------------------------------------------------------------------

fn llm_response(policy) -> Dynamic {
  trace_payloads.llm_response(
    policy:,
    iteration: 2,
    text: "the model said: " <> secret,
    tool_calls: tool_calls(),
  )
}

pub fn llm_response_metadata_only_key_set_test() {
  let payload = llm_response(MetadataOnly)

  assert keys(payload)
    == ["iteration", "text_bytes", "tool_call_count", "tool_call_names"]

  let assert Ok(names) =
    decode.run(nested(payload, "tool_call_names"), decode.list(decode.string))
  assert names == ["web_search"]

  assert_no_secret(payload)
}

pub fn llm_response_full_content_key_set_test() {
  assert keys(llm_response(FullContent))
    == [
      "iteration", "text", "text_bytes", "tool_call_count", "tool_call_names",
      "tool_calls",
    ]
}

// ---------------------------------------------------------------------
// tool_execution
// ---------------------------------------------------------------------

fn tool_execution(policy) -> Dynamic {
  trace_payloads.tool_execution(
    policy:,
    result: turn.ToolResult(
      id: "t1",
      name: "web_search",
      result: "results: " <> secret,
      is_error: False,
    ),
    input: dynamic.properties([
      #(dynamic.string("query"), dynamic.string(secret)),
    ]),
  )
}

pub fn tool_execution_metadata_only_key_set_test() {
  let payload = tool_execution(MetadataOnly)

  assert keys(payload)
    == ["input_bytes", "is_error", "result_bytes", "tool_name", "tool_use_id"]

  let assert Ok(result_bytes) =
    decode.run(nested(payload, "result_bytes"), decode.int)
  assert result_bytes == string.byte_size("results: " <> secret)

  assert_no_secret(payload)
}

pub fn tool_execution_full_content_key_set_test() {
  assert keys(tool_execution(FullContent))
    == [
      "input", "input_bytes", "is_error", "result", "result_bytes", "tool_name",
      "tool_use_id",
    ]
}

// ---------------------------------------------------------------------
// completion (session_complete / request_complete)
// ---------------------------------------------------------------------

fn completion(policy) -> Dynamic {
  trace_payloads.completion(
    policy:,
    turn_usage: turn_usage(),
    summary: Some(session_summary()),
    responses: loop.Responses(text: ["done"], tool_calls: []),
    cancelled: False,
  )
}

pub fn completion_metadata_only_key_set_test() {
  let payload = completion(MetadataOnly)

  assert keys(payload)
    == ["ai_response_count", "cancelled", "session_summary", "usage"]

  assert keys(nested(payload, "session_summary"))
    == ["confidence", "danger", "turn_count"]

  assert_no_secret(payload)
}

pub fn completion_full_content_summary_includes_notes_test() {
  assert keys(nested(completion(FullContent), "session_summary"))
    == [
      "confidence", "confidence_notes", "danger", "danger_notes", "turn_count",
    ]
}

pub fn completion_without_summary_omits_key_test() {
  let payload =
    trace_payloads.completion(
      policy: MetadataOnly,
      turn_usage: turn_usage(),
      summary: None,
      responses: loop.Responses(text: [], tool_calls: []),
      cancelled: True,
    )

  assert keys(payload) == ["ai_response_count", "cancelled", "usage"]
}
