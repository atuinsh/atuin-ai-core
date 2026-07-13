import atuin_ai_core/llm/client.{type ClientRequest}
import atuin_ai_core/llm/openai_compat
import dream_http_client/client as dream
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// x-anthropic-beta for beta headers for opus
// structured-outputs-2025-11-13 - enables structured outputs
// interleaved-thinking-2025-05-14 - allows reasoning to be interleaved with regular output

pub type OpenRouterOptions {
  OpenRouterOptions(
    model: String,
    api_key: String,
    anthropic_betas: List(AnthropicBetas),
    referer: Option(String),
    title: Option(String),
    provider_options: Option(ProviderOptions),
    /// Used for sticky provider routing
    session_id: Option(String),
    model_options: Option(OpenRouterModelOptions),
    /// Which messages to apply `cache_control` to.
    /// Positive numbers count from the first message, so `[0]` adds
    /// `cache_control` to the first message, `[1]` to the second, etc.
    /// Negative numbers count backwards from the last message, so `[-1]` adds
    /// `cache_control` to the last message, `[-2]` to the second-to-last, etc.
    cache_points: List(Int),
  )
}

pub type AnthropicBetas {
  /// Enables interleaved reasoning and output, allowing the model to reason
  /// about its output in the middle of generating it.
  InterleavedThinking
  /// Enables structured output, allowing the model to produce structured
  /// JSON data as output.
  StructuredOutput
}

pub type ProviderOptions {
  ProviderOptions(
    /// List of providers to try, in order
    order: Option(List(String)),
    /// Whether or not to allow falling back to
    /// another provider when primary is unavailable
    allow_fallbacks: Option(Bool),
    /// Only use providers that support all parameters in the request
    require_parameters: Option(Bool),
    /// Control whether to use providers that may store data
    data_collection: Option(AllowDeny),
    /// Restrict routing to only ZDR endpoints
    zero_data_retention: Option(Bool),
    /// Restrict routing to only models that allow text distillation
    enforce_distillable: Option(Bool),
    /// List of provider slugs to allow for this request
    only: Option(List(String)),
    /// List of provider slugs to skip for this request
    ignore: Option(List(String)),
  )
}

pub type OpenRouterModelOptions {
  OpenrouterModelOptions(
    max_tokens: Option(Int),
    temperature: Option(Int),
    seed: Option(Int),
    reasoning: Option(Reasoning),
  )
}

pub type AllowDeny {
  Allow
  Deny
}

pub type Reasoning {
  Reasoning(effort: Option(ReasoningEffort), summary: Option(ReasoningSummary))
}

pub type ReasoningEffort {
  Max
  Xhigh
  High
  Medium
  Low
  Minimal
  NoReasoning
}

pub type ReasoningSummary {
  Auto
  Concise
  Detailed
}

pub fn prepare_request(
  options: OpenRouterOptions,
  request: ClientRequest,
) -> ClientRequest {
  let betas_string = case options.anthropic_betas {
    [] -> None
    betas ->
      betas
      |> list.map(beta_to_string)
      |> string.join(",")
      |> Some
  }

  let dream_req =
    request.inner
    |> dream.method(http.Post)
    |> dream.scheme(http.Https)
    |> dream.host("openrouter.ai")
    |> dream.path("/api/v1/chat/completions")
    |> dream.add_header("authorization", "Bearer " <> options.api_key)
    |> dream.add_header("content-type", "application/json")
    |> maybe_add_header("x-session-id", options.session_id)
    |> maybe_add_header("http-referer", options.referer)
    |> maybe_add_header("x-openrouter-title", options.title)
    |> maybe_add_header("x-anthropic-beta", betas_string)

  let open_ai_messages =
    openai_compat.assemble(
      system: request.system,
      messages: request.messages,
      turn_context: request.turn_context,
      cache_points: options.cache_points,
    )

  let body =
    [
      #("stream", json.bool(True)),
      #("parallel_tool_calls", json.bool(True)),
      #("model", json.string(options.model)),
      #("messages", openai_compat.encode_messages(open_ai_messages)),
    ]
    |> maybe_add_model_options(options.model_options)
    |> maybe_add_provider_options(options.provider_options)
    |> openai_compat.add_tools_field(request.tools)
    |> json.object()

  let dream_req = dream_req |> dream.body(json.to_string(body))

  client.ClientRequest(..request, inner: dream_req)
}

