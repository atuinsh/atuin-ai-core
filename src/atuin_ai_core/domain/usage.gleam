//// Token-usage normalization and aggregation for the chat loop.
////
//// In the normalized `Usage`, `input_tokens` is always the *uncached
//// base* — the tokens billed at full price — with cache reads and writes
//// reported separately. `billing.compute` relies on this convention.
//// `total_tokens` is everything the provider processed (base + cache reads
//// + cache writes + output), matching the OpenAI/OpenRouter meaning of
//// "total".

import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}

pub type Provider {
  Anthropic
  Openrouter
  Fireworks
  /// A custom OpenAI-compatible endpoint (Ollama, vLLM, ...): OpenAI
  /// usage conventions, no provider-cost reporting.
  OpenAiCompatible
  OtherProvider
}

/// One provider-reported usage payload, decoded leniently at the boundary.
/// Cache fields arrive under two spellings depending on the source:
/// normalized (cached_tokens, cache_creation_tokens) in stream usage, but
/// the meta capture can carry the raw Anthropic wire names
/// (cache_read_input_tokens, cache_creation_input_tokens).
pub type UsageReport {
  UsageReport(
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    cached_tokens: Option(Int),
    cache_read_input_tokens: Option(Int),
    cache_creation_tokens: Option(Int),
    cache_creation_input_tokens: Option(Int),
    input_includes_cached: Option(Bool),
    input_cost: Option(Float),
    output_cost: Option(Float),
    total_cost: Option(Float),
    /// Provider-reported exact charge in dollars (OpenRouter's meta cost).
    /// On BYOK-routed requests this is only OpenRouter's routing fee.
    cost: Option(Float),
    /// True when OpenRouter routed the request through our own provider
    /// key (the provider then bills us directly for inference).
    is_byok: Option(Bool),
    /// OpenRouter's `cost_details.upstream_inference_cost` in dollars.
    /// Present on non-BYOK responses too, where it merely mirrors `cost` —
    /// it only represents a separate (provider-billed) charge when
    /// `is_byok` is true.
    upstream_cost: Option(Float),
    /// True when the source map existed and was non-empty.
    present: Bool,
  )
}

pub fn empty_report() -> UsageReport {
  UsageReport(
    input_tokens: None,
    output_tokens: None,
    cached_tokens: None,
    cache_read_input_tokens: None,
    cache_creation_tokens: None,
    cache_creation_input_tokens: None,
    input_includes_cached: None,
    input_cost: None,
    output_cost: None,
    total_cost: None,
    cost: None,
    is_byok: None,
    upstream_cost: None,
    present: False,
  )
}

/// The normalized usage map recorded for analytics and billing, and sent
/// to the client in the done event.
pub type Usage {
  Usage(
    input_tokens: Int,
    output_tokens: Int,
    total_tokens: Int,
    cached_tokens: Int,
    cache_creation_tokens: Int,
    input_cost: Option(Float),
    output_cost: Option(Float),
    total_cost: Option(Float),
    /// OpenRouter-reported exact cost in micro-dollars: what was deducted
    /// from our OpenRouter credits (the routing fee when BYOK-routed).
    provider_cost: Option(Int),
    /// Inference cost in micro-dollars billed directly by the upstream
    /// provider on BYOK-routed requests. None on non-BYOK requests, where
    /// the full charge is already in `provider_cost`.
    upstream_cost: Option(Int),
  )
}

pub fn zero() -> Usage {
  Usage(
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    cached_tokens: 0,
    cache_creation_tokens: 0,
    input_cost: None,
    output_cost: None,
    total_cost: None,
    provider_cost: None,
    upstream_cost: None,
  )
}

/// Extraction result: the usage plus a flag telling the boundary to log
/// that the provider reported nothing (such a request gets recorded as
/// free, which should be surfaced).
pub type Extracted {
  Extracted(usage: Usage, no_usage_data: Bool)
}

