import atuin_hub/json_schema as schema
import gleam/json

fn to_string(s: schema.Schema) -> String {
  s |> schema.to_json |> json.to_string
}

pub fn object_with_required_and_optional_properties_test() {
  let s =
    schema.object([
      schema.prop("name", schema.string()),
      schema.prop("age", schema.integer()) |> schema.optional,
    ])

  assert to_string(s)
    == "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"age\":{\"type\":\"integer\"}},\"required\":[\"name\"]}"
}

pub fn description_test() {
  let s =
    schema.object([
      schema.prop(
        "name",
        schema.string() |> schema.description("The name of the person"),
      ),
    ])

  assert to_string(s)
    == "{\"type\":\"object\",\"properties\":{\"name\":{\"description\":\"The name of the person\",\"type\":\"string\"}},\"required\":[\"name\"]}"
}

pub fn enum_on_property_test() {
  let s = schema.string() |> schema.enum_strings(["high", "med", "low"])

  assert to_string(s)
    == "{\"enum\":[\"high\",\"med\",\"low\"],\"type\":\"string\"}"
}

pub fn enum_on_array_items_test() {
  let s =
    schema.array(
      schema.string() |> schema.enum_strings(["red", "green", "blue"]),
    )

  assert to_string(s)
    == "{\"type\":\"array\",\"items\":{\"enum\":[\"red\",\"green\",\"blue\"],\"type\":\"string\"}}"
}

pub fn nested_array_item_constraints_test() {
  // The atuin_output `ranges` shape: up to 10 [start, end] pairs.
  let s =
    schema.array(
      schema.array(schema.integer())
      |> schema.min_items(2)
      |> schema.max_items(2),
    )
    |> schema.max_items(10)

  assert to_string(s)
    == "{\"maxItems\":10,\"type\":\"array\",\"items\":{\"minItems\":2,\"maxItems\":2,\"type\":\"array\",\"items\":{\"type\":\"integer\"}}}"
}

pub fn numeric_bounds_test() {
  let s = schema.integer() |> schema.minimum_int(1) |> schema.maximum_int(50)

  assert to_string(s) == "{\"minimum\":1,\"maximum\":50,\"type\":\"integer\"}"
}

pub fn integer_and_float_type_names_test() {
  assert to_string(schema.integer()) == "{\"type\":\"integer\"}"
  assert to_string(schema.float()) == "{\"type\":\"number\"}"
}

pub fn union_test() {
  let s = schema.union([schema.string(), schema.null()])

  assert to_string(s) == "{\"type\":[\"string\",\"null\"]}"
}

pub fn additional_properties_test() {
  let props = [schema.prop("name", schema.string())]
  let base =
    "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]"

  assert to_string(schema.object(props)) == base <> "}"
  assert to_string(schema.object(props) |> schema.disallow_additional_props)
    == base <> ",\"additionalProperties\":false}"
  assert to_string(
      schema.object(props) |> schema.constrain_additional_props(schema.string()),
    )
    == base <> ",\"additionalProperties\":{\"type\":\"string\"}}"
}
