//// Trace-event payload construction for chat turns.
////
//// Payload shapes are the on-disk contract for the admin trace UI — and
//// the allowlist here is the privacy contract. Under `MetadataOnly` (the
//// production default) payloads carry identifiers, counts, and byte
//// sizes, never user content: no message text, tool inputs or results,
//// context-file contents or paths, working directories, or any other
//// user-authored string. `FullContent` — reserved for the future opt-in
//// data-sharing program — adds the content fields on top.
////
//// `trace_payloads_test` asserts the exact key set each builder emits
//// under each policy; adding a field means deliberately allowlisting it
//// there. When in doubt a field is content, not metadata.

import atuin_ai_core/domain/capabilities
import atuin_ai_core/domain/config.{type Config}
import atuin_ai_core/domain/prompt
import atuin_ai_core/domain/tools.{type ToolDefinition}
import atuin_ai_core/domain/usage.{type Usage}
import atuin_ai_core/engine/loop
import atuin_ai_core/engine/turn
import atuin_ai_core/ffi/json as json_ffi
import atuin_ai_core/http/request
import atuin_ai_core/http/trace.{type ContentPolicy, FullContent, MetadataOnly}
import atuin_ai_core/llm/openai_compat
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/string

/// Payload for the `client_request` event: what the client sent, after
/// server-side resolution (capabilities in canonical wire form, model
/// fields resolved past defaults).
pub fn client_request(
  policy policy: ContentPolicy,
  messages messages: List(request.Message),
  config config: Config,
  context context: prompt.PromptContext,
  invocation_id invocation_id: Option(String),
  client_version client_version: Option(String),
  model_alias model_alias: String,
  model model: String,
) -> Dynamic {
  let metadata = [
    #(dynamic.string("message_count"), dynamic.int(list.length(messages))),
    #(dynamic.string("messages_bytes"), dynamic.int(messages_bytes(messages))),
    #(
      dynamic.string("capabilities"),
      config.capabilities
        |> capabilities.to_list
        |> list.map(dynamic.string)
        |> dynamic.list,
    ),
    #(
      dynamic.string("config"),
      config_to_dynamic(policy, config, model_alias, model),
    ),
    #(dynamic.string("context"), context_to_dynamic(policy, context)),
    #(dynamic.string("invocation_id"), optional_text(invocation_id)),
    #(dynamic.string("client_version"), optional_text(client_version)),
  ]

  dynamic.properties(case policy {
    MetadataOnly -> metadata
    FullContent -> [
      #(
        dynamic.string("messages"),
        messages |> list.map(request.to_dynamic) |> dynamic.list,
      ),
      ..metadata
    ]
  })
}

fn config_to_dynamic(
  policy: ContentPolicy,
  config: Config,
  model_alias: String,
  model: String,
) -> Dynamic {
  let metadata = [
    #(
      dynamic.string("run_preference"),
      dynamic.string(run_preference_string(config.run_preference)),
    ),
    #(dynamic.string("model_alias"), dynamic.string(model_alias)),
    #(dynamic.string("model"), dynamic.string(model)),
    #(dynamic.string("prompt_fn"), optional_text(config.prompt_fn)),
    #(dynamic.string("skill_count"), dynamic.int(list.length(config.skills))),
    #(
      dynamic.string("skills_bytes"),
      dynamic.int(measure(skills_to_dynamic(config.skills))),
    ),
    #(
      dynamic.string("skills_overflow_bytes"),
      dynamic.int(optional_bytes(config.skills_overflow)),
    ),
    #(
      dynamic.string("user_context_count"),
      dynamic.int(list.length(config.user_contexts)),
    ),
    #(
      dynamic.string("user_contexts_bytes"),
      dynamic.int(measure(user_contexts_to_dynamic(config.user_contexts))),
    ),
  ]

  dynamic.properties(case policy {
    MetadataOnly -> metadata
    FullContent ->
      list.append(metadata, [
        #(dynamic.string("skills"), skills_to_dynamic(config.skills)),
        #(
          dynamic.string("skills_overflow"),
          optional_text(config.skills_overflow),
        ),
        #(
          dynamic.string("user_contexts"),
          user_contexts_to_dynamic(config.user_contexts),
        ),
      ])
  })
}

// Everything here is client-machine environment; os/distro/shell/language
// are safe categorical values, while pwd and last_command are user content
// (paths and shell history can carry anything) and are FullContent-only.
fn context_to_dynamic(
  policy: ContentPolicy,
  context: prompt.PromptContext,
) -> Dynamic {
  let metadata = [
    #(dynamic.string("os"), optional_text(context.os)),
    #(dynamic.string("distro"), optional_text(context.distro)),
    #(dynamic.string("shell"), optional_text(context.shell)),
    #(
      dynamic.string("preferred_language"),
      optional_text(context.preferred_language),
    ),
  ]

  dynamic.properties(case policy {
    MetadataOnly -> metadata
    FullContent ->
      list.append(metadata, [
        #(dynamic.string("pwd"), optional_text(context.pwd)),
        #(dynamic.string("last_command"), optional_text(context.last_command)),
      ])
  })
}

