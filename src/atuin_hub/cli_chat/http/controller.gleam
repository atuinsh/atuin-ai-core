import atuin_hub/cli_chat/domain/billing
import atuin_hub/cli_chat/domain/config
import atuin_hub/cli_chat/domain/models
import atuin_hub/cli_chat/domain/prompt
import atuin_hub/cli_chat/domain/usage.{type Usage}
import atuin_hub/cli_chat/engine/loop
import atuin_hub/cli_chat/engine/turn
import atuin_hub/cli_chat/http/driver
import atuin_hub/cli_chat/http/limits
import atuin_hub/cli_chat/http/request
import atuin_hub/cli_chat/http/streaming
import atuin_hub/cli_chat/http/trace
import atuin_hub/cli_chat/http/trace_payloads
import atuin_hub/cli_chat/instance.{type Instance, type RequestEnv}
import atuin_hub/ffi/log
import atuin_hub/ffi/plug.{type PlugConn}
import atuin_hub/ffi/uuid
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type ChatParams {
  ChatParams(
    messages: List(request.Message),
    session_id: Option(String),
    invocation_id: Option(String),
    config: config.Config,
    raw_model: Option(String),
    context: prompt.PromptContext,
  )
}

type ChatControllerPhase {
  PreStreaming
  PostStreaming
}

type ChatControllerError {
  InvalidSessionId
  MissingMessages
  ConversationTooLarge
  Disabled
  UnknownModel(String)
  LimitExceeded(limits.LimitDetails)
  DecodeError(decode.DecodeError)
  Disconnected
  Unknown(String)
}

type ChatControllerPhaseError {
  ChatControllerPhaseError(
    phase: ChatControllerPhase,
    error: ChatControllerError,
  )
}

/// Serves the model list for any instance's catalog.
pub fn models_response(
  conn: PlugConn,
  catalog: models.Catalog,
  llm_selection_enabled: Bool,
) -> PlugConn {
  let avail =
    catalog.models
    |> list.filter(fn(alias) { alias.visible_in_cli || llm_selection_enabled })
    |> list.map(fn(alias) {
      dynamic.properties([
        #(dynamic.string("alias"), dynamic.string(alias.alias)),
        #(dynamic.string("name"), dynamic.string(alias.display_name)),
        #(dynamic.string("description"), dynamic.string(alias.description)),
      ])
    })

  case
    plug.json(
      conn,
      dynamic.properties([
        #(dynamic.string("models"), dynamic.list(avail)),
        #(dynamic.string("default"), dynamic.string(catalog.default_alias)),
      ]),
    )
  {
    Ok(conn) -> conn
    Error(str) -> {
      result.unwrap(
        send_error(
          conn,
          500,
          "internal_error",
          "Failed to encode model list: " <> str,
        ),
        conn,
      )
    }
  }
}

/// Serves one chat request against any instance — the host-agnostic
/// entry point.
pub fn serve(
  conn: PlugConn,
  params: Dynamic,
  inst: Instance,
  env: RequestEnv,
) -> PlugConn {
  case do_chat(conn, params, inst, env) {
    Ok(conn) -> conn
    // Controller-phase errors (bad request, limits, stream init) are not
    // recorded as usage — nothing was generated. Failures *during* a turn
    // are recorded by record_outcome via the Failed outcome.
    Error(ChatControllerPhaseError(phase, error)) -> {
      log.error("Error during request: " <> string.inspect(error))

      case error, phase {
        Disconnected, _ -> conn
        _, PreStreaming ->
          result.unwrap(send_pre_stream_error(conn, error), conn)
        _, PostStreaming -> {
          let #(_, error_str, message) = describe_error(error)
          result.unwrap(
            stream_error(conn, error_str, option.Some(message)),
            conn,
          )
        }
      }
    }
  }
}

