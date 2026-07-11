import atuin_hub/cli_chat/domain/usage.{
  Anthropic, Extracted, Fireworks, OpenAiCompatible, Openrouter, UsageReport,
}
import gleam/option.{None, Some}

fn report(input: Int, output: Int) -> usage.UsageReport {
  UsageReport(
    ..usage.empty_report(),
    input_tokens: Some(input),
    output_tokens: Some(output),
    present: True,
  )
}

pub fn prefers_stream_usage_test() {
  let Extracted(usage: extracted, no_usage_data: no_data) =
    usage.extract(report(10, 5), report(99, 99), report(50, 50), Anthropic)
  assert extracted.input_tokens == 10
  assert extracted.output_tokens == 5
  assert extracted.total_tokens == 15
  assert !no_data
}

pub fn falls_back_to_meta_then_response_test() {
  let Extracted(usage: from_meta, ..) =
    usage.extract(usage.empty_report(), report(7, 3), report(50, 50), Anthropic)
  assert from_meta.input_tokens == 7

  let Extracted(usage: from_response, ..) =
    usage.extract(
      usage.empty_report(),
      usage.empty_report(),
      report(50, 50),
      Anthropic,
    )
  assert from_response.input_tokens == 50
}

pub fn no_sources_flags_missing_usage_test() {
  let Extracted(usage: extracted, no_usage_data: no_data) =
    usage.extract(
      usage.empty_report(),
      usage.empty_report(),
      usage.empty_report(),
      Anthropic,
    )
  assert no_data
  assert extracted == usage.zero()
}

pub fn cache_field_spellings_unify_test() {
  // ReqLLM-normalized spelling
  let normalized =
    UsageReport(
      ..report(100, 10),
      cached_tokens: Some(800),
      cache_creation_tokens: Some(50),
    )
  let Extracted(usage: a, ..) =
    usage.extract(
      normalized,
      usage.empty_report(),
      usage.empty_report(),
      Anthropic,
    )
  assert a.cached_tokens == 800
  assert a.cache_creation_tokens == 50
  assert a.input_tokens == 100
  assert a.total_tokens == 960

  // Raw Anthropic wire spelling from the meta capture
  let wire =
    UsageReport(
      ..report(100, 10),
      cache_read_input_tokens: Some(800),
      cache_creation_input_tokens: Some(50),
    )
  let Extracted(usage: b, ..) =
    usage.extract(wire, usage.empty_report(), usage.empty_report(), Anthropic)
  assert b.cached_tokens == 800
  assert b.cache_creation_tokens == 50
}

pub fn openrouter_inclusive_input_normalizes_test() {
  // OpenAI-style providers report input inclusive of cached tokens; the
  // uncached base is input - cached - cache_writes, clamped at zero.
  let inclusive = UsageReport(..report(1000, 10), cached_tokens: Some(800))
  let Extracted(usage: extracted, ..) =
    usage.extract(
      inclusive,
      usage.empty_report(),
      usage.empty_report(),
      Openrouter,
    )
  assert extracted.input_tokens == 200
  assert extracted.total_tokens == 1010

  let oversubscribed = UsageReport(..report(100, 10), cached_tokens: Some(800))
  let Extracted(usage: clamped, ..) =
    usage.extract(
      oversubscribed,
      usage.empty_report(),
      usage.empty_report(),
      Openrouter,
    )
  assert clamped.input_tokens == 0
}

pub fn fireworks_inclusive_input_normalizes_test() {
  // Values captured from a live dedicated-deployment response: Fireworks
  // reports prompt_tokens inclusive of cached tokens (the response headers
  // showed fireworks-cached-prompt-tokens 2420 of fireworks-prompt-tokens
  // 2421), so the uncached base is the difference.
  let inclusive = UsageReport(..report(2421, 82), cached_tokens: Some(2420))
  let Extracted(usage: extracted, ..) =
    usage.extract(
      inclusive,
      usage.empty_report(),
      usage.empty_report(),
      Fireworks,
    )
  assert extracted.input_tokens == 1
  assert extracted.cached_tokens == 2420
  assert extracted.total_tokens == 2503
}