/// Payload for one `llm_request` event: the prompt actually assembled for
/// this iteration. The size fields exist so prompt growth (system prompt,
/// tool block, conversation) stays observable over time without the text.
pub fn llm_request(
  policy policy: ContentPolicy,
  iteration iteration: Int,
  model model: String,
  messages messages: List(request.Message),
  system system: Option(String),
  turn_context turn_context: Option(String),
  tools tools: List(ToolDefinition),
) -> Dynamic {
  let metadata = [
    #(dynamic.string("iteration"), dynamic.int(iteration)),
    #(dynamic.string("model"), dynamic.string(model)),
    #(dynamic.string("message_count"), dynamic.int(list.length(messages))),
    #(dynamic.string("messages_bytes"), dynamic.int(messages_bytes(messages))),
    #(
      dynamic.string("system_prompt_bytes"),
      dynamic.int(optional_bytes(system)),
    ),
    #(
      dynamic.string("turn_context_bytes"),
      dynamic.int(optional_bytes(turn_context)),
    ),
    #(dynamic.string("tool_count"), dynamic.int(list.length(tools))),
    #(dynamic.string("tools_bytes"), dynamic.int(tools_bytes(tools))),
    #(
      dynamic.string("tool_names"),
      tools |> list.map(fn(tool) { dynamic.string(tool.name) }) |> dynamic.list,
    ),
  ]

  dynamic.properties(case policy {
    MetadataOnly -> metadata
    FullContent ->
      list.append(metadata, [
        #(
          dynamic.string("messages"),
          messages
            |> list.take(20)
            |> list.map(request.to_dynamic)
            |> dynamic.list,
        ),
        #(dynamic.string("system_prompt"), optional_text(system)),
        #(dynamic.string("turn_context"), optional_text(turn_context)),
        #(
          dynamic.string("tools"),
          tools
            |> list.map(fn(tool) {
              dynamic.properties([
                #(dynamic.string("name"), dynamic.string(tool.name)),
                #(
                  dynamic.string("description"),
                  dynamic.string(tool.description),
                ),
              ])
            })
            |> dynamic.list,
        ),
      ])
  })
}

/// Payload for one `llm_response` event. Tool-call *names* are metadata —
/// they come from the server's own tool whitelist — but inputs are model
/// output and FullContent-only.
pub fn llm_response(
  policy policy: ContentPolicy,
  iteration iteration: Int,
  text text: String,
  tool_calls tool_calls: List(turn.ToolCall),
) -> Dynamic {
  let metadata = [
    #(dynamic.string("iteration"), dynamic.int(iteration)),
    #(dynamic.string("text_bytes"), dynamic.int(string.byte_size(text))),
    #(dynamic.string("tool_call_count"), dynamic.int(list.length(tool_calls))),
    #(
      dynamic.string("tool_call_names"),
      tool_calls
        |> list.map(fn(call) { dynamic.string(call.name) })
        |> dynamic.list,
    ),
  ]

  dynamic.properties(case policy {
    MetadataOnly -> metadata
    FullContent ->
      list.append(metadata, [
        #(dynamic.string("text"), dynamic.string(text)),
        #(
          dynamic.string("tool_calls"),
          tool_calls |> list.map(tool_call_to_dynamic) |> dynamic.list,
        ),
      ])
  })
}

/// Payload for one `tool_execution` event.
pub fn tool_execution(
  policy policy: ContentPolicy,
  result result: turn.ToolResult,
  input input: Dynamic,
) -> Dynamic {
  let metadata = [
    #(dynamic.string("tool_name"), dynamic.string(result.name)),
    #(dynamic.string("tool_use_id"), dynamic.string(result.id)),
    #(dynamic.string("input_bytes"), dynamic.int(measure(input))),
    #(
      dynamic.string("result_bytes"),
      dynamic.int(string.byte_size(result.result)),
    ),
    #(dynamic.string("is_error"), dynamic.bool(result.is_error)),
  ]

  dynamic.properties(case policy {
    MetadataOnly -> metadata
    FullContent ->
      list.append(metadata, [
        #(dynamic.string("input"), input),
        #(dynamic.string("result"), dynamic.string(result.result)),
      ])
  })
}