fn do_chat(
  conn: PlugConn,
  params: Dynamic,
  inst: Instance,
  env: RequestEnv,
) -> Result(PlugConn, ChatControllerPhaseError) {
  use params <- result.try(
    decode_params(params, inst.catalog) |> result.map_error(pre_stream_error),
  )
  use session_id <- result.try(
    ensure_session_id(params) |> result.map_error(pre_stream_error),
  )
  let params = ChatParams(..params, session_id: Some(session_id))

  use _ <- result.try(
    check_conversation_size(params.messages)
    |> result.map_error(pre_stream_error),
  )
  // convert messages to internal format <- these should be typed
  let app_version = get_client_version(conn)
  let config = config.Config(..params.config, app_version:)
  let config =
    config.apply_feature_gates(
      config,
      inst.catalog,
      params.raw_model,
      env.options_enabled,
      env.llm_selection_enabled,
    )

  use charge_target <- result.try(
    inst.limiter.check(env.user_id)
    |> result.map_error(limit_error)
    |> result.map_error(pre_stream_error),
  )

  let resolved_alias = config.resolved_alias(config, inst.catalog)

  // None only when the catalog's default alias doesn't resolve — a
  // deployment configuration error, reported like any unknown model.
  use resolved_model <- result.try(
    config.resolved_provider_id(config, inst.catalog)
    |> option.to_result(pre_stream_error(UnknownModel(resolved_alias))),
  )

  use llm_options <- result.try(
    inst.backend(resolved_model, session_id)
    |> option.to_result(pre_stream_error(UnknownModel(resolved_model))),
  )

  use conn <- result.try(
    streaming.init_stream(conn, session_id)
    |> result.map_error(Unknown)
    |> result.map_error(post_stream_error),
  )
  // If the connection is *already* gone, we can just kill the generation.
  use conn <- result.try(
    streaming.send_status(conn, "processing")
    |> result.map_error(fn(_) { post_stream_error(Disconnected) }),
  )

  let trace_context =
    trace.TraceContext(
      trace_id: uuid.uuidv7(),
      session_id:,
      user_id: env.user_id,
      invocation_id: params.invocation_id,
      client_version: config.app_version,
      model_alias: resolved_alias,
      model: resolved_model,
      charge_info: charge_target,
    )

  inst.recorder.trace_event(
    trace_context,
    client_request_event(env.content_policy, params, config, trace_context),
  )

  // Both prompts are built once per request: the system prompt must stay
  // byte-identical across the loop's iterations for prompt caching, and
  // the turn context (pwd, last command, date) is re-appended as the final
  // message of every LLM call.
  let system = system_prompt(inst, params, config)
  let turn_context = prompt.turn_context(params.context, env.current_date)

  // Server-tool results come back from the client as remote references;
  // resolve them to the stored content before anything reads the messages.
  let messages =
    request.hydrate(params.messages, fn(tool_use_id) {
      inst.tool_results.fetch(env.user_id, tool_use_id)
    })

  log.debug("Starting LLM loop")
  let result =
    driver.run(
      conn,
      driver.Context(
        session_id:,
        options: llm_options,
        base_request: inst.base_request,
        system: Some(system),
        messages:,
        turn_context: Some(turn_context),
        tools: instance.tool_list(inst, config.capabilities),
        is_server_tool: instance.is_server_tool(inst, _),
        execute_tool: instance.execute_server_tool(inst, _),
        store_tool_result: fn(result) {
          inst.tool_results.store(instance.StoredToolResult(
            user_id: env.user_id,
            tool_use_id: result.id,
            tool_name: result.name,
            content: result.result,
            is_error: result.is_error,
          ))
        },
        trace: fn(event) { inst.recorder.trace_event(trace_context, event) },
        credits: fn(turn_usage) {
          credits_payload(inst, trace_context, turn_usage)
        },
        content_policy: env.content_policy,
      ),
    )

  record_outcome(
    inst,
    trace_context,
    env.content_policy,
    params.messages,
    result,
  )

  Ok(result.conn)
}

// The instance's prompt extensions append after the built-in prompt: the
// enabled capabilities' sections, then the operator's extra guidance. With
// no extensions configured this is byte-identical to the built-in prompt.
fn system_prompt(
  inst: Instance,
  params: ChatParams,
  config: config.Config,
) -> String {
  let base =
    prompt.select(
      params.context,
      config,
      prompt.Host(
        dev_mode: inst.prompt.dev_mode,
        safety_prompt: inst.prompt.safety_prompt,
      ),
    )

  [base, ..instance.capability_prompt_sections(inst, config.capabilities)]
  |> list.append(option.values([inst.prompt.extra_guidance]))
  |> string.join("\n\n")
}

