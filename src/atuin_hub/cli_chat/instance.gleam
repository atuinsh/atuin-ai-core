//// The composition root for a chat backend.
////
//// An `Instance` gathers everything host-specific about the CLI chat
//// engine into one value, assembled once at boot: the model catalog and
//// how each resolved model reaches its provider, the server-side tools,
//// the client tools each declared capability unlocks, and the ports
//// through which a turn touches the outside world — limits, recording,
//// and server-tool result persistence.
////
//// `new` yields a fully working *stateless* instance: requests are never
//// limited, nothing is recorded, and server-tool results stream inline to
//// the client instead of being persisted. Each `with_*` call layers on one
//// host concern, so deployments differ only in their builder pipeline,
//// never in engine code:
////
//// ```gleam
//// // Self-hosted: one backend, stateless defaults.
//// instance.new(catalog, backend)
////
//// // Hosted: the same core plus the hosted-only concerns.
//// instance.new(catalog, backend)
//// |> instance.with_server_tool(web_search.web_search(), execute_search)
//// |> instance.with_server_tool(web_scrape.web_scrape(), execute_scrape)
//// |> instance.with_limiter(credits_limiter)
//// |> instance.with_recorder(trace_recorder)
//// |> instance.with_tool_result_store(postgres_store)
//// ```
////
//// Registration order is part of the contract: `tool_list` emits tools in
//// registration order, and the tool list is part of the prompt-cache
//// prefix, so a deployment's registration order must stay stable.

import atuin_hub/cli_chat/domain/billing
import atuin_hub/cli_chat/domain/capabilities.{type Capabilities}
import atuin_hub/cli_chat/domain/models
import atuin_hub/cli_chat/domain/tools.{type ToolDefinition}
import atuin_hub/cli_chat/domain/usage.{type Usage}
import atuin_hub/cli_chat/engine/turn.{type ToolCall, type ToolResult}
import atuin_hub/cli_chat/http/driver
import atuin_hub/cli_chat/http/limits.{
  type ChargeTarget, type CreditsSnapshot, type LimitCheckError,
}
import atuin_hub/cli_chat/http/trace.{type ContentPolicy}
import dream_http_client/client as dream
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None}

// ---------------------------------------------------------------------
// Configuration values
// ---------------------------------------------------------------------

/// Maps a resolved provider model ID (e.g. "openrouter:anthropic/...") and
/// the session ID to the LLM backend options for a turn. `None` means the
/// instance has no backend serving the model. The API keys live inside the
/// closure.
pub type Backend =
  fn(String, String) -> Option(driver.LlmOptions)

/// System-prompt configuration. The built-in prompt (including
/// suggest_command guidance) ships with the engine; these are the
/// host-specific parts.
pub type PromptSettings {
  PromptSettings(
    dev_mode: Bool,
    /// Appended verbatim to the system prompt; shared with the host's
    /// other AI endpoints in the hosted deployment.
    safety_prompt: String,
    /// Free-form section appended after the built-in prompt and any
    /// capability prompt sections — the single operator extension point
    /// for now.
    extra_guidance: Option(String),
  )
}

/// A tool the *server* executes mid-turn, as opposed to the client tools
/// declared via capabilities. The executor receives the tool-call input
/// and returns the result text; an `Error` becomes an error tool result
/// for the model to react to, never a failed turn.
pub type ServerTool {
  ServerTool(
    definition: ToolDefinition,
    execute: fn(Dynamic) -> Result(String, String),
  )
}

/// Ties a client capability (wire string) to the tool it unlocks and,
/// optionally, the system-prompt section that should accompany it.
pub type CapabilityBinding {
  CapabilityBinding(
    /// The wire string the client must declare, e.g. "client_v1_read_file".
    capability: String,
    tool: ToolDefinition,
    /// Appended to the system prompt when the capability is enabled.
    prompt_section: Option(String),
  )
}

/// The bindings for the standard Atuin CLI client protocol, in the
/// prompt-cache-stable order `tools.client_tools` established.
/// `client_invocations` is deliberately absent: it gates a protocol
/// feature (invocation IDs), not a tool.
pub fn standard_bindings() -> List(CapabilityBinding) {
  [
    CapabilityBinding("client_v1_read_file", tools.read_file(), None),
    CapabilityBinding("client_v1_edit_file", tools.edit_file(), None),
    CapabilityBinding("client_v1_write_file", tools.write_file(), None),
    CapabilityBinding("client_v1_atuin_history", tools.atuin_history(), None),
    CapabilityBinding("client_v1_atuin_output", tools.atuin_output(), None),
    CapabilityBinding(
      "client_v1_execute_shell_command",
      tools.execute_shell_command(),
      None,
    ),
    CapabilityBinding("client_v1_load_skill", tools.load_skill(), None),
  ]
}

