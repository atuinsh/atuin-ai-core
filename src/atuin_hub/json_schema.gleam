/// A module for generating JSON Schema from Gleam type definitions.
/// Based on https://github.com/Neofox/jscheam with edits for additional features
import gleam/json
import gleam/list
import gleam/option

/// A schema node: a type plus its annotations. Every schema position — a
/// property's value, an array's items, additionalProperties — is a full
/// `Schema`, so descriptions and constraints can be applied at any depth.
pub type Schema {
  Schema(
    type_: Type,
    description: option.Option(String),
    constraints: List(Constraint),
  )
}

/// Constraints that can be applied to a schema node
pub type Constraint {
  /// Restrict values to a fixed set of values (can be any JSON value)
  Enum(values: List(json.Json))
  /// Pattern constraint using regex
  Pattern(regex: String)
  /// Minimum value constraint for numeric types
  Minimum(value: Number)
  /// Maximum value constraint for numeric types
  Maximum(value: Number)
  /// Minimum length constraint for array types
  MinItems(count: Int)
  /// Maximum length constraint for array types
  MaxItems(count: Int)
}

/// A JSON number, used in numeric constraints so that integer bounds
/// serialize without a decimal point (e.g. 5 rather than 5.0)
pub type Number {
  IntValue(Int)
  FloatValue(Float)
}

/// A type definition for JSON Schema
pub type Type {
  Integer
  String
  Boolean
  Float
  Null
  Object(
    properties: List(Property),
    additional_properties: AdditionalProperties,
  )
  Array(items: Schema)
  /// Union type for multiple allowed types (e.g., ["string", "null"])
  Union(List(Type))
}

fn schema(type_: Type) -> Schema {
  Schema(type_: type_, description: option.None, constraints: [])
}

/// Creates a string schema
pub fn string() -> Schema {
  schema(String)
}

/// Creates an integer schema
pub fn integer() -> Schema {
  schema(Integer)
}

/// Creates a boolean schema
pub fn boolean() -> Schema {
  schema(Boolean)
}

/// Creates a float/number schema
pub fn float() -> Schema {
  schema(Float)
}

/// Creates a null schema
pub fn null() -> Schema {
  schema(Null)
}

/// Creates an array schema with the specified item schema
/// Example: array(string() |> enum_strings(["red", "green", "blue"]))
pub fn array(items: Schema) -> Schema {
  schema(Array(items))
}

/// Creates a union schema that accepts multiple types (e.g., string or null).
/// Only the types of the given schemas are used; JSON Schema's `"type": [...]`
/// form can't carry per-branch descriptions or constraints.
/// Example: union([string(), null()]) accepts both strings and null values
pub fn union(schemas: List(Schema)) -> Schema {
  schema(Union(list.map(schemas, fn(s) { s.type_ })))
}

/// Creates an object schema with the specified properties
/// By default allows any additional properties (JSON Schema default behavior - omits the field)
pub fn object(properties: List(Property)) -> Schema {
  schema(Object(properties: properties, additional_properties: AllowAny))
}

/// Update an object schema to allow any additional properties
/// Explicitly allows any additional properties (outputs "additionalProperties": true)
pub fn allow_additional_props(object_schema: Schema) -> Schema {
  set_additional_props(object_schema, AllowExplicit)
}

/// Update an object schema to disallow additional properties
/// Disallows additional properties (outputs "additionalProperties": false)
pub fn disallow_additional_props(object_schema: Schema) -> Schema {
  set_additional_props(object_schema, Disallow)
}

/// Update an object schema to constrain additional properties to a specific schema
/// Example: object([prop("name", string())]) |> constrain_additional_props(string())
/// This will set "additionalProperties" to the specified schema
pub fn constrain_additional_props(
  object_schema: Schema,
  additional: Schema,
) -> Schema {
  set_additional_props(object_schema, WithSchema(additional))
}