// ---------------------------------------------------------------------
// Post-turn recording: usage records + completion traces. All best-effort
// — the response has already streamed by the time any of this runs.
// ---------------------------------------------------------------------

fn record_outcome(
  inst: Instance,
  context: trace.TraceContext,
  policy: trace.ContentPolicy,
  messages: List(request.Message),
  result: driver.TurnResult,
) -> Nil {
  // Under the metadata-only policy the usage record carries billing data
  // with no conversation content.
  let instruction = case policy {
    trace.MetadataOnly -> None
    trace.FullContent -> Some(extract_instruction(messages))
  }

  case result.outcome {
    loop.Success(usage:, summary:) ->
      record_billed(
        inst,
        context,
        policy,
        instruction,
        result.responses,
        usage,
        Some(summary),
        cancelled: False,
      )

    // A cancelled turn (client disconnected mid-stream) is billed like a
    // success, but tagged so the trace records it.
    loop.Cancelled(usage:, summary:) ->
      record_billed(
        inst,
        context,
        policy,
        instruction,
        result.responses,
        usage,
        Some(summary),
        cancelled: True,
      )

    loop.PausedForClientTools(usage:) ->
      record_billed(
        inst,
        context,
        policy,
        instruction,
        result.responses,
        usage,
        None,
        cancelled: False,
      )

    // The error event was already streamed to the client; record the
    // failure (not charged — excluded from limits by success: false) with
    // whatever tokens the request consumed before dying.
    loop.Failed(error_type:, usage:) ->
      inst.recorder.failed(
        context,
        instance.FailedTurn(error_type:, instruction:, usage: Some(usage)),
      )
  }
}

fn record_billed(
  inst: Instance,
  context: trace.TraceContext,
  policy: trace.ContentPolicy,
  instruction: Option(String),
  responses: loop.Responses,
  turn_usage: Usage,
  summary: Option(turn.SessionSummary),
  cancelled cancelled: Bool,
) -> Nil {
  let billing.CostResult(computed:, missing_anthropic_pricing:) =
    compute_cost(inst, context, turn_usage)

  // Computed cost is the cost of record when no provider cost exists, so a
  // silent fallback would bill an Opus-class model at Sonnet rates.
  case missing_anthropic_pricing {
    True ->
      log.warning(
        "[cli_chat] no pricing entry for Anthropic model "
        <> context.model
        <> " - computing cost at the default (Sonnet) rate",
      )
    False -> Nil
  }

  let response = case policy {
    trace.MetadataOnly -> None
    trace.FullContent -> Some(response_text(responses))
  }

  inst.recorder.billed(
    context,
    instance.BilledTurn(
      instruction:,
      response:,
      tool_call_names: tool_call_names(responses),
      usage: turn_usage,
      billing: computed,
    ),
  )

  // session_complete marks a fully finished session; a request that pauses
  // for client tools emits request_complete instead, so every charged
  // request carries its usage and billing in the trace exactly once.
  inst.recorder.trace_event(
    context,
    completion_event(
      policy,
      turn_usage,
      computed,
      summary,
      responses,
      cancelled,
    ),
  )
}

fn compute_cost(
  inst: Instance,
  context: trace.TraceContext,
  turn_usage: Usage,
) -> billing.CostResult {
  billing.compute_for_catalog(
    raw_usage(turn_usage),
    inst.catalog,
    model_alias: context.model_alias,
    model_id: context.model,
  )
}

fn raw_usage(turn_usage: Usage) -> billing.RawUsage {
  billing.RawUsage(
    input_tokens: turn_usage.input_tokens,
    output_tokens: turn_usage.output_tokens,
    cached_tokens: turn_usage.cached_tokens,
    cache_creation_tokens: turn_usage.cache_creation_tokens,
  )
}

