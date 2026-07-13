//// A synthetic catalog shaped like a real deployment's — a visible
//// default with credit multipliers, a visible premium alias without, a
//// hidden experimental alias — for tests that need realistic alias
//// resolution without depending on any deployment's data.

import atuin_ai_core/domain/models.{Catalog, ModelAlias}
import gleam/option.{None, Some}

pub fn catalog() -> models.Catalog {
  Catalog(
    models: [
      ModelAlias(
        alias: "fast",
        display_name: "Fast",
        model_id: "fireworks:fast-model",
        description: "The default model",
        visible_in_cli: True,
        input_token_mult: Some(0.5),
        output_token_mult: Some(0.25),
      ),
      ModelAlias(
        alias: "max",
        display_name: "Max",
        model_id: "openrouter:provider/max-model",
        description: "The premium model",
        visible_in_cli: True,
        input_token_mult: None,
        output_token_mult: None,
      ),
      ModelAlias(
        alias: "experimental",
        display_name: "Experimental",
        model_id: "openrouter:provider/experimental-model",
        description: "Hidden from the CLI model list",
        visible_in_cli: False,
        input_token_mult: Some(0.5),
        output_token_mult: Some(0.25),
      ),
    ],
    default_alias: "fast",
    pricing: fn(_) { None },
  )
}
