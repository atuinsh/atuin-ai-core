//// Trace-event context and event types for chat turns. Emission is a
//// host concern — events flow through the `Recorder` port on the
//// `Instance` — and recorders are best-effort by contract, so producing
//// and emitting an `Event` is always safe.

import atuin_ai_core/http/limits.{type ChargeTarget}
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None}

/// Whether trace payloads and usage records may carry user content
/// (message text, tool inputs/results, context-file contents) or only
/// metadata — identifiers, counts, and byte sizes. `MetadataOnly` is the
/// production default; `FullContent` is reserved for users who explicitly
/// opt in to sharing their data. The allowlists live in `trace_payloads`.
pub type ContentPolicy {
  MetadataOnly
  FullContent
}

/// The per-request identifiers every trace event and usage record shares.
/// Built once per request; the Elixir FFI reads this as a tuple, so field
/// order is part of the FFI contract.
pub type TraceContext {
  TraceContext(
    trace_id: String,
    session_id: String,
    user_id: String,
    invocation_id: Option(String),
    client_version: Option(String),
    /// Resolved model alias/ID pair (after defaults), so trace consumers
    /// never see a default-model session as unlabelled.
    model_alias: String,
    model: String,
    charge_info: ChargeTarget,
  )
}

/// One trace event. `payload` is a JSON-shaped Dynamic map (string keys);
/// the identifier fields (session, user) come from the TraceContext at
/// emit time. Field order is part of the FFI contract.
pub type Event {
  Event(
    event_type: String,
    event_order: Int,
    payload: Dynamic,
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    cached_tokens: Option(Int),
    cache_creation_tokens: Option(Int),
    billable_input_tokens: Option(Int),
    billable_output_tokens: Option(Int),
    input_token_mult: Option(Float),
    output_token_mult: Option(Float),
    computed_cost: Option(Int),
    provider_cost: Option(Int),
    duration_ms: Option(Int),
  )
}

/// An event with no token/billing measurements attached.
pub fn event(
  event_type event_type: String,
  event_order event_order: Int,
  payload payload: Dynamic,
) -> Event {
  Event(
    event_type:,
    event_order:,
    payload:,
    input_tokens: None,
    output_tokens: None,
    cached_tokens: None,
    cache_creation_tokens: None,
    billable_input_tokens: None,
    billable_output_tokens: None,
    input_token_mult: None,
    output_token_mult: None,
    computed_cost: None,
    provider_cost: None,
    duration_ms: None,
  )
}