/// The `credits` object for the done event: the requester's period totals
/// against their limits, so the TUI can render usage percent without a
/// second request. The stored totals can't include the turn still being
/// streamed (it's recorded after the stream ends), so its credits are
/// added here. Limits use the UsageLimit sentinels: -1 unlimited, 0
/// disabled.
fn credits_payload(
  inst: Instance,
  context: trace.TraceContext,
  turn_usage: Usage,
) -> Option(dynamic.Dynamic) {
  case inst.limiter.credits(context.charge_info) {
    None -> None
    Some(snapshot) -> {
      let billing.CostResult(computed:, ..) =
        compute_cost(inst, context, turn_usage)

      Some(
        dynamic.properties([
          #(dynamic.string("period"), dynamic.string(snapshot.period)),
          #(dynamic.string("resets_at"), dynamic.string(snapshot.resets_at)),
          #(
            dynamic.string("requests"),
            used_and_limit(snapshot.requests_used + 1, snapshot.requests_limit),
          ),
          #(
            dynamic.string("input"),
            used_and_limit(
              snapshot.input_used + computed.billable_input_tokens,
              snapshot.input_limit,
            ),
          ),
          #(
            dynamic.string("output"),
            used_and_limit(
              snapshot.output_used + computed.billable_output_tokens,
              snapshot.output_limit,
            ),
          ),
        ]),
      )
    }
  }
}

fn used_and_limit(used: Int, limit: Int) -> dynamic.Dynamic {
  dynamic.properties([
    #(dynamic.string("used"), dynamic.int(used)),
    #(dynamic.string("limit"), dynamic.int(limit)),
  ])
}

fn completion_event(
  policy: trace.ContentPolicy,
  turn_usage: Usage,
  computed: billing.Computed,
  summary: Option(turn.SessionSummary),
  responses: loop.Responses,
  cancelled: Bool,
) -> trace.Event {
  let #(event_type, event_order) = case summary {
    Some(_) -> #("session_complete", 9999)
    None -> #("request_complete", 9998)
  }

  let payload =
    trace_payloads.completion(
      policy:,
      turn_usage:,
      summary:,
      responses:,
      cancelled:,
    )

  trace.Event(
    ..trace.event(event_type:, event_order:, payload:),
    input_tokens: Some(turn_usage.input_tokens),
    output_tokens: Some(turn_usage.output_tokens),
    cached_tokens: Some(turn_usage.cached_tokens),
    cache_creation_tokens: Some(turn_usage.cache_creation_tokens),
    billable_input_tokens: Some(computed.billable_input_tokens),
    billable_output_tokens: Some(computed.billable_output_tokens),
    input_token_mult: Some(computed.input_token_mult),
    output_token_mult: Some(computed.output_token_mult),
    computed_cost: Some(computed.computed_cost),
    provider_cost: turn_usage.provider_cost,
  )
}

// Last user message with plain-text content, truncated, used as the usage
// record's instruction. Block-content messages (tool results) fall through
// to the generic label, matching the historical behavior.
fn extract_instruction(messages: List(request.Message)) -> String {
  messages
  |> list.reverse
  |> list.find_map(fn(message) {
    case message.role, message.content {
      request.User, request.Text(text) -> Ok(string.slice(text, 0, 200))
      request.User, request.Blocks(_) -> Ok("conversation")
      request.Assistant, _ -> Error(Nil)
    }
  })
  |> result.unwrap("conversation")
}

// Tool-call names for the usage record's metadata, in execution order —
// the admin usage screens render the per-turn tool sequence from these
// instead of parsing tool lines out of the (now often absent) response
// text. Names come from the server's tool whitelist, so they're
// metadata-safe under any content policy.
fn tool_call_names(responses: loop.Responses) -> List(String) {
  list.map(responses.tool_calls, fn(summarized) { summarized.call.name })
}

// The recorded response: streamed text, then the tool-call summaries.
fn response_text(responses: loop.Responses) -> String {
  let text = string.join(responses.text, "\n")
  let tool_summaries =
    responses.tool_calls
    |> list.map(fn(summarized) { summarized.summary })
    |> string.join("\n")

  [text, tool_summaries]
  |> list.filter(fn(part) { part != "" })
  |> string.join("\n\n")
}

