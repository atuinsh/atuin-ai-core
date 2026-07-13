//// Typed representation of per-request CLI chat configuration, decoded
//// from the raw request params.
////
//// The wire form is the optional `"config"` object on a
//// `POST /api/cli/chat` request body:
////
////     {
////       "config": {
////         "capabilities": ["client_v1_read_file", ...],
////         "run_preference": "auto" | "suggest" | "run",
////         "model": "max" | "fast"
////       }
////     }
////
//// `model` is an alias, not a provider model ID — the decoder maps it to
//// the real model at parse time. That way the set of usable models is a
//// closed set the server controls, and analytics can segment on the alias
//// without having to reverse-map provider IDs.
////
//// Every field is optional, unknown keys are ignored, and any field whose
//// value has the wrong shape falls back to its default — older clients
//// (that don't send `config` at all) and newer clients (that send fields
//// this server release doesn't yet understand) both work without error.
////
//// ## Backward compatibility for `capabilities`
////
//// Before `config` existed, the CLI sent its capability list on the
//// top-level request body as `"capabilities": [...]`. That shape is frozen
//// in released binaries that we don't control, so this server MUST
//// continue to honor it forever. Both the nested and legacy lists funnel
//// through `capabilities.from_list`, and the results are unioned so
//// neither side "wins".

import atuin_ai_core/domain/capabilities.{type Capabilities}
import atuin_ai_core/domain/models
import gleam/dynamic
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type RunPreference {
  Auto
  Suggest
  Run
}

pub type UserContext {
  UserContext(file_path: String, content: String)
}

pub type SkillSummary {
  SkillSummary(name: String, description: String)
}

pub type ModelSelection {
  DefaultModel
  KnownModel(alias: String, provider_id: String)
  CustomModel(name: String, provider_id: String)
}

pub type Config {
  Config(
    app_version: Option(String),
    capabilities: Capabilities,
    run_preference: RunPreference,
    model_selection: ModelSelection,
    prompt_fn: Option(String),
    user_contexts: List(UserContext),
    skills: List(SkillSummary),
    skills_overflow: Option(String),
  )
}

pub fn default() -> Config {
  Config(
    app_version: None,
    capabilities: capabilities.new(),
    run_preference: Auto,
    model_selection: DefaultModel,
    prompt_fn: None,
    user_contexts: [],
    skills: [],
    skills_overflow: None,
  )
}

/// The alias (or custom-model name) the request resolves to, applying the
/// catalog's default when the client didn't select one, so analytics and
/// traces label default-model sessions correctly.
pub fn resolved_alias(config: Config, catalog: models.Catalog) -> String {
  case config.model_selection {
    DefaultModel -> catalog.default_alias
    KnownModel(alias, _) -> alias
    CustomModel(name, _) -> name
  }
}

/// The provider model ID the request will actually use, applying the
/// catalog's default alias when the client didn't select one. `None` only
/// when the catalog's default alias doesn't resolve in the catalog — a
/// deployment configuration error the caller rejects the request over.
pub fn resolved_provider_id(
  config: Config,
  catalog: models.Catalog,
) -> Option(String) {
  case config.model_selection {
    DefaultModel -> models.resolve(catalog, catalog.default_alias)
    KnownModel(_, provider_id) -> Some(provider_id)
    CustomModel(_, provider_id) -> Some(provider_id)
  }
}

pub fn from_params(params: dynamic.Dynamic, catalog: models.Catalog) -> Config {
  case decode.run(params, params_decoder(catalog)) {
    Ok(config) -> config
    Error(_) -> default()
  }
}

pub fn raw_model_from_params(params: dynamic.Dynamic) -> Option(String) {
  case decode.run(params, raw_model_decoder()) {
    Ok(raw_model) -> raw_model
    Error(_) -> None
  }
}

pub fn defaults_gated(config: Config) -> Config {
  Config(..config, model_selection: DefaultModel, run_preference: Auto)
}

pub fn llm_selection_gated(
  config: Config,
  raw_model: Option(String),
  catalog: models.Catalog,
) -> Config {
  let model_selection = case raw_model {
    Some(raw_model) -> parse_model_llm_selection(raw_model, catalog)
    None -> DefaultModel
  }

  Config(..config, model_selection:)
}