fn maybe_add_header(
  req: dream.ClientRequest,
  key: String,
  value: Option(String),
) -> dream.ClientRequest {
  case value {
    None -> req
    Some(value) -> dream.add_header(req, key, value)
  }
}

fn maybe_add_model_options(
  body: List(#(String, json.Json)),
  model_options: Option(OpenRouterModelOptions),
) -> List(#(String, json.Json)) {
  case model_options {
    None -> body
    Some(options) ->
      body
      |> maybe_add_body_field(
        "max_completion_tokens",
        options.max_tokens,
        json.int,
      )
      |> maybe_add_body_field("temperature", options.temperature, json.int)
      |> maybe_add_body_field("seed", options.seed, json.int)
      |> maybe_add_reasoning(options.reasoning)
  }
}

fn maybe_add_reasoning(
  body: List(#(String, json.Json)),
  reasoning: Option(Reasoning),
) -> List(#(String, json.Json)) {
  case reasoning {
    None -> body
    Some(reasoning) -> {
      let reasoning_list =
        []
        |> maybe_add_body_field("effort", reasoning.effort, fn(effort) {
          json.string(reasoning_effort_to_string(effort))
        })
        |> maybe_add_body_field("summary", reasoning.summary, fn(summary) {
          json.string(reasoning_summary_to_string(summary))
        })

      case reasoning_list {
        [] -> body
        reasoning_json -> [#("reasoning", json.object(reasoning_json)), ..body]
      }
    }
  }
}

fn maybe_add_provider_options(
  body: List(#(String, json.Json)),
  provider_options: Option(ProviderOptions),
) -> List(#(String, json.Json)) {
  let opts = case provider_options {
    None -> []
    Some(options) -> {
      []
      |> maybe_add_body_field("order", options.order, fn(order) {
        json.preprocessed_array(list.map(order, json.string))
      })
      |> maybe_add_body_field(
        "allow_fallbacks",
        options.allow_fallbacks,
        json.bool,
      )
      |> maybe_add_body_field(
        "require_parameters",
        options.require_parameters,
        json.bool,
      )
      |> maybe_add_body_field(
        "data_collection",
        options.data_collection,
        fn(data_collection) {
          case data_collection {
            Allow -> json.string("allow")
            Deny -> json.string("deny")
          }
        },
      )
      |> maybe_add_body_field("zdr", options.zero_data_retention, json.bool)
      |> maybe_add_body_field(
        "enforce_distillable_text",
        options.enforce_distillable,
        json.bool,
      )
      |> maybe_add_body_field("only", options.only, fn(only) {
        json.preprocessed_array(list.map(only, json.string))
      })
      |> maybe_add_body_field("ignore_providers", options.ignore, fn(ignore) {
        json.preprocessed_array(list.map(ignore, json.string))
      })
    }
  }

  case opts {
    [] -> body
    opts -> [#("provider", json.object(opts)), ..body]
  }
}

fn maybe_add_body_field(
  body: List(#(String, json.Json)),
  key: String,
  value: Option(value),
  encode: fn(value) -> json.Json,
) -> List(#(String, json.Json)) {
  case value {
    None -> body
    Some(value) -> [#(key, encode(value)), ..body]
  }
}

fn beta_to_string(beta: AnthropicBetas) -> String {
  case beta {
    InterleavedThinking -> "interleaved-thinking-2025-05-14"
    StructuredOutput -> "structured-outputs-2025-11-13"
  }
}

fn reasoning_effort_to_string(effort: ReasoningEffort) -> String {
  case effort {
    Max -> "max"
    Xhigh -> "xhigh"
    High -> "high"
    Medium -> "medium"
    Low -> "low"
    Minimal -> "minimal"
    NoReasoning -> "none"
  }
}

fn reasoning_summary_to_string(summary: ReasoningSummary) -> String {
  case summary {
    Auto -> "auto"
    Concise -> "concise"
    Detailed -> "detailed"
  }
}
