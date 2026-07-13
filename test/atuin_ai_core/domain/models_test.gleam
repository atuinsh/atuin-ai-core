import atuin_ai_core/domain/models.{Catalog, ModelAlias, Multipliers}
import gleam/option.{None, Some}

// A synthetic catalog: the lookups are pure functions of whatever catalog
// a deployment supplies. The hosted deployment's actual catalog data is
// guarded in hosted_test.
fn catalog() -> models.Catalog {
  Catalog(
    models: [
      ModelAlias(
        alias: "quick",
        display_name: "Quick",
        model_id: "prov:quick-model",
        description: "",
        visible_in_cli: True,
        input_token_mult: Some(0.5),
        output_token_mult: Some(0.25),
      ),
      ModelAlias(
        alias: "hidden",
        display_name: "Hidden",
        model_id: "prov:hidden-model",
        description: "",
        visible_in_cli: False,
        input_token_mult: None,
        output_token_mult: None,
      ),
    ],
    default_alias: "quick",
    pricing: fn(_) { None },
  )
}

pub fn resolve_known_alias_test() {
  assert models.resolve(catalog(), "quick") == Some("prov:quick-model")
  assert models.resolve(catalog(), "hidden") == Some("prov:hidden-model")
}

pub fn resolve_unknown_alias_test() {
  // Provider IDs are not aliases; only catalog aliases resolve.
  assert models.resolve(catalog(), "prov:quick-model") == None
  assert models.resolve(catalog(), "") == None
}

pub fn visible_in_cli_test() {
  assert models.visible_in_cli(catalog(), "quick")
  assert !models.visible_in_cli(catalog(), "hidden")
  assert !models.visible_in_cli(catalog(), "unknown")
}

pub fn multipliers_for_known_alias_test() {
  assert models.multipliers(catalog(), "quick")
    == Multipliers(input: 0.5, output: 0.25)
}

pub fn multipliers_default_to_one_test() {
  // Absent multipliers mean 1:1, and unknown aliases (arbitrary
  // :llm_selection models) also bill 1:1 deliberately.
  assert models.multipliers(catalog(), "hidden")
    == Multipliers(input: 1.0, output: 1.0)
  assert models.multipliers(catalog(), "openai/gpt-4o")
    == Multipliers(input: 1.0, output: 1.0)
}
