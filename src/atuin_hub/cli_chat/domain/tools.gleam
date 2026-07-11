//// Tool definitions for the CLI chat LLM calls.
////
//// Owns suggest_command (server-side structured output) and the
//// client-side tools gated by declared `Capabilities`. The web_search and
//// web_scrape definitions live in `domain/tools/`; the instance's
//// registrations splice them into the final list, and which tools the
//// server executes is likewise the instance's knowledge, not this
//// module's.
////
//// Descriptions are prompt bytes: they're part of the cached prefix sent
//// to the model, so any change invalidates prompt caches and must be
//// deliberate. Schemas are built with the `json_schema` module and
//// serialized to JSON at the client boundary.

import atuin_hub/cli_chat/domain/capabilities.{type Capabilities}
import atuin_hub/json_schema as schema
import gleam/option.{type Option, None, Some}

pub type ToolDefinition {
  ToolDefinition(
    name: String,
    description: String,
    parameter_schema: JsonSchema,
  )
}

pub type JsonSchema {
  JsonSchema(schema.Schema)
}

/// The suggest_command tool definition for structured command output, with
/// confidence and safety indicators.
pub fn suggest_command() -> ToolDefinition {
  ToolDefinition(
    name: "suggest_command",
    description: "Suggest a shell command to the user. The command is displayed in the user's terminal
where they can choose to run it. Provide the command with a description, confidence,
and danger assessment.

Only call this tool when you have a command to suggest. For pure conversation
(answers, clarifying questions, explanations), respond with plain text instead.
",
    parameter_schema: JsonSchema(
      schema.object([
        schema.prop(
          "command",
          schema.string()
            |> schema.description("The shell command to suggest to the user"),
        ),
        schema.prop(
          "description",
          schema.string()
            |> schema.description("Brief description of the command"),
        ),
        schema.prop(
          "confidence",
          schema.string()
            |> schema.enum_strings(["high", "med", "low"])
            |> schema.description("Confidence level in the suggested command"),
        ),
        schema.prop(
          "confidence_notes",
          schema.string()
            |> schema.description("Brief explanation of confidence level"),
        )
          |> schema.optional,
        schema.prop(
          "danger",
          schema.string()
            |> schema.enum_strings(["high", "med", "low"])
            |> schema.description(
              "Safety level: high = destructive/sudo, med = modifies files, low = safe read-only",
            ),
        ),
        schema.prop(
          "danger_notes",
          schema.string()
            |> schema.description(
              "Brief explanation of safety concerns (e.g., 'deletes files recursively')",
            ),
        )
          |> schema.optional,
      ]),
    ),
  )
}

/// Client-side tool definitions for the given capabilities, in the stable
/// order the prompt cache depends on.
pub fn client_tools(caps: Capabilities) -> List(ToolDefinition) {
  [
    gate(caps.read_file, read_file),
    gate(caps.edit_file, edit_file),
    gate(caps.write_file, write_file),
    gate(caps.atuin_history, atuin_history),
    gate(caps.atuin_output, atuin_output),
    gate(caps.execute_shell_command, execute_shell_command),
    gate(caps.load_skill, load_skill),
  ]
  |> option.values
}

fn gate(
  enabled: Bool,
  definition: fn() -> ToolDefinition,
) -> Option(ToolDefinition) {
  case enabled {
    True -> Some(definition())
    False -> None
  }
}

pub fn load_skill() -> ToolDefinition {
  ToolDefinition(
    name: "load_skill",
    description: "Loads the full content of a skill by name. Skills are user-defined instruction
sets (playbooks, conventions, workflows) that the user has configured on their
system. The available skills and their descriptions are listed in the system
prompt. Use this tool when a skill's instructions are relevant to the current
task. The tool returns the skill's full body content with any embedded shell
commands already executed and substituted.
",
    parameter_schema: JsonSchema(
      schema.object([
        schema.prop(
          "name",
          schema.string()
            |> schema.description(
              "The name of the skill to load, as listed in the available skills",
            ),
        ),
      ]),
    ),
  )
}

