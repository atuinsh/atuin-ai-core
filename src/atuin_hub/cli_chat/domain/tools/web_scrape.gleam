import atuin_hub/cli_chat/domain/tools
import atuin_hub/json_schema as schema

pub fn web_scrape() -> tools.ToolDefinition {
  tools.ToolDefinition(
    name: "web_scrape",
    description: "Fetches and extracts text content from a specific URL.
Use this when web_search returns a relevant URL and you need
the full content (documentation, examples, etc.).
Limited to 3 scrapes per conversation turn.
",
    parameter_schema: tools.JsonSchema(
      schema.object([
        schema.prop(
          "url",
          schema.string() |> schema.description("The URL to fetch and scrape"),
        ),
      ]),
    ),
  )
}