// `capabilities` (inside the payload) is the canonical wire-form list
// (derived from the parsed struct) so the trace reflects what the server
// actually honored, not the raw client input. The model fields are the
// *resolved* values after defaults — this is what the trace UI displays.
fn client_request_event(
  policy: trace.ContentPolicy,
  params: ChatParams,
  config: config.Config,
  context: trace.TraceContext,
) -> trace.Event {
  trace.event(
    event_type: "client_request",
    event_order: 0,
    payload: trace_payloads.client_request(
      policy:,
      messages: params.messages,
      config:,
      context: params.context,
      invocation_id: params.invocation_id,
      client_version: context.client_version,
      model_alias: context.model_alias,
      model: context.model,
    ),
  )
}

fn pre_stream_error(error: ChatControllerError) -> ChatControllerPhaseError {
  ChatControllerPhaseError(PreStreaming, error)
}

fn post_stream_error(error: ChatControllerError) -> ChatControllerPhaseError {
  ChatControllerPhaseError(PostStreaming, error)
}

fn limit_error(error: limits.LimitCheckError) -> ChatControllerError {
  case error {
    limits.Disabled -> Disabled
    limits.LimitExceeded(details) -> LimitExceeded(details)
    limits.Unknown(message) -> Unknown(message)
  }
}

fn decode_params(
  params: Dynamic,
  catalog: models.Catalog,
) -> Result(ChatParams, ChatControllerError) {
  use params <- result.try(
    decode.run(params, params_decoder(catalog))
    |> result.map_error(fn(errors) {
      case list.first(errors) {
        Ok(error) -> DecodeError(error)
        Error(Nil) -> Unknown("Unknown decode error")
      }
    }),
  )

  case params.messages {
    [] -> Error(MissingMessages)
    _ -> Ok(params)
  }
}

fn params_decoder(catalog: models.Catalog) -> decode.Decoder(ChatParams) {
  use raw_params <- decode.then(decode.dynamic)
  use messages <- decode.optional_field(
    "messages",
    [],
    request.messages_decoder(),
  )
  use session_id <- decode.optional_field(
    "session_id",
    option.None,
    decode.optional(decode.string),
  )
  use invocation_id <- decode.optional_field(
    "invocation_id",
    option.None,
    decode.optional(decode.string),
  )
  use context <- decode.optional_field(
    "context",
    prompt.empty_context(),
    context_decoder(),
  )
  let config = config.from_params(raw_params, catalog)
  let raw_model = config.raw_model_from_params(raw_params)

  decode.success(ChatParams(
    messages: messages,
    session_id: session_id,
    invocation_id: invocation_id,
    config: config,
    raw_model: raw_model,
    context: context,
  ))
}

// Decodes the client's `context` object into the fields the prompt reads.
// The client also sends keys this server doesn't use (path,
// installed_commands); they are ignored. Context is advisory, never a
// reason to reject a request:
// any field that isn't a string decays to None, and a context that isn't
// a map at all decays to the empty context.
fn context_decoder() -> decode.Decoder(prompt.PromptContext) {
  decode.one_of(
    {
      use os <- lenient_context_field("os")
      use distro <- lenient_context_field("distro")
      use shell <- lenient_context_field("shell")
      use preferred_language <- lenient_context_field("preferred_language")
      use pwd <- lenient_context_field("pwd")
      use last_command <- lenient_context_field("last_command")

      decode.success(prompt.PromptContext(
        os:,
        distro:,
        shell:,
        preferred_language:,
        pwd:,
        last_command:,
      ))
    },
    [decode.success(prompt.empty_context())],
  )
}

fn lenient_context_field(
  field: String,
  next: fn(Option(String)) -> decode.Decoder(final),
) -> decode.Decoder(final) {
  decode.optional_field(
    field,
    None,
    decode.one_of(decode.string |> decode.map(Some), [decode.success(None)]),
    next,
  )
}

fn ensure_session_id(
  params: ChatParams,
) -> Result(String, ChatControllerError) {
  case params.session_id {
    Some(session_id) ->
      case session_id {
        "" -> Ok(uuid.uuidv7())
        _ ->
          case uuid.valid(session_id) {
            True -> Ok(session_id)
            False -> Error(InvalidSessionId)
          }
      }
    None -> Ok(uuid.uuidv7())
  }
}

fn check_conversation_size(
  messages: List(request.Message),
) -> Result(Nil, ChatControllerError) {
  case request.estimate_tokens(messages) {
    request.ConversationTooLarge -> Error(ConversationTooLarge)
    request.Estimated(_) -> Ok(Nil)
  }
}

