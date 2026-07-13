import atuin_ai_core/domain/tools
import atuin_ai_core/json_schema as schema

pub fn web_search() -> tools.ToolDefinition {
  tools.ToolDefinition(
    name: "web_search",
    description: "Searches the web for information to help answer the user's question.
Use this when you need current information, documentation, or examples
that you don't have in your training data.
Limited to 5 searches per conversation turn.
",
    parameter_schema: tools.JsonSchema(
      schema.object([
        schema.prop(
          "query",
          schema.string() |> schema.description("The search query to execute"),
        ),
      ]),
    ),
  )
}