pub fn llm_selection_disabled(
  config: Config,
  catalog: models.Catalog,
) -> Config {
  // Hidden aliases (visible_in_cli: False) are selectable only behind
  // :llm_selection; without the flag they decay to the default, matching
  // the lenient handling of unrecognized model strings.
  let model_selection = case config.model_selection {
    KnownModel(alias, _) ->
      case models.visible_in_cli(catalog, alias) {
        True -> config.model_selection
        False -> DefaultModel
      }
    other -> other
  }
  Config(..config, prompt_fn: None, model_selection:)
}

pub fn apply_feature_gates(
  config: Config,
  catalog: models.Catalog,
  raw_model: Option(String),
  cli_chat_options_enabled: Bool,
  llm_selection_enabled: Bool,
) -> Config {
  let config = case cli_chat_options_enabled {
    True -> config
    False -> defaults_gated(config)
  }

  case llm_selection_enabled {
    True -> llm_selection_gated(config, raw_model, catalog)
    False -> llm_selection_disabled(config, catalog)
  }
}

/// Decodes a `Config` from the raw request params. Accepts the full params
/// value (not just `params.config`) because it needs to read both the
/// nested config object and the legacy top-level `capabilities` key.
/// Anything malformed — including params that aren't a map at all — decays
/// to defaults rather than erroring.
pub fn params_decoder(catalog: models.Catalog) -> Decoder(Config) {
  use nested_caps <- decode.then(decode.optionally_at(
    ["config", "capabilities"],
    capabilities.new(),
    lenient_capabilities(),
  ))
  use run_preference <- decode.then(decode.optionally_at(
    ["config", "run_preference"],
    Auto,
    lenient_run_preference(),
  ))
  use model_selection <- decode.then(decode.optionally_at(
    ["config", "model"],
    DefaultModel,
    lenient_model(catalog),
  ))
  use prompt_fn <- decode.then(decode.optionally_at(
    ["config", "prompt_fn"],
    None,
    lenient_prompt_fn(),
  ))
  use user_contexts <- decode.then(decode.optionally_at(
    ["config", "user_contexts"],
    [],
    lenient_user_contexts(),
  ))
  use skills <- decode.then(decode.optionally_at(
    ["config", "skills"],
    [],
    lenient_skills(),
  ))
  use skills_overflow <- decode.then(decode.optionally_at(
    ["config", "skills_overflow"],
    None,
    lenient_skills_overflow(),
  ))
  use legacy_caps <- decode.then(decode.optionally_at(
    ["capabilities"],
    capabilities.new(),
    lenient_capabilities(),
  ))

  decode.success(Config(
    app_version: None,
    capabilities: capabilities.merge(nested_caps, legacy_caps),
    run_preference:,
    model_selection:,
    prompt_fn:,
    user_contexts:,
    skills:,
    skills_overflow:,
  ))
}

fn raw_model_decoder() -> Decoder(Option(String)) {
  decode.optionally_at(["config", "model"], None, lenient_string_option())
}

fn lenient_string_option() -> Decoder(Option(String)) {
  decode.one_of(decode.string |> decode.map(Some), or: [
    decode.success(None),
  ])
}

// Non-string entries decay to "" (dropped as unknown by from_list); a
// non-list value decays to no capabilities.
fn lenient_capabilities() -> Decoder(Capabilities) {
  decode.one_of(
    decode.list(decode.one_of(decode.string, [decode.success("")]))
      |> decode.map(capabilities.from_list),
    [decode.success(capabilities.new())],
  )
}

fn lenient_run_preference() -> Decoder(RunPreference) {
  decode.one_of(
    decode.string
      |> decode.map(fn(value) {
        case value {
          "auto" -> Auto
          "suggest" -> Suggest
          "run" -> Run
          _unknown -> Auto
        }
      }),
    [decode.success(Auto)],
  )
}

// Returns a known catalog-whitelisted model selection, or `DefaultModel`
// for anything we don't recognize.
fn lenient_model(catalog: models.Catalog) -> Decoder(ModelSelection) {
  decode.one_of(
    decode.string
      |> decode.map(fn(value) {
        case models.resolve(catalog, value) {
          Some(provider_id) -> KnownModel(value, provider_id)
          None -> DefaultModel
        }
      }),
    [decode.success(DefaultModel)],
  )
}

