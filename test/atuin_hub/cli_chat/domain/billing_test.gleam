import atuin_hub/cli_chat/domain/billing.{type RawUsage, Computed, RawUsage}
import atuin_hub/cli_chat/domain/models.{Multipliers, Pricing}
import gleam/option.{None, Some}

const sonnet = Pricing(
  input_price_per_mtok: 3_000_000,
  output_price_per_mtok: 15_000_000,
)

const opus = Pricing(
  input_price_per_mtok: 5_000_000,
  output_price_per_mtok: 25_000_000,
)

// $0.09/MTok in, $0.18/MTok out — exercises pricing below $1/MTok, which
// only works because prices are stored per million tokens.
const deepseek_flash = Pricing(
  input_price_per_mtok: 90_000,
  output_price_per_mtok: 180_000,
)

const one_to_one = Multipliers(input: 1.0, output: 1.0)

// The "fast" alias's credit multipliers at the time of writing.
const fast_mults = Multipliers(input: 0.028, output: 0.011)

fn usage(
  input input: Int,
  output output: Int,
  cached cached: Int,
  written written: Int,
) -> RawUsage {
  RawUsage(
    input_tokens: input,
    output_tokens: output,
    cached_tokens: cached,
    cache_creation_tokens: written,
  )
}

pub fn base_case_no_cache_tokens_test() {
  let result = billing.compute(usage(1000, 500, 0, 0), sonnet, one_to_one)
  assert result
    == Computed(
      billable_input_tokens: 1000,
      billable_output_tokens: 500,
      computed_cost: 10_500,
      input_token_mult: 1.0,
      output_token_mult: 1.0,
    )
}

pub fn cache_read_discount_test() {
  // billable = 200 × 1.0 + 0 × 1.25 + 800 × 0.10 = 280
  let result = billing.compute(usage(200, 200, 800, 0), sonnet, one_to_one)
  assert result.billable_input_tokens == 280
  assert result.billable_output_tokens == 200
}

pub fn cache_write_surcharge_test() {
  // billable = 1000 × 1.0 + 4000 × 1.25 + 0 × 0.10 = 6000
  let result = billing.compute(usage(1000, 500, 0, 4000), sonnet, one_to_one)
  assert result.billable_input_tokens == 6000
}

pub fn cache_read_and_write_test() {
  // billable = 2000 × 1.0 + 5000 × 1.25 + 3000 × 0.10 = 8550
  let result =
    billing.compute(usage(2000, 1000, 3000, 5000), sonnet, one_to_one)
  assert result.billable_input_tokens == 8550
  assert result.billable_output_tokens == 1000
}

pub fn mostly_cached_request_bills_uncached_remainder_test() {
  // billable = 145 + 154 × 1.25 + 5196 × 0.10 = 857.1 → 857
  // cost = 857 × 5 + 120 × 25 = 7285
  let result = billing.compute(usage(145, 120, 5196, 154), opus, one_to_one)
  assert result.billable_input_tokens == 857
  assert result.computed_cost == 7285
}

pub fn sub_dollar_per_mtok_pricing_test() {
  // cost = (1000 × 90_000 + 500 × 180_000) / 1_000_000 = 180 µ$
  let result =
    billing.compute(usage(1000, 500, 0, 0), deepseek_flash, one_to_one)
  assert result.computed_cost == 180

  // Tiny requests round to the nearest µ$: 3 × 90_000 / 1e6 = 0.27 → 0
  let tiny = billing.compute(usage(3, 0, 0, 0), deepseek_flash, one_to_one)
  assert tiny.computed_cost == 0
}

pub fn rounds_half_away_from_zero_test() {
  // billable = 0 + 0 + 5 × 0.10 = 0.5 → 1 (Erlang round semantics)
  let result = billing.compute(usage(0, 0, 5, 0), sonnet, one_to_one)
  assert result.billable_input_tokens == 1
}