/// Builds the normalized usage from the candidate sources. Token counts
/// come from the first non-empty source. Stream usage is preferred: it's
/// fully normalized and carries the input_includes_cached flag. The meta
/// capture exists for OpenRouter's provider-reported cost, which only
/// arrives in a late meta chunk; it doubles as a token fallback.
pub fn extract(
  stream_usage: UsageReport,
  meta_usage: UsageReport,
  response_usage: UsageReport,
  provider: Provider,
) -> Extracted {
  let report = first_present([stream_usage, meta_usage, response_usage])

  let output = option.unwrap(report.output_tokens, 0)

  let cached_tokens =
    report.cached_tokens
    |> option.or(report.cache_read_input_tokens)
    |> option.unwrap(0)

  let cache_creation_tokens =
    report.cache_creation_tokens
    |> option.or(report.cache_creation_input_tokens)
    |> option.unwrap(0)

  // Normalize input to the uncached base. Anthropic reports it that way
  // natively; OpenAI-style providers (OpenRouter, Fireworks, custom
  // OpenAI-compatible endpoints) report input *inclusive* of cached
  // tokens. Stream usage states which convention applies via
  // input_includes_cached; sources without the flag fall back on the
  // provider.
  let includes_cached = case report.input_includes_cached {
    Some(flag) -> flag
    None ->
      provider == Openrouter
      || provider == Fireworks
      || provider == OpenAiCompatible
  }

  let input = case includes_cached {
    True ->
      int.max(
        option.unwrap(report.input_tokens, 0)
          - cached_tokens
          - cache_creation_tokens,
        0,
      )
    False -> option.unwrap(report.input_tokens, 0)
  }

  Extracted(
    usage: Usage(
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + cached_tokens + cache_creation_tokens + output,
      cached_tokens: cached_tokens,
      cache_creation_tokens: cache_creation_tokens,
      input_cost: report.input_cost,
      output_cost: report.output_cost,
      total_cost: report.total_cost,
      provider_cost: extract_provider_cost(meta_usage, report),
      upstream_cost: extract_upstream_cost(meta_usage, report),
    ),
    no_usage_data: !report.present,
  )
}

fn first_present(reports: List(UsageReport)) -> UsageReport {
  case reports {
    [] -> empty_report()
    [report, ..rest] ->
      case report.present {
        True -> report
        False -> first_present(rest)
      }
  }
}

// OpenRouter reports its exact charge as a dollar amount, but only in the
// late meta chunk - check there first, then the chosen usage report.
// Stored as micro-dollars.
fn extract_provider_cost(
  meta_usage: UsageReport,
  chosen: UsageReport,
) -> Option(Int) {
  case option.or(meta_usage.cost, chosen.cost) {
    Some(dollars) -> Some(to_microdollars(dollars))
    None -> None
  }
}

// The upstream inference cost only names a real, separate charge (the
// provider billing our own key directly) when the same report says
// is_byok — on non-BYOK reports it just mirrors `cost`, and counting it
// would double the recorded spend.
fn extract_upstream_cost(
  meta_usage: UsageReport,
  chosen: UsageReport,
) -> Option(Int) {
  option.or(byok_upstream_cost(meta_usage), byok_upstream_cost(chosen))
}

fn byok_upstream_cost(report: UsageReport) -> Option(Int) {
  case report.is_byok, report.upstream_cost {
    Some(True), Some(dollars) -> Some(to_microdollars(dollars))
    _, _ -> None
  }
}

fn to_microdollars(dollars: Float) -> Int {
  float.round(dollars *. 1_000_000.0)
}

/// Normalizes partial usage captured before a stream died. The caller
/// treats `None` as zero consumption for the failing call.
pub fn extract_partial(
  meta_usage: UsageReport,
  provider: Provider,
) -> Option(Usage) {
  case meta_usage.present {
    True -> {
      let Extracted(usage:, no_usage_data: _) =
        extract(empty_report(), meta_usage, empty_report(), provider)
      Some(usage)
    }
    False -> None
  }
}

pub fn aggregate(current: Usage, new: Usage) -> Usage {
  Usage(
    input_tokens: current.input_tokens + new.input_tokens,
    output_tokens: current.output_tokens + new.output_tokens,
    total_tokens: current.total_tokens + new.total_tokens,
    cached_tokens: current.cached_tokens + new.cached_tokens,
    cache_creation_tokens: current.cache_creation_tokens
      + new.cache_creation_tokens,
    input_cost: sum_cost(current.input_cost, new.input_cost),
    output_cost: sum_cost(current.output_cost, new.output_cost),
    total_cost: sum_cost(current.total_cost, new.total_cost),
    provider_cost: sum_int_cost(current.provider_cost, new.provider_cost),
    upstream_cost: sum_int_cost(current.upstream_cost, new.upstream_cost),
  )
}

// A cost present on either side survives aggregation; two absent costs
// stay absent (distinct from zero, which means "provider said free").
fn sum_cost(a: Option(Float), b: Option(Float)) -> Option(Float) {
  case a, b {
    Some(a), Some(b) -> Some(a +. b)
    Some(a), None -> Some(a)
    None, Some(b) -> Some(b)
    None, None -> None
  }
}

fn sum_int_cost(a: Option(Int), b: Option(Int)) -> Option(Int) {
  case a, b {
    Some(a), Some(b) -> Some(a + b)
    Some(a), None -> Some(a)
    None, Some(b) -> Some(b)
    None, None -> None
  }
}