pub fn openai_compatible_inclusive_input_normalizes_test() {
  // Custom OpenAI-compatible endpoints (Ollama, vLLM, ...) follow OpenAI
  // conventions: prompt_tokens inclusive of any cached tokens.
  let inclusive = UsageReport(..report(1000, 10), cached_tokens: Some(800))
  let Extracted(usage: extracted, ..) =
    usage.extract(
      inclusive,
      usage.empty_report(),
      usage.empty_report(),
      OpenAiCompatible,
    )
  assert extracted.input_tokens == 200
  assert extracted.total_tokens == 1010
}

pub fn explicit_includes_cached_flag_wins_test() {
  // Flag says exclusive even though provider is openrouter
  let exclusive =
    UsageReport(
      ..report(100, 10),
      cached_tokens: Some(800),
      input_includes_cached: Some(False),
    )
  let Extracted(usage: extracted, ..) =
    usage.extract(
      exclusive,
      usage.empty_report(),
      usage.empty_report(),
      Openrouter,
    )
  assert extracted.input_tokens == 100
}

pub fn provider_cost_prefers_meta_and_converts_test() {
  let chosen = UsageReport(..report(10, 5), cost: Some(0.5))
  let meta = UsageReport(..usage.empty_report(), cost: Some(0.000425))
  let Extracted(usage: extracted, ..) =
    usage.extract(chosen, meta, usage.empty_report(), Openrouter)
  assert extracted.provider_cost == Some(425)

  // Without a meta cost, the chosen report's cost applies
  let Extracted(usage: fallback, ..) =
    usage.extract(
      chosen,
      usage.empty_report(),
      usage.empty_report(),
      Openrouter,
    )
  assert fallback.provider_cost == Some(500_000)
}

pub fn byok_upstream_cost_recorded_separately_test() {
  let byok =
    UsageReport(
      ..report(10, 5),
      cost: Some(0.0009),
      is_byok: Some(True),
      upstream_cost: Some(0.018),
    )
  let Extracted(usage: extracted, ..) =
    usage.extract(byok, usage.empty_report(), usage.empty_report(), Openrouter)

  // BYOK: OpenRouter's cost is only the routing fee; the provider bills
  // the upstream inference cost directly, so both are recorded.
  assert extracted.provider_cost == Some(900)
  assert extracted.upstream_cost == Some(18_000)
}

pub fn non_byok_upstream_cost_is_ignored_test() {
  // Non-BYOK responses still carry cost_details, where the upstream cost
  // just mirrors `cost` — recording it would double-count the charge.
  let mirrored =
    UsageReport(
      ..report(10, 5),
      cost: Some(0.018),
      is_byok: Some(False),
      upstream_cost: Some(0.018),
    )
  let Extracted(usage: extracted, ..) =
    usage.extract(
      mirrored,
      usage.empty_report(),
      usage.empty_report(),
      Openrouter,
    )
  assert extracted.provider_cost == Some(18_000)
  assert extracted.upstream_cost == None

  // Same when is_byok is absent entirely (older payloads).
  let unflagged =
    UsageReport(..report(10, 5), cost: Some(0.018), upstream_cost: Some(0.018))
  let Extracted(usage: extracted, ..) =
    usage.extract(
      unflagged,
      usage.empty_report(),
      usage.empty_report(),
      Openrouter,
    )
  assert extracted.upstream_cost == None
}

pub fn extract_partial_test() {
  assert usage.extract_partial(usage.empty_report(), Anthropic) == None

  let assert Some(partial) = usage.extract_partial(report(5, 2), Anthropic)
  assert partial.input_tokens == 5
  assert partial.output_tokens == 2
}

pub fn aggregate_sums_and_keeps_costs_test() {
  let a =
    usage.Usage(
      ..usage.zero(),
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      input_cost: Some(0.1),
      provider_cost: Some(100),
    )
  let b =
    usage.Usage(
      ..usage.zero(),
      input_tokens: 1,
      output_tokens: 2,
      total_tokens: 3,
      provider_cost: Some(50),
    )

  let combined = usage.aggregate(a, b)
  assert combined.input_tokens == 11
  assert combined.output_tokens == 7
  assert combined.total_tokens == 18
  assert combined.input_cost == Some(0.1)
  assert combined.output_cost == None
  assert combined.provider_cost == Some(150)
}