fn get_client_version(conn: PlugConn) -> Option(String) {
  let user_agent = plug.get_req_header(conn, "user-agent")
  case user_agent {
    [] -> option.None
    [header, ..] -> parse_client_version(header)
  }
}

fn parse_client_version(user_agent: String) -> Option(String) {
  case string.split_once(user_agent, "atuin/") {
    Ok(#(_, rest)) ->
      case string.split(rest, " ") {
        ["", ..] -> option.None
        [version, ..] -> option.Some(version)
        [] -> option.None
      }
    Error(Nil) -> option.None
  }
}

fn describe_error(error: ChatControllerError) -> #(Int, String, String) {
  case error {
    InvalidSessionId -> #(
      400,
      "invalid_request",
      "Invalid session_id format - must be a valid UUID",
    )
    MissingMessages -> #(
      400,
      "invalid_request",
      "messages field is required and must be a non-empty array",
    )
    ConversationTooLarge -> #(
      400,
      "conversation_too_large",
      "Conversation exceeds maximum allowed size of 180,000 tokens",
    )
    Disabled -> #(
      403,
      "feature_disabled",
      "CLI chat is disabled for this account",
    )
    UnknownModel(model) -> #(
      400,
      "invalid_request",
      "Model not available on this server: " <> model,
    )
    Disconnected -> #(
      499,
      "client_disconnected",
      "Client disconnected before response could be sent",
    )
    LimitExceeded(details) -> #(
      429,
      "rate_limit_exceeded",
      limit_exceeded_message(details.limit_type),
    )
    DecodeError(decode_error) -> #(
      400,
      "invalid_request",
      "Failed to decode request parameters: expected "
        <> decode_error.expected
        <> ", got "
        <> decode_error.found
        <> " at path "
        <> string.join(decode_error.path, "."),
    )
    Unknown(_) -> #(500, "internal_error", "An unknown error occurred")
  }
}

fn send_pre_stream_error(
  conn: PlugConn,
  error: ChatControllerError,
) -> Result(PlugConn, String) {
  case error {
    LimitExceeded(details) -> send_rate_limit_error(conn, details)
    _ -> {
      let #(code, error_str, message) = describe_error(error)
      send_error(conn, code, error_str, message)
    }
  }
}

fn send_rate_limit_error(
  conn: PlugConn,
  details: limits.LimitDetails,
) -> Result(PlugConn, String) {
  let data =
    dynamic.properties([
      #(dynamic.string("error"), dynamic.string("rate_limit_exceeded")),
      #(
        dynamic.string("message"),
        dynamic.string(limit_exceeded_message(details.limit_type)),
      ),
      #(dynamic.string("limit"), dynamic.int(details.limit)),
      #(dynamic.string("used"), dynamic.int(details.used)),
    ])

  Ok(conn)
  |> result.try(plug.put_resp_header(
    _,
    "retry-after",
    int.to_string(details.retry_after_seconds),
  ))
  |> result.try(plug.put_resp_header(_, "content-type", "application/json"))
  |> result.try(plug.put_status(_, 429))
  |> result.try(plug.json(_, data))
}

// CLI token limits are enforced in credits (billable tokens × the alias's
// multiplier), so the user-visible message says credits; the raw
// limit_type strings are the Elixir-side atoms and stay internal.
fn limit_exceeded_message(limit_type: String) -> String {
  let noun = case limit_type {
    "input_tokens" -> "input credit"
    "output_tokens" -> "output credit"
    "requests" -> "request"
    other -> other
  }
  noun <> " limit exceeded"
}

fn send_error(conn, code, error, message) -> Result(PlugConn, String) {
  let data =
    dynamic.properties([
      #(dynamic.string("error"), dynamic.string(error)),
      #(dynamic.string("message"), dynamic.string(message)),
    ])

  Ok(conn)
  |> result.try(plug.put_resp_header(_, "content-type", "application/json"))
  |> result.try(plug.put_status(_, code))
  |> result.try(plug.json(_, data))
}

fn stream_error(conn, error, message) {
  streaming.send_error(conn, error, message)
}