fn set_additional_props(
  object_schema: Schema,
  add_props: AdditionalProperties,
) -> Schema {
  case object_schema.type_ {
    Object(properties: props, additional_properties: _) ->
      Schema(
        ..object_schema,
        type_: Object(properties: props, additional_properties: add_props),
      )
    _ -> object_schema
  }
}

/// A property in an object type: a named schema plus whether it is required.
pub type Property {
  Property(name: String, schema: Schema, is_required: Bool)
}

/// Additional properties configuration for object types
pub type AdditionalProperties {
  /// Allow any additional properties (JSON Schema Draft 7 default behavior)
  /// This is the default and will omit the additionalProperties field from the schema
  AllowAny
  /// Explicitly allow any additional properties (outputs "additionalProperties": true)
  AllowExplicit
  /// Disallow any additional properties
  Disallow
  /// Additional properties must conform to the specified schema
  WithSchema(Schema)
}

// Property builders
/// Creates a property with the specified name and schema
/// Properties are required by default
pub fn prop(name: String, schema: Schema) -> Property {
  Property(name: name, schema: schema, is_required: True)
}

/// Makes a property optional (not required in the schema)
/// Example: object([prop("name", string()) |> optional()])
pub fn optional(property: Property) -> Property {
  Property(..property, is_required: False)
}

// Schema builders
/// Adds a description to a schema node for documentation purposes
/// Example: prop("name", string() |> description("The name of the person"))
pub fn description(schema: Schema, desc: String) -> Schema {
  Schema(..schema, description: option.Some(desc))
}

fn constrain(schema: Schema, constraint: Constraint) -> Schema {
  Schema(..schema, constraints: [constraint, ..schema.constraints])
}

/// Adds an enum constraint to a schema that restricts values to a fixed set
/// Example: prop("color", string() |> enum_strings(["red", "green", "blue"]))
pub fn enum(schema: Schema, values: List(json.Json)) -> Schema {
  constrain(schema, Enum(values: values))
}

/// Adds an enum constraint from a list of strings
/// Example: array(string() |> enum_strings(["red", "green", "blue"]))
pub fn enum_strings(schema: Schema, values: List(String)) -> Schema {
  enum(schema, list.map(values, json.string))
}

/// Adds a pattern constraint to a schema that restricts values to match a regex pattern
/// Example: prop("phone", string() |> pattern("^(\\([0-9]{3}\\))?[0-9]{3}-[0-9]{4}$"))
pub fn pattern(schema: Schema, regex: String) -> Schema {
  constrain(schema, Pattern(regex: regex))
}

/// Adds an integer minimum value constraint to a numeric schema
/// Example: prop("age", integer() |> minimum_int(0))
pub fn minimum_int(schema: Schema, value: Int) -> Schema {
  constrain(schema, Minimum(value: IntValue(value)))
}

/// Adds a float minimum value constraint to a numeric schema
/// Example: prop("score", float() |> minimum_float(0.5))
pub fn minimum_float(schema: Schema, value: Float) -> Schema {
  constrain(schema, Minimum(value: FloatValue(value)))
}

/// Adds an integer maximum value constraint to a numeric schema
/// Example: prop("age", integer() |> maximum_int(120))
pub fn maximum_int(schema: Schema, value: Int) -> Schema {
  constrain(schema, Maximum(value: IntValue(value)))
}

/// Adds a float maximum value constraint to a numeric schema
/// Example: prop("score", float() |> maximum_float(9.5))
pub fn maximum_float(schema: Schema, value: Float) -> Schema {
  constrain(schema, Maximum(value: FloatValue(value)))
}

/// Adds a minimum length constraint to an array schema
/// Example: prop("tags", array(string()) |> min_items(1))
pub fn min_items(schema: Schema, count: Int) -> Schema {
  constrain(schema, MinItems(count: count))
}

/// Adds a maximum length constraint to an array schema
/// Example: prop("tags", array(string()) |> max_items(10))
pub fn max_items(schema: Schema, count: Int) -> Schema {
  constrain(schema, MaxItems(count: count))
}

