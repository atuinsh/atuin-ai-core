import atuin_hub/cli_chat/domain/config.{
  Auto, CustomModel, DefaultModel, KnownModel, Suggest, UserContext,
}
import atuin_hub/cli_chat/domain/models
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/catalogs

// These behaviors need realistic alias resolution ("max", hidden
// "experimental", ...), so they run against the shared synthetic catalog.
fn cat() -> models.Catalog {
  catalogs.catalog()
}

fn obj(entries: List(#(String, Dynamic))) -> Dynamic {
  entries
  |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) })
  |> dynamic.properties
}

fn strings(values: List(String)) -> Dynamic {
  values |> list.map(dynamic.string) |> dynamic.list
}

pub fn empty_params_gives_default_test() {
  assert config.from_params(obj([]), cat()) == config.default()
}

pub fn non_map_params_gives_default_test() {
  assert config.from_params(dynamic.string("nope"), cat()) == config.default()
  assert config.from_params(dynamic.int(42), cat()) == config.default()
}

pub fn non_map_config_gives_default_test() {
  assert config.from_params(
      obj([#("config", dynamic.string("not a map"))]),
      cat(),
    )
    == config.default()
  assert config.from_params(obj([#("config", dynamic.nil())]), cat())
    == config.default()
}

pub fn parses_nested_fields_test() {
  let params =
    obj([
      #(
        "config",
        obj([
          #("capabilities", strings(["client_v1_read_file"])),
          #("run_preference", dynamic.string("suggest")),
          #("model", dynamic.string("fast")),
        ]),
      ),
    ])
  let config = config.from_params(params, cat())
  assert config.capabilities.read_file
  assert config.run_preference == Suggest
  assert config.model_selection == KnownModel("fast", "fireworks:fast-model")
}

pub fn invalid_field_values_fall_back_test() {
  let params =
    obj([
      #(
        "config",
        obj([
          #("capabilities", dynamic.string("not a list")),
          #("run_preference", dynamic.int(7)),
          #("model", dynamic.list([])),
        ]),
      ),
    ])
  let config = config.from_params(params, cat())
  assert config.capabilities == config.default().capabilities
  assert config.run_preference == Auto
  assert config.model_selection == DefaultModel
}

pub fn rejects_raw_provider_model_ids_test() {
  let params =
    obj([
      #(
        "config",
        obj([#("model", dynamic.string("anthropic:claude-opus-4-6"))]),
      ),
    ])
  let config = config.from_params(params, cat())
  assert config.model_selection == DefaultModel
}

pub fn extracts_raw_model_for_llm_selection_test() {
  let params =
    obj([
      #("config", obj([#("model", dynamic.string("openai/gpt-4o"))])),
    ])

  assert config.raw_model_from_params(params) == Some("openai/gpt-4o")
}

pub fn malformed_config_has_no_raw_model_test() {
  assert config.raw_model_from_params(
      obj([#("config", dynamic.string("not a map"))]),
    )
    == None
}

pub fn unions_legacy_and_nested_capabilities_test() {
  let params =
    obj([
      #("capabilities", strings(["client_v1_edit_file"])),
      #("config", obj([#("capabilities", strings(["client_v1_read_file"]))])),
    ])
  let config = config.from_params(params, cat())
  assert config.capabilities.read_file
  assert config.capabilities.edit_file
}

pub fn user_contexts_truncate_and_skip_invalid_test() {
  let valid =
    obj([
      #("path", dynamic.string("~/notes.md")),
      #("data", dynamic.string("hello")),
    ])
  let invalid = obj([#("path", dynamic.int(1))])
  let long_path = string.repeat("p", 200)
  let truncated =
    obj([#("path", dynamic.string(long_path)), #("data", dynamic.string("x"))])
  let params =
    obj([
      #(
        "config",
        obj([#("user_contexts", dynamic.list([valid, invalid, truncated]))]),
      ),
    ])

  let assert [first, second] = config.from_params(params, cat()).user_contexts
  assert first == UserContext(file_path: "~/notes.md", content: "hello")
  assert second.file_path
    == string.repeat("p", 150) <> "... (truncated due to length)"
}

pub fn user_contexts_take_ten_before_validity_test() {
  let valid =
    obj([#("path", dynamic.string("p")), #("data", dynamic.string("d"))])
  let invalid = dynamic.string("junk")
  // 10 invalid entries first: the take-10 window contains no valid ones
  let entries = list.repeat(invalid, 10) |> list.append([valid])
  let params =
    obj([#("config", obj([#("user_contexts", dynamic.list(entries))]))])
  assert config.from_params(params, cat()).user_contexts == []
}

pub fn skills_name_only_gets_empty_description_test() {
  let params =
    obj([
      #(
        "config",
        obj([
          #(
            "skills",
            dynamic.list([
              obj([
                #("name", dynamic.string("deploy")),
                #("description", dynamic.string("ship it")),
              ]),
              obj([#("name", dynamic.string("bare"))]),
              obj([#("description", dynamic.string("no name"))]),
            ]),
          ),
        ]),
      ),
    ])
  let skills = config.from_params(params, cat()).skills
  assert list.map(skills, fn(skill) { #(skill.name, skill.description) })
    == [#("deploy", "ship it"), #("bare", "")]
}

pub fn skills_overflow_truncates_test() {
  let params =
    obj([
      #(
        "config",
        obj([#("skills_overflow", dynamic.string(string.repeat("s", 600)))]),
      ),
    ])
  let assert Some(overflow) = config.from_params(params, cat()).skills_overflow
  assert overflow == string.repeat("s", 500) <> "... "
}

pub fn llm_selection_known_alias_test() {
  assert config.parse_model_llm_selection("max", cat())
    == KnownModel("max", "openrouter:provider/max-model")
}

pub fn llm_selection_openrouter_prefixed_test() {
  assert config.parse_model_llm_selection("openrouter:openai/gpt-4o", cat())
    == CustomModel("openai/gpt-4o", "openrouter:openai/gpt-4o")
}

pub fn llm_selection_other_provider_passthrough_test() {
  assert config.parse_model_llm_selection("anthropic:claude-3-opus", cat())
    == CustomModel("anthropic:claude-3-opus", "anthropic:claude-3-opus")
}

pub fn llm_selection_bare_model_routes_openrouter_test() {
  assert config.parse_model_llm_selection("gpt-4o", cat())
    == CustomModel("gpt-4o", "openrouter:gpt-4o")
}

pub fn defaults_gated_strips_option_gated_fields_test() {
  let params =
    obj([
      #(
        "config",
        obj([
          #("run_preference", dynamic.string("suggest")),
          #("model", dynamic.string("fast")),
          #("prompt_fn", dynamic.string("concise")),
        ]),
      ),
    ])

  let gated = params |> config.from_params(cat()) |> config.defaults_gated

  assert gated.run_preference == Auto
  assert gated.model_selection == DefaultModel
  assert gated.prompt_fn == Some("concise")
}

pub fn llm_selection_gated_restores_custom_model_test() {
  let params =
    obj([
      #(
        "config",
        obj([
          #("run_preference", dynamic.string("suggest")),
          #("model", dynamic.string("openai/gpt-4o")),
          #("prompt_fn", dynamic.string("concise")),
        ]),
      ),
    ])

  let gated =
    params
    |> config.from_params(cat())
    |> config.defaults_gated
    |> config.llm_selection_gated(Some("openai/gpt-4o"), cat())

  assert gated.run_preference == Auto
  assert gated.model_selection
    == CustomModel("openai/gpt-4o", "openrouter:openai/gpt-4o")
  assert gated.prompt_fn == Some("concise")
}

pub fn without_llm_selection_clears_prompt_fn_test() {
  let params =
    obj([#("config", obj([#("prompt_fn", dynamic.string("concise"))]))])

  let gated =
    params
    |> config.from_params(cat())
    |> config.llm_selection_disabled(cat())

  assert gated.prompt_fn == None
}

pub fn without_llm_selection_hidden_alias_decays_to_default_test() {
  let params =
    obj([#("config", obj([#("model", dynamic.string("experimental"))]))])

  let gated =
    params
    |> config.from_params(cat())
    |> config.llm_selection_disabled(cat())

  assert gated.model_selection == DefaultModel
}

pub fn without_llm_selection_visible_alias_survives_test() {
  let params = obj([#("config", obj([#("model", dynamic.string("max"))]))])

  let gated =
    params
    |> config.from_params(cat())
    |> config.llm_selection_disabled(cat())

  assert gated.model_selection
    == KnownModel("max", "openrouter:provider/max-model")
}

pub fn with_llm_selection_hidden_alias_survives_test() {
  let params =
    obj([#("config", obj([#("model", dynamic.string("experimental"))]))])

  let gated =
    params
    |> config.from_params(cat())
    |> config.llm_selection_gated(Some("experimental"), cat())

  assert gated.model_selection
    == KnownModel("experimental", "openrouter:provider/experimental-model")
}
