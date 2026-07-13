//// Adapter for a custom OpenAI-compatible chat-completions endpoint —
//// the self-hosted route: Ollama, vLLM, LM Studio, llama.cpp, LiteLLM,
//// or any cloud API speaking the OpenAI wire shape. The message
//// projection and SSE decoding are shared with the other adapters via
//// `openai_compat`; this module owns where the request goes and how it
//// authenticates.
////
//// The request body is deliberately minimal — stream, model, messages,
//// tools — because strict servers reject fields they don't recognize,
//// and the engines this targets default sensibly. Operators can add
//// engine-specific fields via `extra_body`. Messages use the
//// leading-turn-context layout: every engine in this class does automatic
//// prefix caching, which a trailing volatile block defeats (see the
//// fireworks module docs for the measured rationale).

import atuin_ai_core/llm/client.{type ClientRequest}
import atuin_ai_core/llm/openai_compat
import dream_http_client/client as dream
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// Build with `options`, which validates the endpoint URL and resolves
/// the auth headers — the fields are public for the driver's
/// introspection, not for direct construction.
pub type Options {
  Options(
    scheme: http.Scheme,
    host: String,
    /// `None` uses the scheme default (80/443).
    port: Option(Int),
    /// The full request path, ending in "/chat/completions".
    path: String,
    /// The endpoint URL's query string, sent through verbatim
    /// (e.g. Azure's `api-version`).
    query: Option(String),
    /// Fully resolved: `{{api_key}}` expanded, content-type ensured.
    headers: List(#(String, String)),
    /// Sent verbatim as the body's `model`.
    model: String,
    /// Operator-supplied fields merged into the request body.
    extra_body: List(#(String, json.Json)),
  )
}

/// Body fields the adapter owns; `extra_body` may not override them.
const reserved_body_fields = ["stream", "model", "messages", "tools"]

const api_key_placeholder = "{{api_key}}"

/// Validates an endpoint URL — with or without the trailing
/// "/chat/completions", e.g. "http://localhost:11434/v1" — into `Options`.
/// Errors are operator-facing configuration messages.
///
/// `headers` values may reference `{{api_key}}`; `None` defaults to
/// `Authorization: Bearer {{api_key}}` when an API key is configured and
/// no auth header otherwise (local engines like Ollama). An explicit list
/// replaces the default entirely — the operator controls exactly what is
/// sent.
pub fn options(
  endpoint endpoint: String,
  api_key api_key: Option(String),
  headers headers: Option(List(#(String, String))),
  extra_body extra_body: List(#(String, json.Json)),
  model model: String,
) -> Result(Options, String) {
  use parsed <- result.try(
    uri.parse(endpoint)
    |> result.replace_error("invalid endpoint URL: " <> endpoint),
  )

  use scheme <- result.try(case parsed.scheme {
    Some("http") -> Ok(http.Http)
    Some("https") -> Ok(http.Https)
    Some(other) ->
      Error(
        "unsupported scheme \""
        <> other
        <> "\" in endpoint URL (use http:// or https://): "
        <> endpoint,
      )
    None -> Error("endpoint URL must include http:// or https://: " <> endpoint)
  })

  use host <- result.try(case parsed.host {
    Some("") | None -> Error("endpoint URL must include a host: " <> endpoint)
    Some(host) -> Ok(host)
  })

  use headers <- result.try(resolve_headers(headers, api_key))
  use extra_body <- result.try(check_reserved_fields(extra_body))

  Ok(Options(
    scheme:,
    host:,
    port: parsed.port,
    path: chat_completions_path(parsed.path),
    query: parsed.query,
    headers:,
    model:,
    extra_body:,
  ))
}

/// Appends "/chat/completions" unless the operator already pasted the
/// full endpoint URL including it.
fn chat_completions_path(path: String) -> String {
  let base = case string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }
  case string.ends_with(base, "/chat/completions") {
    True -> base
    False -> base <> "/chat/completions"
  }
}

fn resolve_headers(
  headers: Option(List(#(String, String))),
  api_key: Option(String),
) -> Result(List(#(String, String)), String) {
  let templates = case headers, api_key {
    Some(headers), _ -> headers
    None, Some(_) -> [#("authorization", "Bearer " <> api_key_placeholder)]
    None, None -> []
  }

  use expanded <- result.try(
    list.try_map(templates, fn(header) {
      let #(name, value) = header
      expand_api_key(value, api_key)
      |> result.map(fn(value) { #(name, value) })
    }),
  )

  Ok(ensure_content_type(expanded))
}

fn expand_api_key(
  value: String,
  api_key: Option(String),
) -> Result(String, String) {
  case string.contains(value, api_key_placeholder), api_key {
    False, _ -> Ok(value)
    True, Some(key) -> Ok(string.replace(value, api_key_placeholder, key))
    True, None ->
      Error(
        "header value \""
        <> value
        <> "\" references "
        <> api_key_placeholder
        <> " but no API key is configured",
      )
  }
}

fn ensure_content_type(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  let present =
    list.any(headers, fn(header) {
      string.lowercase(header.0) == "content-type"
    })
  case present {
    True -> headers
    False -> [#("content-type", "application/json"), ..headers]
  }
}

fn check_reserved_fields(
  extra_body: List(#(String, json.Json)),
) -> Result(List(#(String, json.Json)), String) {
  case
    list.find(extra_body, fn(field) {
      list.contains(reserved_body_fields, field.0)
    })
  {
    Ok(#(name, _)) ->
      Error(
        "request body field \""
        <> name
        <> "\" is set by the adapter and cannot be overridden",
      )
    Error(Nil) -> Ok(extra_body)
  }
}

pub fn prepare_request(options: Options, req: ClientRequest) -> ClientRequest {
  let dream_req =
    req.inner
    |> dream.method(http.Post)
    |> dream.scheme(options.scheme)
    |> dream.host(options.host)
    |> add_port(options.port)
    |> dream.path(options.path)
    |> add_query(options.query)
    |> add_headers(options.headers)

  let messages =
    openai_compat.assemble_leading_context(
      system: req.system,
      messages: req.messages,
      turn_context: req.turn_context,
    )

  let body =
    [
      #("stream", json.bool(True)),
      #("model", json.string(options.model)),
      #("messages", openai_compat.encode_messages(messages)),
    ]
    |> openai_compat.add_tools_field(req.tools)
    |> list.append(options.extra_body)
    |> json.object()

  client.ClientRequest(
    ..req,
    inner: dream_req |> dream.body(json.to_string(body)),
  )
}

fn add_port(
  dream_req: dream.ClientRequest,
  port: Option(Int),
) -> dream.ClientRequest {
  case port {
    None -> dream_req
    Some(port) -> dream.port(dream_req, port)
  }
}

fn add_query(
  dream_req: dream.ClientRequest,
  query: Option(String),
) -> dream.ClientRequest {
  case query {
    None -> dream_req
    Some(query) -> dream.query(dream_req, query)
  }
}

fn add_headers(
  dream_req: dream.ClientRequest,
  headers: List(#(String, String)),
) -> dream.ClientRequest {
  list.fold(headers, dream_req, fn(dream_req, header) {
    dream.add_header(dream_req, header.0, header.1)
  })
}