fn additional_properties_to_json(
  add_props: AdditionalProperties,
) -> List(#(String, json.Json)) {
  case add_props {
    // Omit the field entirely (JSON Schema Draft 7 default equivalent to "additionalProperties": true)
    AllowAny -> []
    AllowExplicit -> [#("additionalProperties", json.bool(True))]
    Disallow -> [#("additionalProperties", json.bool(False))]
    WithSchema(schema) -> [#("additionalProperties", to_json(schema))]
  }
}

fn type_to_type_string(type_: Type) -> String {
  case type_ {
    String -> "string"
    Integer -> "integer"
    Boolean -> "boolean"
    Null -> "null"
    Float -> "number"
    Object(_, _) -> "object"
    Array(_) -> "array"
    Union(_) ->
      panic as "Union types should not be converted to single type strings"
  }
}

fn schema_to_fields(schema: Schema) -> List(#(String, json.Json)) {
  let base_fields = type_to_fields(schema.type_)
  let fields_with_constraints =
    add_constraint_fields(base_fields, schema.constraints)
  case schema.description {
    option.Some(desc) -> [
      #("description", json.string(desc)),
      ..fields_with_constraints
    ]
    option.None -> fields_with_constraints
  }
}

fn type_to_fields(type_: Type) -> List(#(String, json.Json)) {
  case type_ {
    String | Integer | Boolean | Null | Float -> [
      #("type", json.string(type_to_type_string(type_))),
    ]
    Array(items) -> [
      #("type", json.string(type_to_type_string(type_))),
      #("items", to_json(items)),
    ]
    Object(properties: props, additional_properties: add_props) -> {
      let properties_json =
        props
        |> list.map(fn(property) { #(property.name, to_json(property.schema)) })
        |> json.object
      let required_json = fields_to_required(props)
      let additional_props_fields = additional_properties_to_json(add_props)

      let base_fields = [
        #("type", json.string(type_to_type_string(type_))),
        #("properties", properties_json),
        #("required", required_json),
      ]

      list.append(base_fields, additional_props_fields)
    }
    Union(types) -> {
      let type_strings = list.map(types, type_to_type_string)
      [#("type", json.array(type_strings, json.string))]
    }
  }
}

fn add_constraint_fields(
  base_fields: List(#(String, json.Json)),
  constraints: List(Constraint),
) -> List(#(String, json.Json)) {
  list.fold(constraints, base_fields, add_single_constraint_field)
}

fn number_to_json(number: Number) -> json.Json {
  case number {
    IntValue(n) -> json.int(n)
    FloatValue(n) -> json.float(n)
  }
}

fn add_single_constraint_field(
  fields: List(#(String, json.Json)),
  constraint: Constraint,
) -> List(#(String, json.Json)) {
  case constraint {
    Enum(values: values) -> [
      #("enum", json.array(values, fn(x) { x })),
      ..fields
    ]
    Pattern(regex: regex) -> [#("pattern", json.string(regex)), ..fields]
    Minimum(value: value) -> [#("minimum", number_to_json(value)), ..fields]
    Maximum(value: value) -> [#("maximum", number_to_json(value)), ..fields]
    MinItems(count: count) -> [#("minItems", json.int(count)), ..fields]
    MaxItems(count: count) -> [#("maxItems", json.int(count)), ..fields]
  }
}

fn fields_to_required(properties: List(Property)) -> json.Json {
  properties
  |> list.filter(fn(property) { property.is_required })
  |> list.map(fn(property) { json.string(property.name) })
  |> json.array(fn(x) { x })
}

/// Converts a Schema to a JSON Schema document
/// This is the main function to generate JSON Schema from your definitions
/// Example: object([prop("name", string()), prop("age", integer())]) |> to_json()
pub fn to_json(schema: Schema) -> json.Json {
  json.object(schema_to_fields(schema))
}
