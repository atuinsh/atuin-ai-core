import atuin_hub/cli_chat/domain/tools
import atuin_hub/cli_chat/http/request
import atuin_hub/cli_chat/llm/client
import atuin_hub/cli_chat/llm/openai_endpoint.{type Options}
import dream_http_client/client as dream
import gleam/http
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

/// The common case: everything defaulted except the endpoint and model.
fn plain_options(endpoint: String) -> Result(Options, String) {
  openai_endpoint.options(
    endpoint:,
    api_key: None,
    headers: None,
    extra_body: [],
    model: "llama3.3",
  )
}

// ---------------------------------------------------------------------
// Endpoint URL validation
// ---------------------------------------------------------------------

pub fn ollama_style_endpoint_test() {
  let assert Ok(options) = plain_options("http://localhost:11434/v1")

  assert options.scheme == http.Http
  assert options.host == "localhost"
  assert options.port == Some(11_434)
  assert options.path == "/v1/chat/completions"
  assert options.query == None
}

pub fn https_root_endpoint_test() {
  let assert Ok(options) = plain_options("https://api.example.com")

  assert options.scheme == http.Https
  assert options.port == None
  assert options.path == "/chat/completions"
}

pub fn trailing_slash_is_tolerated_test() {
  let assert Ok(options) = plain_options("http://127.0.0.1:8000/v1/")

  assert options.path == "/v1/chat/completions"
}

pub fn full_chat_completions_url_is_not_doubled_test() {
  let assert Ok(options) =
    plain_options("http://localhost:11434/v1/chat/completions")

  assert options.path == "/v1/chat/completions"
}

pub fn query_string_is_carried_through_test() {
  let assert Ok(options) =
    plain_options(
      "https://res.openai.azure.com/openai/deployments/gpt4/chat/completions?api-version=2024-06-01",
    )

  assert options.path == "/openai/deployments/gpt4/chat/completions"
  assert options.query == Some("api-version=2024-06-01")
}

pub fn query_string_survives_suffix_appending_test() {
  let assert Ok(options) = plain_options("https://proxy.example/v1?tenant=abc")

  assert options.path == "/v1/chat/completions"
  assert options.query == Some("tenant=abc")
}

pub fn missing_scheme_is_rejected_test() {
  let assert Error(message) = plain_options("localhost:11434/v1")
  assert string.contains(message, "http://")
}

pub fn unsupported_scheme_is_rejected_test() {
  let assert Error(message) = plain_options("ftp://host/v1")
  assert string.contains(message, "unsupported scheme")
}

pub fn missing_host_is_rejected_test() {
  let assert Error(message) = plain_options("http:///v1")
  assert string.contains(message, "host")
}

// ---------------------------------------------------------------------
// Header resolution
// ---------------------------------------------------------------------

