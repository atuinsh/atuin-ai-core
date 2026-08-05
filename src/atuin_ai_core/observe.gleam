//// Operational observability for chat turns: time-to-first-token,
//// throughput, durations, and failure classification, emitted by the
//// driver as plain data.
////
//// This is the operational sibling of the `Recorder` port on the
//// instance: traces and usage records are analytical (what happened, for
//// billing and post-hoc analysis), while observations are operational
//// (how the system is performing right now, for metrics and logs). The
//// contract is the same — fire-and-forget, and an observer must never
//// affect the response.
////
//// Deployments wire one up at composition time:
////
//// ```gleam
//// // Self-hosted: structured log lines via the host's log pipeline.
//// instance.new(catalog, backend)
//// |> instance.with_observer(observe.logging_observer())
////
//// // Hosted: metrics (PromEx) plus log lines, closing over host state.
//// instance.new(catalog, backend)
//// |> instance.with_observer(observe.Observer(fn(observation) {
////   metrics.record(observation)
//// }))
//// ```

import atuin_ai_core/ffi/log
import atuin_ai_core/http/trace.{type TraceContext}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}

/// Where observations go. Fire-and-forget: the driver runs every
/// callback in an unlinked process, so a blocking or crashing observer
/// can never delay or break a turn — and event ordering is not
/// guaranteed in exchange.
pub type Observer {
  Observer(observe: fn(Observation) -> Nil)
}

/// One observation with the request's identifiers attached, so a host
/// can correlate metrics and log lines with traces and usage records
/// without any further context.
pub type Observation {
  Observation(context: TraceContext, event: Event)
}

/// A single observable moment in a turn. Timings are milliseconds;
/// `iteration` is the turn's LLM-call index (0-based).
pub type Event {
  /// An LLM call is starting (one per loop iteration).
  LlmCallStarted(iteration: Int, provider: String, model: String)
  /// The first content (text, reasoning, or tool call) arrived from the
  /// provider. `ttft_ms` is measured from the start of this LLM call.
  LlmFirstToken(iteration: Int, ttft_ms: Int)
  /// The provider stream finished. `tokens_per_second` is output tokens
  /// over generation time (first token to stream end) — absent when the
  /// stream produced no content or no usage data.
  LlmCallCompleted(
    iteration: Int,
    duration_ms: Int,
    ttft_ms: Option(Int),
    output_tokens: Int,
    tokens_per_second: Option(Float),
  )
  /// The LLM call failed. `error_type` is the same classification the
  /// failure records under; `error_detail` is the operator-facing
  /// context (provider message or transport detail), never user content.
  LlmCallFailed(
    iteration: Int,
    error_type: String,
    error_detail: Option(String),
    duration_ms: Int,
  )
  /// A server-executed tool finished.
  ServerToolCompleted(name: String, duration_ms: Int, is_error: Bool)
  /// The turn ended. `outcome` is "success", "cancelled", "paused", or
  /// "failed"; `llm_calls` counts the turn's LLM calls.
  TurnCompleted(outcome: String, duration_ms: Int, llm_calls: Int)
}

/// Observes nothing.
pub fn null_observer() -> Observer {
  Observer(observe: fn(_) { Nil })
}

/// Emits one structured log line per observation through the host's log
/// pipeline (Erlang `logger`). Failures log at error level, tool errors
/// at warning, everything else at info.
pub fn logging_observer() -> Observer {
  Observer(observe: fn(observation) {
    let Observation(context:, event:) = observation
    let prefix =
      "[cli_chat] "
      <> event_name(event)
      <> " session_id="
      <> context.session_id
      <> " trace_id="
      <> context.trace_id
      <> " model="
      <> context.model

    case event {
      LlmCallFailed(iteration:, error_type:, error_detail:, duration_ms:) ->
        log.error(
          prefix
          <> " iteration="
          <> int.to_string(iteration)
          <> " error_type="
          <> error_type
          // Provider-supplied — encoded so it can't forge log lines.
          <> " detail="
          <> log.escape(option_unwrap(error_detail))
          <> " duration_ms="
          <> int.to_string(duration_ms),
        )

      ServerToolCompleted(name:, duration_ms:, is_error: True) ->
        log.warning(
          prefix
          <> " tool="
          <> name
          <> " duration_ms="
          <> int.to_string(duration_ms)
          <> " is_error=true",
        )

      _ -> log.info(prefix <> " " <> event_fields(event))
    }
  })
}

fn event_name(event: Event) -> String {
  case event {
    LlmCallStarted(..) -> "llm_call_started"
    LlmFirstToken(..) -> "llm_first_token"
    LlmCallCompleted(..) -> "llm_call_completed"
    LlmCallFailed(..) -> "llm_call_failed"
    ServerToolCompleted(..) -> "server_tool_completed"
    TurnCompleted(..) -> "turn_completed"
  }
}

fn event_fields(event: Event) -> String {
  case event {
    LlmCallStarted(iteration:, provider:, model:) ->
      "iteration="
      <> int.to_string(iteration)
      <> " provider="
      <> provider
      <> " model="
      <> model

    LlmFirstToken(iteration:, ttft_ms:) ->
      "iteration="
      <> int.to_string(iteration)
      <> " ttft_ms="
      <> int.to_string(ttft_ms)

    LlmCallCompleted(
      iteration:,
      duration_ms:,
      ttft_ms:,
      output_tokens:,
      tokens_per_second:,
    ) ->
      "iteration="
      <> int.to_string(iteration)
      <> " duration_ms="
      <> int.to_string(duration_ms)
      <> " ttft_ms="
      <> option_map_string(ttft_ms, int.to_string)
      <> " output_tokens="
      <> int.to_string(output_tokens)
      <> " tps="
      <> option_map_string(tokens_per_second, fn(tps) {
        // one decimal place is plenty for a log line
        float.to_string(int.to_float(float.round(tps *. 10.0)) /. 10.0)
      })

    LlmCallFailed(..) -> ""

    ServerToolCompleted(name:, duration_ms:, is_error: _) ->
      "tool=" <> name <> " duration_ms=" <> int.to_string(duration_ms)

    TurnCompleted(outcome:, duration_ms:, llm_calls:) ->
      "outcome="
      <> outcome
      <> " duration_ms="
      <> int.to_string(duration_ms)
      <> " llm_calls="
      <> int.to_string(llm_calls)
  }
}

fn option_unwrap(value: Option(String)) -> String {
  case value {
    Some(value) -> value
    None -> "(none)"
  }
}

fn option_map_string(value: Option(a), render: fn(a) -> String) -> String {
  case value {
    Some(value) -> render(value)
    None -> "(none)"
  }
}