pub fn credit_multipliers_scale_billable_tokens_test() {
  // input credits = round(1000 × 0.028) = 28
  // output credits = round(500 × 0.011) = 5.5 → 6
  let result =
    billing.compute(usage(1000, 500, 0, 0), deepseek_flash, fast_mults)
  assert result.billable_input_tokens == 28
  assert result.billable_output_tokens == 6
  assert result.input_token_mult == 0.028
  assert result.output_token_mult == 0.011
}

pub fn credit_multipliers_apply_after_cache_adjustment_test() {
  // cache-adjusted = 200 + 0 + 800 × 0.10 = 280; credits = round(280 × 0.028) = 8
  let result =
    billing.compute(usage(200, 200, 800, 0), deepseek_flash, fast_mults)
  assert result.billable_input_tokens == 8
}

pub fn credit_multipliers_do_not_affect_computed_cost_test() {
  let with_mults =
    billing.compute(usage(1000, 500, 0, 0), deepseek_flash, fast_mults)
  let without =
    billing.compute(usage(1000, 500, 0, 0), deepseek_flash, one_to_one)
  assert with_mults.computed_cost == without.computed_cost
}

pub fn tokens_consumed_bill_at_least_one_credit_test() {
  // 3 × 0.028 = 0.084 → floors at 1, not 0; 1 × 0.011 likewise
  let result = billing.compute(usage(3, 1, 0, 0), deepseek_flash, fast_mults)
  assert result.billable_input_tokens == 1
  assert result.billable_output_tokens == 1
}

pub fn zero_tokens_bill_zero_credits_test() {
  // The 1-credit floor only applies to sides that consumed tokens.
  let result = billing.compute(usage(3, 0, 0, 0), deepseek_flash, fast_mults)
  assert result.billable_output_tokens == 0
}

pub fn compute_with_records_the_multipliers_in_effect_test() {
  let result =
    billing.compute_with(
      usage(1000, 500, 0, 0),
      pricing: Some(models.PerToken(deepseek_flash)),
      mults: fast_mults,
      model_id: "openrouter:deepseek/deepseek-v4-flash",
    )
  assert result.computed.input_token_mult == 0.028
  assert result.computed.output_token_mult == 0.011
  assert result.missing_anthropic_pricing == False
}

pub fn compute_with_no_pricing_uses_default_rate_test() {
  // Unpriced models estimate at the default (Sonnet) rate. That's fine
  // for arbitrary :llm_selection models but a data bug for Anthropic
  // models, where the computed cost is the cost of record — flagged so
  // the boundary can surface it.
  let result =
    billing.compute_with(
      usage(1000, 0, 0, 0),
      pricing: None,
      mults: one_to_one,
      model_id: "openrouter:openai/gpt-4o",
    )
  assert result.computed.computed_cost
    == billing.compute(usage(1000, 0, 0, 0), sonnet, one_to_one).computed_cost
  assert result.missing_anthropic_pricing == False

  let anthropic =
    billing.compute_with(
      usage(1000, 0, 0, 0),
      pricing: None,
      mults: one_to_one,
      model_id: "anthropic:claude-opus-4-6",
    )
  assert anthropic.missing_anthropic_pricing == True
}

pub fn compute_with_no_per_request_cost_test() {
  // Capacity-billed deployments have no cost to estimate — but credits
  // still accrue.
  let result =
    billing.compute_with(
      usage(1000, 500, 0, 0),
      pricing: Some(models.NoPerRequestCost),
      mults: one_to_one,
      model_id: "fireworks:accounts/fireworks/models/llama-v3p1-70b-instruct",
    )
  assert result.computed.computed_cost == 0
  assert result.computed.billable_input_tokens == 1000
  assert result.computed.billable_output_tokens == 500
  assert result.missing_anthropic_pricing == False
}

pub fn to_microdollars_test() {
  assert billing.to_microdollars(1.0) == 1_000_000
  assert billing.to_microdollars(0.000425) == 425
  assert billing.to_microdollars(0.01) == 10_000
  assert billing.to_microdollars(0.0) == 0
}

pub fn from_microdollars_test() {
  assert billing.from_microdollars(1_000_000) == 1.0
  assert billing.from_microdollars(0) == 0.0
}
