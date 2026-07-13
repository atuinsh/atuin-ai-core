//// Model-catalog types and lookups for CLI chat.
////
//// The catalog itself is deployment configuration: the hosted
//// deployment's compiled-in catalog lives in `hosted`, and a self-hosted
//// deployment builds one from its own config. This module owns the types
//// and the alias lookups everything downstream shares — nothing here
//// knows which models any particular deployment serves.

import gleam/list
import gleam/option.{type Option}

/// Per-model pricing in micro-dollars per million tokens: $X/MTok ->
/// X × 1_000_000. The fine granularity matters — sub-dollar-per-MTok
/// models (e.g. DeepSeek at $0.09/MTok -> 90_000) would round to zero
/// at µ$/token resolution.
pub type Pricing {
  Pricing(input_price_per_mtok: Int, output_price_per_mtok: Int)
}

pub type ModelAlias {
  ModelAlias(
    /// User-facing alias (what the client sends on the wire and what analytics
    /// dashboards segment on).
    alias: String,
    /// Friendly name of the model for display in the CLI model selector.
    display_name: String,
    /// Provider-prefixed model ID; we never take a raw provider model ID from
    /// user input — only the catalog's known-safe aliases are accepted.
    model_id: String,
    /// Human-readable description for the CLI help text.
    description: String,
    /// Boolean field determining whether the model should be surfaced to users
    /// in the CLI model selector (note: always shown to users in the :llm_selection
    /// feature flag).
    visible_in_cli: Bool,
    /// Multiplier for token cost for this model, if different from the default
    /// (1.0). This is used to adjust the cost of models that are more expensive
    /// to run than others.
    input_token_mult: Option(Float),
    output_token_mult: Option(Float),
  )
}

/// How a model's usage is priced. Most models bill per token; models
/// served from a dedicated, capacity-billed deployment have no
/// per-request cost — their usage records a computed cost of zero while
/// credits (billable tokens) still accrue against user limits.
pub type ModelCost {
  PerToken(Pricing)
  NoPerRequestCost
}

/// The models a deployment serves. Aliases are the only model identifiers
/// accepted from clients; `default_alias` must name one of them.
pub type Catalog {
  Catalog(
    models: List(ModelAlias),
    default_alias: String,
    /// Cost data by provider model ID, for the recorder's computed costs.
    /// `None` means unpriced — the turn records at the default rate.
    /// Irrelevant under the null recorder.
    pricing: fn(String) -> Option(ModelCost),
  )
}

/// Resolves a user-facing alias to its provider model ID.
pub fn resolve(catalog: Catalog, alias: String) -> Option(String) {
  list.find(catalog.models, fn(entry) { entry.alias == alias })
  |> option.from_result
  |> option.map(fn(entry) { entry.model_id })
}

/// Whether an alias may be selected without the `:llm_selection` flag.
/// Unknown aliases are hidden — the caller decides what non-selection
/// means (the config gate decays them to the default).
pub fn visible_in_cli(catalog: Catalog, alias: String) -> Bool {
  case list.find(catalog.models, fn(entry) { entry.alias == alias }) {
    Ok(entry) -> entry.visible_in_cli
    Error(Nil) -> False
  }
}

/// Credit multipliers applied to billable token counts. Credits are the
/// user-facing billing unit: 1 credit = 1 billable token on the "max"
/// model, and cheaper models bill proportionally fewer credits per token.
pub type Multipliers {
  Multipliers(input: Float, output: Float)
}

/// Multipliers for a resolved alias. Unknown aliases — arbitrary model
/// strings from `:llm_selection` users — bill 1:1 deliberately.
pub fn multipliers(catalog: Catalog, alias: String) -> Multipliers {
  case list.find(catalog.models, fn(entry) { entry.alias == alias }) {
    Ok(entry) ->
      Multipliers(
        input: option.unwrap(entry.input_token_mult, 1.0),
        output: option.unwrap(entry.output_token_mult, 1.0),
      )
    Error(Nil) -> Multipliers(input: 1.0, output: 1.0)
  }
}