// ---------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------

/// Admission control for a turn. `check` runs before anything streams;
/// `credits` builds the usage snapshot for the done event (`None` omits
/// the credits object, which released clients tolerate).
pub type Limiter {
  Limiter(
    check: fn(String) -> Result(ChargeTarget, LimitCheckError),
    credits: fn(ChargeTarget) -> Option(CreditsSnapshot),
  )
}

/// Never limits: every user is their own unlimited charge target and no
/// credits snapshot exists.
pub fn open_limiter() -> Limiter {
  Limiter(check: fn(user_id) { Ok(limits.User(user_id)) }, credits: fn(_) {
    None
  })
}

/// A billed turn (success, cancelled mid-stream, or paused for client
/// tools — all charged alike), as reported to the recorder. Instruction
/// and response are `None` under the metadata-only content policy.
pub type BilledTurn {
  BilledTurn(
    instruction: Option(String),
    response: Option(String),
    /// In execution order; names come from the server's tool whitelist,
    /// so they're metadata-safe under any policy.
    tool_call_names: List(String),
    usage: Usage,
    billing: billing.Computed,
  )
}

/// A failed turn — not charged, but kept with whatever tokens were
/// consumed before the failure.
pub type FailedTurn {
  FailedTurn(
    error_type: String,
    instruction: Option(String),
    usage: Option(Usage),
  )
}

/// Where turn outcomes and trace events go. All best-effort and
/// fire-and-forget: a recorder must never affect the response.
pub type Recorder {
  Recorder(
    trace_event: fn(trace.TraceContext, trace.Event) -> Nil,
    billed: fn(trace.TraceContext, BilledTurn) -> Nil,
    failed: fn(trace.TraceContext, FailedTurn) -> Nil,
  )
}

/// Records nothing.
pub fn null_recorder() -> Recorder {
  Recorder(
    trace_event: fn(_, _) { Nil },
    billed: fn(_, _) { Nil },
    failed: fn(_, _) { Nil },
  )
}

pub type StoredToolResult {
  StoredToolResult(
    user_id: String,
    tool_use_id: String,
    tool_name: String,
    content: String,
    is_error: Bool,
  )
}

/// Persistence for server-tool results. A failed `store` makes the result
/// stream inline to the client instead — the conversation always
/// continues (the error carries no detail because that fallback is the
/// only reaction; implementations log specifics themselves). `fetch`
/// hydrates `remote: true` references on replay by user ID and
/// tool_use_id; `None` (expired, or never stored) degrades to a
/// placeholder.
pub type ToolResultStore {
  ToolResultStore(
    store: fn(StoredToolResult) -> Result(Nil, Nil),
    fetch: fn(String, String) -> Option(String),
  )
}

/// Persists nothing: every server-tool result streams inline and remote
/// references never resolve.
pub fn inline_tool_results() -> ToolResultStore {
  ToolResultStore(store: fn(_) { Error(Nil) }, fetch: fn(_, _) { None })
}

// ---------------------------------------------------------------------
// The instance
// ---------------------------------------------------------------------

pub type Instance {
  Instance(
    catalog: models.Catalog,
    backend: Backend,
    prompt: PromptSettings,
    server_tools: List(ServerTool),
    capabilities: List(CapabilityBinding),
    limiter: Limiter,
    recorder: Recorder,
    tool_results: ToolResultStore,
    /// The dream request each LLM call starts from — `dream.new` outside
    /// of tests, where a playback recorder is attached instead.
    base_request: dream.ClientRequest,
  )
}

/// A stateless instance serving the standard client protocol: no limits,
/// no recording, no server tools, inline tool results.
pub fn new(catalog: models.Catalog, backend: Backend) -> Instance {
  Instance(
    catalog:,
    backend:,
    prompt: PromptSettings(
      dev_mode: False,
      safety_prompt: "",
      extra_guidance: None,
    ),
    server_tools: [],
    capabilities: standard_bindings(),
    limiter: open_limiter(),
    recorder: null_recorder(),
    tool_results: inline_tool_results(),
    base_request: dream.new,
  )
}

pub fn with_prompt(instance: Instance, prompt: PromptSettings) -> Instance {
  Instance(..instance, prompt:)
}