pub fn read_file() -> ToolDefinition {
  ToolDefinition(
    name: "read_file",
    description: "Reads the contents of a file or directory on the user's system. Use this to
get context from configuration files, code files, or any relevant text files
that can help you understand the user's environment and provide better
suggestions, answers, or assistance. Each line is prefixed with its line
number in the file, starting from 1, followed by a `\\t` (tab) character.
",
    parameter_schema: JsonSchema(
      schema.object([
        schema.prop(
          "file_path",
          schema.string()
            |> schema.description(
              "The path to the file or directory to read, relative to the current directory or absolute",
            ),
        ),
        schema.prop(
          "limit",
          schema.integer()
            |> schema.minimum_int(1)
            |> schema.maximum_int(1000)
            |> schema.description(
              "Maximum number of lines to read from the file (default: 100, max 1000). Ignored if reading a directory.",
            ),
        )
          |> schema.optional,
        schema.prop(
          "offset",
          schema.integer()
            |> schema.description(
              "Number of lines to skip from the start of the file before reading (default: 0). Ignored if reading a directory.",
            ),
        )
          |> schema.optional,
      ]),
    ),
  )
}

pub fn edit_file() -> ToolDefinition {
  ToolDefinition(
    name: "edit_file",
    description: "Edits a file on the user's system by replacing an exact string match with new
content. The file MUST have been read first using read_file — edits to unread
files will be rejected.

The old_string must match the file content exactly, including whitespace and
indentation. By default, old_string must appear exactly once in the file. If
it appears multiple times and you want to replace all of them, set replace_all
to true. If it appears multiple times and you only want to replace one, provide
more surrounding context in old_string to make the match unique.

Use this for targeted edits to existing files — especially configuration files
where preserving comments, formatting, and key ordering matters. For creating
new files, use write_file instead.

If you get an error saying the file was modified since read, call read_file
again to get the current contents before retrying the edit.
",
    parameter_schema: JsonSchema(
      schema.object([
        schema.prop(
          "file_path",
          schema.string()
            |> schema.description(
              "The path to the file to edit, relative to the current directory or absolute",
            ),
        ),
        schema.prop(
          "old_string",
          schema.string()
            |> schema.description(
              "The exact text to find in the file. Must match byte-for-byte including whitespace and indentation.",
            ),
        ),
        schema.prop(
          "new_string",
          schema.string()
            |> schema.description("The text to replace old_string with"),
        ),
        schema.prop(
          "replace_all",
          schema.boolean()
            |> schema.description(
              "If true, replace all occurrences of old_string. If false (default), old_string must appear exactly once.",
            ),
        )
          |> schema.optional,
      ]),
    ),
  )
}

pub fn write_file() -> ToolDefinition {
  ToolDefinition(
    name: "write_file",
    description: "Creates a new file or overwrites an existing file on the user's system.
Use this to write complete file contents when creating new files or when
the entire content needs to be replaced.

For new files: just provide file_path and content. Parent directories will
be created automatically.

For existing files: you MUST set overwrite to true. If the file exists and
overwrite is not set, an error will be returned. Consider using edit_file
instead if you only need to change a small part of an existing file — it
preserves formatting and is safer for config files.
",
    parameter_schema: JsonSchema(
      schema.object([
        schema.prop(
          "file_path",
          schema.string()
            |> schema.description(
              "The path to the file to write, relative to the current directory or absolute",
            ),
        ),
        schema.prop(
          "content",
          schema.string()
            |> schema.description("The complete content to write to the file"),
        ),
        schema.prop(
          "overwrite",
          schema.boolean()
            |> schema.description(
              "Must be set to true to overwrite an existing file. If false (default), writing to an existing file will return an error.",
            ),
        )
          |> schema.optional,
      ]),
    ),
  )
}

pub fn atuin_history() -> ToolDefinition {
  ToolDefinition(
    name: "atuin_history",
    description: "Searches the user's Atuin command history for relevant past commands.
Use this when multiple commands might be relevant and you want to know what
tools the user uses most, or when the user references a previously run
command that you don't have the details for.

There are multiple filter modes to choose from; opt for the least intrusive
unless there's a good reason to use a more general mode:
* workspace - only search commands from the current git project
  E.g. \"when did the tests last pass?\" -> the user is probably referring to recent test commands in this project
* directory - only search commands run from the current directory
  Usually similar to workspace but without git context; can be useful if the user is asking about
  commands they've run in this part of the filesystem, but workspace is usually more appropriate
* session - only search commands from the current shell session
  E.g. \"why did that command fail?\" -> the user is probably referring to the most recent command in that session
* host - search all commands from the current machine, regardless of session or directory
  E.g. \"when did I last restart postgresql?\" -> the user is probably referring to any command they've run to restart
  postgresql on this machine, not just in this project or session
* global - search all commands from all machines
  E.g. \"what's the most common way I use docker?\" -> the user is probably referring to their overall docker usage,
  not just in this project or session
",
    parameter_schema: JsonSchema(
      schema.object([
        schema.prop(
          "query",
          schema.string()
            |> schema.description(
              "Search query to find relevant commands in history; use empty string to return most recent commands",
            ),
        ),
        schema.prop(
          "limit",
          schema.integer()
            |> schema.minimum_int(1)
            |> schema.maximum_int(50)
            |> schema.description(
              "Maximum number of results to return (default: 10)",
            ),
        )
          |> schema.optional,
        schema.prop(
          "filter_modes",
          schema.array(
            schema.string()
            |> schema.enum_strings([
              "workspace", "directory", "session", "host", "global",
            ]),
          )
            |> schema.description(
              "A list of filter modes, in order of priority. The first allowed mode will be returned.",
            ),
        ),
      ]),
    ),
  )
}