fn lenient_prompt_fn() -> Decoder(Option(String)) {
  decode.one_of(
    decode.string
      |> decode.map(fn(value) {
        // Known prompt function names: "default" is the standard system
        // prompt; other values map to variants in the prompt module.
        case value {
          "default" | "concise" -> Some(value)
          _unknown -> None
        }
      }),
    [decode.success(None)],
  )
}

fn lenient_user_contexts() -> Decoder(List(UserContext)) {
  decode.one_of(
    decode.list(user_context_item())
      // Take 10 raw entries *before* dropping invalid ones, matching the
      // historical behavior.
      // TODO: verify the historical behavior is what we want
      |> decode.map(fn(items) { items |> list.take(10) |> option.values }),
    [decode.success([])],
  )
}

fn user_context_item() -> Decoder(Option(UserContext)) {
  decode.one_of(
    {
      use path <- decode.field("path", decode.string)
      use content <- decode.field("data", decode.string)
      decode.success(
        Some(UserContext(
          file_path: truncate(path, 150, "(truncated due to length)"),
          content: truncate(content, 10_000, "(truncated due to length)"),
        )),
      )
    },
    [decode.success(None)],
  )
}

fn lenient_skills() -> Decoder(List(SkillSummary)) {
  decode.one_of(
    decode.list(skill_item())
      |> decode.map(fn(items) { items |> list.take(50) |> option.values }),
    [decode.success([])],
  )
}

fn skill_item() -> Decoder(Option(SkillSummary)) {
  decode.one_of(
    {
      use name <- decode.field("name", decode.string)
      use description <- decode.field("description", decode.string)
      decode.success(
        Some(SkillSummary(
          name: truncate(name, 64, ""),
          description: truncate(description, 1024, ""),
        )),
      )
    },
    [
      {
        use name <- decode.field("name", decode.string)
        decode.success(
          Some(SkillSummary(name: truncate(name, 64, ""), description: "")),
        )
      },
      decode.success(None),
    ],
  )
}

fn lenient_skills_overflow() -> Decoder(Option(String)) {
  decode.one_of(
    decode.string |> decode.map(fn(value) { Some(truncate(value, 500, "")) }),
    [decode.success(None)],
  )
}

/// Relaxed model parsing for `:llm_selection` users — any model string is
/// accepted and routed through OpenRouter.
///
/// If the value is a known alias (e.g. "max"), it's resolved normally.
/// Otherwise the value is treated as an OpenRouter model identifier:
///   "openrouter:openai/gpt-4o" -> #("openai/gpt-4o", "openrouter:openai/gpt-4o")
///   "openai/gpt-4o"           -> #("openai/gpt-4o", "openrouter:openai/gpt-4o")
///   "gpt-4o"                  -> #("gpt-4o", "openrouter:gpt-4o")
/// A different provider prefix passes through unchanged — the caller
/// explicitly chose a provider. "fireworks:..." is served by the native
/// Fireworks adapter; a prefix with no adapter (e.g. "anthropic:...") is
/// sent to OpenRouter, which rejects it.
pub fn parse_model_llm_selection(
  value: String,
  catalog: models.Catalog,
) -> ModelSelection {
  case models.resolve(catalog, value) {
    Some(provider_id) -> KnownModel(value, provider_id)
    None ->
      case string.starts_with(value, "openrouter:") {
        True -> CustomModel(trim_leading(value, "openrouter:"), value)
        False ->
          case string.contains(value, ":") {
            True -> CustomModel(value, value)
            False -> CustomModel(value, "openrouter:" <> value)
          }
      }
  }
}

// Mirrors Elixir's String.trim_leading/2: strips *repeated* leading
// occurrences of the prefix.
fn trim_leading(text: String, prefix: String) -> String {
  case string.starts_with(text, prefix) {
    True ->
      text
      |> string.drop_start(string.length(prefix))
      |> trim_leading(prefix)
    False -> text
  }
}

fn truncate(text: String, length: Int, suffix: String) -> String {
  case string.length(text) > length {
    True -> string.slice(text, 0, length) <> "... " <> suffix
    False -> text
  }
}