/// Registers a server tool. Registration order is the wire order — part
/// of the prompt-cache prefix.
pub fn with_server_tool(
  instance: Instance,
  definition: ToolDefinition,
  execute: fn(Dynamic) -> Result(String, String),
) -> Instance {
  Instance(
    ..instance,
    server_tools: list.append(instance.server_tools, [
      ServerTool(definition:, execute:),
    ]),
  )
}

/// Appends a capability binding after the standard set.
pub fn with_capability(
  instance: Instance,
  binding: CapabilityBinding,
) -> Instance {
  Instance(
    ..instance,
    capabilities: list.append(instance.capabilities, [binding]),
  )
}

/// Replaces the capability bindings wholesale, for deployments that serve
/// a non-standard client.
pub fn with_capabilities(
  instance: Instance,
  bindings: List(CapabilityBinding),
) -> Instance {
  Instance(..instance, capabilities: bindings)
}

pub fn with_limiter(instance: Instance, limiter: Limiter) -> Instance {
  Instance(..instance, limiter:)
}

pub fn with_recorder(instance: Instance, recorder: Recorder) -> Instance {
  Instance(..instance, recorder:)
}

pub fn with_tool_result_store(
  instance: Instance,
  tool_results: ToolResultStore,
) -> Instance {
  Instance(..instance, tool_results:)
}

pub fn with_base_request(
  instance: Instance,
  base_request: dream.ClientRequest,
) -> Instance {
  Instance(..instance, base_request:)
}

// ---------------------------------------------------------------------
// Derived views the engine consumes
// ---------------------------------------------------------------------

/// The tool list for a turn: suggest_command, then the server tools, then
/// the client tools whose capabilities the client declared — all in
/// registration order, which the prompt cache depends on.
pub fn tool_list(
  instance: Instance,
  caps: Capabilities,
) -> List(ToolDefinition) {
  list.flatten([
    [tools.suggest_command()],
    list.map(instance.server_tools, fn(tool) { tool.definition }),
    instance.capabilities
      |> list.filter(fn(binding) { capabilities.has(caps, binding.capability) })
      |> list.map(fn(binding) { binding.tool }),
  ])
}

/// Whether a tool call is executed by this server (as opposed to being
/// sent to the client). Replaces the compiled-in `tools.is_server_tool`
/// whitelist.
pub fn is_server_tool(instance: Instance, name: String) -> Bool {
  list.any(instance.server_tools, fn(tool) { tool.definition.name == name })
}

/// Executes a registered server tool. Unknown names and executor errors
/// both become error tool results for the model to react to.
pub fn execute_server_tool(instance: Instance, call: ToolCall) -> ToolResult {
  let outcome = case
    list.find(instance.server_tools, fn(tool) {
      tool.definition.name == call.name
    })
  {
    Ok(tool) -> tool.execute(call.input)
    Error(Nil) -> Error("Unknown tool: " <> call.name)
  }

  case outcome {
    Ok(text) ->
      turn.ToolResult(
        id: call.id,
        name: call.name,
        result: text,
        is_error: False,
      )
    Error(message) ->
      turn.ToolResult(
        id: call.id,
        name: call.name,
        result: message,
        is_error: True,
      )
  }
}

/// The prompt sections contributed by the enabled capabilities, in
/// binding order.
pub fn capability_prompt_sections(
  instance: Instance,
  caps: Capabilities,
) -> List(String) {
  instance.capabilities
  |> list.filter(fn(binding) { capabilities.has(caps, binding.capability) })
  |> list.filter_map(fn(binding) {
    option.to_result(binding.prompt_section, Nil)
  })
}

// ---------------------------------------------------------------------
// Per-request environment
// ---------------------------------------------------------------------

/// The values that vary per request rather than per deployment, supplied
/// by the host alongside the HTTP params. In the OSS shim most of these
/// are constants.
pub type RequestEnv {
  RequestEnv(
    /// Opaque owner of the request; the OSS shim passes a constant.
    user_id: String,
    /// Today's UTC date, pre-formatted for the turn-context block (e.g.
    /// "July 10, 2026").
    current_date: String,
    /// Per-request because it follows the *user*: hosted superusers who
    /// opted in get `FullContent`, everyone else `MetadataOnly`.
    content_policy: ContentPolicy,
    /// Hosted feature-flag gates; `True` in the OSS shim.
    options_enabled: Bool,
    llm_selection_enabled: Bool,
  )
}