pub fn atuin_output() -> ToolDefinition {
  ToolDefinition(
    name: "atuin_output",
    description: "Looks up the full output of a command from the user's Atuin history. Use this to read the
captured stdout/stderr for a specific history entry. Pass a history entry's ID as `history_id` to retrieve
the output. History IDs come from `atuin_history` results (the `id` field) or from the `last_command` value
in the turn_context block — when the user refers to their most recent command (\"fix that\", \"why did that
fail\"), pass the last_command's History ID directly instead of searching history first.

Use `ranges` to request specific line ranges from the output. Each range is a `[start, end]` pair
where both indices are 0-based and inclusive. Negative indices count from the end: `-1` is the last
line, `-200` is the 200th-from-last.

Common patterns:
* First look: `[[0, 100], [-200, -1]]` — head and tail in one call
* Entire output: `[[0, -1]]` — use sparingly and only when total length is already known or expected to be small
* Drill into middle: `[[250, 275]]`
* Combination: `[[0, 50], [250, 275], [-100, -1]]`

The returned output has line numbers prefixed (starting from 1) followed by a tab character, just like `read_file`,
to help you correlate it with the original command output and refer back to specific lines in your response.
",
    parameter_schema: JsonSchema(
      schema.object([
        schema.prop(
          "history_id",
          schema.string()
            |> schema.description(
              "The history entry ID returned by the atuin_history tool",
            ),
        ),
        schema.prop(
          "ranges",
          schema.array(
            schema.array(schema.integer())
            |> schema.min_items(2)
            |> schema.max_items(2),
          )
            |> schema.max_items(10)
            |> schema.description(
              "Array of [start, end] line ranges (0-based, inclusive, negative = from end). Default: [[0, 1000]]. Max 10 ranges per call.",
            ),
        )
          |> schema.optional,
      ]),
    ),
  )
}

pub fn execute_shell_command() -> ToolDefinition {
  ToolDefinition(
    name: "execute_shell_command",
    description: "Executes a shell command on the user's system and returns the output. Use this
to run commands that can provide information or context that helps you answer
the user's question or fulfill their request. Be cautious with this tool, as
it can have side effects on the user's system. Always prefer read-only commands
and avoid destructive actions unless absolutely necessary and you have high
confidence it's what the user wants.

Do not use this tool when another tool - like read_file or edit_file - would be
more appropriate, unless you have a good reason to do so.

IMPORTANT: do *NOT* use this tool if simply suggesting a command for the user
to run themselves would suffice. This tool should only be used when you need
to get information from the user's system that you can't get through other
tools, and that is necessary to answer the user's question or fulfill their
request OR the user has a preference for you to run commands directly:

- \"How do I find the largest file in this directory\" -> Suggest a command instead
- \"What is the largest file in this directory\" -> Answer the question using a tool call
",
    parameter_schema: JsonSchema(
      schema.object([
        schema.prop(
          "command",
          schema.string()
            |> schema.description(
              "The shell command to execute. Use this to get information from the user's system that can help you answer their question or fulfill their request. Be cautious and prefer read-only commands when possible.",
            ),
        ),
        schema.prop(
          "shell",
          schema.string()
            |> schema.enum_strings(["bash", "fish", "zsh", "nu"])
            |> schema.description("Which shell to use for execution"),
        ),
        schema.prop(
          "timeout",
          schema.integer()
            |> schema.minimum_int(1)
            |> schema.maximum_int(600)
            |> schema.description(
              "Maximum time in seconds to allow the command to run before cancelling it (default: 30, max: 600)",
            ),
        )
          |> schema.optional,
        schema.prop(
          "description",
          schema.string()
            |> schema.description(
              "Brief description of why you need to run this command or what information you're trying to get from it",
            ),
        ),
      ]),
    ),
  )
}
