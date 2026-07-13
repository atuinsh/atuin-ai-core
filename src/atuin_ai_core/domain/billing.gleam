//// Computes billable token counts and cost estimates for LLM usage.
////
//// All cost values are in **micro-dollars** (1_000_000 = $1.00) to avoid
//// floating-point precision issues with fractional cent amounts.
////
//// ## Cache discounting
////
//// Anthropic's prompt caching billing model:
////
//// | Token type | Multiplier | Effective price |
//// |------------|------------|-----------------|
//// | Base input | 1.00×      | Full price      |
//// | Cache write| 1.25×      | 25% surcharge   |
//// | Cache read | 0.10×      | 90% discount    |
////
//// Billable input tokens are computed as:
////
////     input × 1.00 + cache_write × 1.25 + cache_read × 0.10
////
//// `input_tokens` is expected to be the **uncached base** — the tokens
//// billed at full price, excluding cache reads and writes. That's
//// Anthropic's native reporting convention; OpenAI-style providers report
//// input *inclusive* of cached tokens and are normalized to this
//// convention before reaching this module.
////
//// Output tokens are not cache-eligible and pass through unchanged.
////
//// ## Credits
////
//// Billable tokens are the user-facing "credits": the cache-adjusted
//// input (and raw output) scaled by the per-alias credit multipliers from
//// `models`. "max" bills 1:1; cheaper models bill fewer credits per
//// token. Any side that consumed tokens bills at least 1 credit, so no
//// response is free. The dollar-cost estimate (`computed_cost`) is
//// deliberately multiplier-free — it tracks what the request actually
//// cost us, not what we charge for it.

import atuin_ai_core/domain/models.{type Multipliers, type Pricing, Pricing}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

/// Raw provider-reported token counts, normalized to Anthropic's exclusive
/// reporting convention (see module doc).
pub type RawUsage {
  RawUsage(
    input_tokens: Int,
    output_tokens: Int,
    cached_tokens: Int,
    cache_creation_tokens: Int,
  )
}

pub type Computed {
  Computed(
    billable_input_tokens: Int,
    billable_output_tokens: Int,
    computed_cost: Int,
    /// The multipliers in effect when this was computed, persisted on the
    /// record so historical rows stay explainable after rates change.
    input_token_mult: Float,
    output_token_mult: Float,
  )
}

const cache_read_multiplier = 0.1

const cache_write_multiplier = 1.25

/// Fallback pricing when the model is not in models' pricing table
/// (Sonnet-equivalent). Expected for arbitrary OpenRouter models, whose
/// computed cost is comparative only; for Anthropic models the computed
/// cost is the cost of record, so `missing_anthropic_pricing` is flagged
/// for the boundary to surface.
const default_pricing = Pricing(
  input_price_per_mtok: 3_000_000,
  output_price_per_mtok: 15_000_000,
)

pub type CostResult {
  CostResult(computed: Computed, missing_anthropic_pricing: Bool)
}

/// Computes billable tokens and cost from a deployment's catalog: pricing
/// looked up by resolved model ID, credit multipliers by alias.
pub fn compute_for_catalog(
  usage: RawUsage,
  catalog: models.Catalog,
  model_alias model_alias: String,
  model_id model_id: String,
) -> CostResult {
  compute_with(
    usage,
    pricing: catalog.pricing(model_id),
    mults: models.multipliers(catalog, model_alias),
    model_id: model_id,
  )
}

/// Computes billable tokens and cost with an already-resolved price and
/// multipliers (both from the deployment's catalog). `model_id` is only
/// consulted to flag missing Anthropic pricing when `pricing` is `None`.
pub fn compute_with(
  usage: RawUsage,
  pricing pricing: Option(models.ModelCost),
  mults mults: Multipliers,
  model_id model_id: String,
) -> CostResult {
  case pricing {
    Some(models.PerToken(pricing)) ->
      CostResult(
        compute(usage, pricing, mults),
        missing_anthropic_pricing: False,
      )
    // Capacity-billed models have no per-request cost to estimate — an
    // estimate from the default pricing would be fiction in the spend
    // analytics. Credits (billable tokens) still accrue normally.
    Some(models.NoPerRequestCost) ->
      CostResult(
        compute(usage, Pricing(0, 0), mults),
        missing_anthropic_pricing: False,
      )
    None ->
      CostResult(
        compute(usage, default_pricing, mults),
        missing_anthropic_pricing: string.starts_with(model_id, "anthropic:"),
      )
  }
}

pub fn compute(
  usage: RawUsage,
  pricing: Pricing,
  mults: Multipliers,
) -> Computed {
  // Operation order mirrors the original Elixir implementation so the
  // float rounding behavior is bit-identical.
  let cache_adjusted_input =
    float.round(
      int.to_float(usage.input_tokens)
      +. int.to_float(usage.cache_creation_tokens)
      *. cache_write_multiplier
      +. int.to_float(usage.cached_tokens)
      *. cache_read_multiplier,
    )

  // Prices are per million tokens, so the µ$ cost is the product scaled
  // back down, rounded half-away-from-zero like cache_adjusted_input
  // above. Cost is estimated from cache-adjusted tokens *before* the
  // credit multipliers — mults shape what we charge, not what we spent.
  let computed_cost =
    float.round(
      int.to_float(
        cache_adjusted_input
        * pricing.input_price_per_mtok
        + usage.output_tokens
        * pricing.output_price_per_mtok,
      )
      /. 1_000_000.0,
    )

  Computed(
    billable_input_tokens: to_credits(cache_adjusted_input, mults.input),
    billable_output_tokens: to_credits(usage.output_tokens, mults.output),
    computed_cost: computed_cost,
    input_token_mult: mults.input,
    output_token_mult: mults.output,
  )
}

// Tokens × multiplier, rounded, floored at 1 credit: anything that
// consumed tokens bills at least one credit. Zero tokens stay zero so a
// no-output turn isn't charged for output it never produced.
fn to_credits(tokens: Int, mult: Float) -> Int {
  case tokens {
    0 -> 0
    _ -> int.max(1, float.round(int.to_float(tokens) *. mult))
  }
}

pub fn to_microdollars(dollars: Float) -> Int {
  float.round(dollars *. 1_000_000.0)
}

/// For display only — going back to floats reintroduces the precision
/// problems micro-dollars exist to avoid.
pub fn from_microdollars(microdollars: Int) -> Float {
  int.to_float(microdollars) /. 1_000_000.0
}