pub fn no_key_and_no_headers_sends_only_content_type_test() {
  let assert Ok(options) = plain_options("http://localhost:11434/v1")

  assert options.headers == [#("content-type", "application/json")]
}

pub fn api_key_defaults_to_bearer_auth_test() {
  let assert Ok(options) =
    openai_endpoint.options(
      endpoint: "https://api.example.com/v1",
      api_key: Some("sekret"),
      headers: None,
      extra_body: [],
      model: "m",
    )

  assert options.headers
    == [
      #("content-type", "application/json"),
      #("authorization", "Bearer sekret"),
    ]
}

pub fn explicit_headers_replace_the_default_test() {
  let assert Ok(options) =
    openai_endpoint.options(
      endpoint: "https://res.openai.azure.com/openai/deployments/gpt4",
      api_key: Some("sekret"),
      headers: Some([#("api-key", "{{api_key}}")]),
      extra_body: [],
      model: "m",
    )

  assert options.headers
    == [#("content-type", "application/json"), #("api-key", "sekret")]
}

pub fn placeholder_expands_inside_a_larger_value_test() {
  let assert Ok(options) =
    openai_endpoint.options(
      endpoint: "https://api.example.com/v1",
      api_key: Some("sekret"),
      headers: Some([#("authorization", "Token {{api_key}}")]),
      extra_body: [],
      model: "m",
    )

  assert options.headers
    == [
      #("content-type", "application/json"),
      #("authorization", "Token sekret"),
    ]
}

pub fn placeholder_without_api_key_is_rejected_test() {
  let assert Error(message) =
    openai_endpoint.options(
      endpoint: "https://api.example.com/v1",
      api_key: None,
      headers: Some([#("authorization", "Bearer {{api_key}}")]),
      extra_body: [],
      model: "m",
    )

  assert string.contains(message, "{{api_key}}")
  assert string.contains(message, "no API key")
}

pub fn operator_content_type_is_not_duplicated_test() {
  let assert Ok(options) =
    openai_endpoint.options(
      endpoint: "https://api.example.com/v1",
      api_key: None,
      headers: Some([#("Content-Type", "application/json; charset=utf-8")]),
      extra_body: [],
      model: "m",
    )

  assert options.headers
    == [#("Content-Type", "application/json; charset=utf-8")]
}

// ---------------------------------------------------------------------
// Extra body fields
// ---------------------------------------------------------------------

pub fn reserved_body_field_is_rejected_test() {
  let assert Error(message) =
    openai_endpoint.options(
      endpoint: "http://localhost:11434/v1",
      api_key: None,
      headers: None,
      extra_body: [#("stream", json.bool(False))],
      model: "m",
    )

  assert string.contains(message, "stream")
  assert string.contains(message, "cannot be overridden")
}

// ---------------------------------------------------------------------
// Request preparation
// ---------------------------------------------------------------------

fn chat_request() -> client.ClientRequest {
  client.ClientRequest(
    inner: dream.new,
    system: Some("system prompt"),
    messages: [
      request.Message(role: request.User, content: request.Text("hello")),
    ],
    turn_context: Some("<turn_context>pwd</turn_context>"),
    tools: Some([tools.suggest_command()]),
  )
}

pub fn prepare_request_targets_the_endpoint_test() {
  let assert Ok(options) = plain_options("http://localhost:11434/v1")

  let prepared = openai_endpoint.prepare_request(options, chat_request())

  assert dream.get_method(prepared.inner) == http.Post
  assert dream.get_scheme(prepared.inner) == http.Http
  assert dream.get_host(prepared.inner) == "localhost"
  assert dream.get_port(prepared.inner) == Some(11_434)
  assert dream.get_path(prepared.inner) == "/v1/chat/completions"
  assert dream.get_query(prepared.inner) == None
}

pub fn prepare_request_sends_the_query_string_test() {
  let assert Ok(options) =
    openai_endpoint.options(
      endpoint: "https://res.openai.azure.com/openai/deployments/gpt4/chat/completions?api-version=2024-06-01",
      api_key: Some("sekret"),
      headers: Some([#("api-key", "{{api_key}}")]),
      extra_body: [],
      model: "gpt4",
    )

  let prepared = openai_endpoint.prepare_request(options, chat_request())

  assert dream.get_query(prepared.inner) == Some("api-version=2024-06-01")
  assert dream.get_headers(prepared.inner)
    |> list_find_header("api-key")
    == Some("sekret")
}

pub fn prepare_request_omits_auth_without_key_test() {
  let assert Ok(options) = plain_options("http://localhost:11434/v1")

  let prepared = openai_endpoint.prepare_request(options, chat_request())
  let headers = dream.get_headers(prepared.inner)

  assert !has_header(headers, "authorization")
  assert has_header(headers, "content-type")
}

pub fn prepare_request_sends_bearer_auth_with_key_test() {
  let assert Ok(options) =
    openai_endpoint.options(
      endpoint: "https://api.example.com/v1",
      api_key: Some("sekret"),
      headers: None,
      extra_body: [],
      model: "m",
    )

  let prepared = openai_endpoint.prepare_request(options, chat_request())

  assert dream.get_headers(prepared.inner)
    |> list_find_header("authorization")
    == Some("Bearer sekret")
}

pub fn prepare_request_body_is_minimal_test() {
  let assert Ok(options) = plain_options("http://localhost:11434/v1")

  let prepared = openai_endpoint.prepare_request(options, chat_request())
  let body = dream.get_body(prepared.inner)

  assert string.contains(body, "\"stream\":true")
  assert string.contains(body, "\"model\":\"llama3.3\"")
  assert string.contains(body, "\"tools\":")
  // The volatile turn-context block leads the conversation (automatic
  // prefix caching; see openai_compat.assemble_leading_context)...
  let assert Ok(#(before_hello, _)) = string.split_once(body, "hello")
  assert string.contains(before_hello, "turn_context")
  // ...and nothing OpenRouter/Anthropic-specific leaks into the body.
  assert !string.contains(body, "cache_control")
  assert !string.contains(body, "parallel_tool_calls")
}

pub fn prepare_request_merges_extra_body_fields_test() {
  let assert Ok(options) =
    openai_endpoint.options(
      endpoint: "http://localhost:11434/v1",
      api_key: None,
      headers: None,
      extra_body: [
        #("special_param", json.bool(True)),
        #("num_ctx", json.int(32_768)),
      ],
      model: "llama3.3",
    )

  let prepared = openai_endpoint.prepare_request(options, chat_request())
  let body = dream.get_body(prepared.inner)

  assert string.contains(body, "\"special_param\":true")
  assert string.contains(body, "\"num_ctx\":32768")
  assert string.contains(body, "\"stream\":true")
}

fn has_header(headers: List(dream.Header), name: String) -> Bool {
  list_find_header(headers, name) != None
}

fn list_find_header(
  headers: List(dream.Header),
  name: String,
) -> Option(String) {
  case headers {
    [] -> None
    [dream.Header(name: key, value:), ..rest] ->
      case string.lowercase(key) == name {
        True -> Some(value)
        False -> list_find_header(rest, name)
      }
  }
}