/// Payload for the `session_complete` / `request_complete` event. Entirely
/// aggregate except the session-summary *notes*, which are model-written
/// free text (they can paraphrase the conversation) and FullContent-only.
pub fn completion(
  policy policy: ContentPolicy,
  turn_usage turn_usage: Usage,
  summary summary: Option(turn.SessionSummary),
  responses responses: loop.Responses,
  cancelled cancelled: Bool,
) -> Dynamic {
  let summary_entries = case summary {
    option.Some(summary) -> [
      #(dynamic.string("session_summary"), summary_to_dynamic(policy, summary)),
    ]
    option.None -> []
  }

  dynamic.properties([
    #(dynamic.string("usage"), usage_to_dynamic(turn_usage)),
    #(dynamic.string("cancelled"), dynamic.bool(cancelled)),
    #(
      dynamic.string("ai_response_count"),
      dynamic.properties([
        #(dynamic.string("text"), dynamic.int(list.length(responses.text))),
        #(
          dynamic.string("tool_calls"),
          dynamic.int(list.length(responses.tool_calls)),
        ),
      ]),
    ),
    ..summary_entries
  ])
}

fn summary_to_dynamic(
  policy: ContentPolicy,
  summary: turn.SessionSummary,
) -> Dynamic {
  let metadata = [
    #(dynamic.string("confidence"), optional_text(summary.confidence)),
    #(dynamic.string("danger"), optional_text(summary.danger)),
    #(dynamic.string("turn_count"), dynamic.int(summary.turn_count)),
  ]

  dynamic.properties(case policy {
    MetadataOnly -> metadata
    FullContent ->
      list.append(metadata, [
        #(
          dynamic.string("confidence_notes"),
          optional_text(summary.confidence_notes),
        ),
        #(dynamic.string("danger_notes"), optional_text(summary.danger_notes)),
      ])
  })
}

fn usage_to_dynamic(turn_usage: Usage) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("input_tokens"), dynamic.int(turn_usage.input_tokens)),
    #(dynamic.string("output_tokens"), dynamic.int(turn_usage.output_tokens)),
    #(dynamic.string("total_tokens"), dynamic.int(turn_usage.total_tokens)),
    #(dynamic.string("cached_tokens"), dynamic.int(turn_usage.cached_tokens)),
    #(
      dynamic.string("cache_creation_tokens"),
      dynamic.int(turn_usage.cache_creation_tokens),
    ),
    #(
      dynamic.string("provider_cost"),
      turn_usage.provider_cost
        |> option.map(dynamic.int)
        |> option.unwrap(dynamic.nil()),
    ),
    #(
      dynamic.string("upstream_cost"),
      turn_usage.upstream_cost
        |> option.map(dynamic.int)
        |> option.unwrap(dynamic.nil()),
    ),
  ])
}

fn tool_call_to_dynamic(call: turn.ToolCall) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("id"), dynamic.string(call.id)),
    #(dynamic.string("name"), dynamic.string(call.name)),
    #(dynamic.string("input"), call.input),
  ])
}

fn skills_to_dynamic(skills: List(config.SkillSummary)) -> Dynamic {
  skills
  |> list.map(fn(skill) {
    dynamic.properties([
      #(dynamic.string("name"), dynamic.string(skill.name)),
      #(dynamic.string("description"), dynamic.string(skill.description)),
    ])
  })
  |> dynamic.list
}

fn user_contexts_to_dynamic(contexts: List(config.UserContext)) -> Dynamic {
  contexts
  |> list.map(fn(user_context) {
    dynamic.properties([
      #(dynamic.string("file_path"), dynamic.string(user_context.file_path)),
      #(dynamic.string("content"), dynamic.string(user_context.content)),
    ])
  })
  |> dynamic.list
}

fn run_preference_string(preference: config.RunPreference) -> String {
  case preference {
    config.Auto -> "auto"
    config.Suggest -> "suggest"
    config.Run -> "run"
  }
}

// ---------------------------------------------------------------------
// Size measurement. Sizes are of the trace wire form (JSON), which for
// tools matches the LLM request body exactly and for messages closely
// approximates it — good enough to watch prompt growth over time.
// ---------------------------------------------------------------------

fn messages_bytes(messages: List(request.Message)) -> Int {
  messages
  |> list.map(request.to_dynamic)
  |> dynamic.list
  |> measure
}

fn tools_bytes(tools: List(ToolDefinition)) -> Int {
  tools
  |> list.map(openai_compat.encode_tool)
  |> json.preprocessed_array
  |> json.to_string
  |> string.byte_size
}

fn measure(value: Dynamic) -> Int {
  value |> json_ffi.encode |> string.byte_size
}

fn optional_bytes(value: Option(String)) -> Int {
  value |> option.map(string.byte_size) |> option.unwrap(0)
}

fn optional_text(value: Option(String)) -> Dynamic {
  value |> option.map(dynamic.string) |> option.unwrap(dynamic.nil())
}
