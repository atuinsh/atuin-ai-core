import atuin_hub/cli_chat/domain/capabilities
import atuin_hub/cli_chat/domain/tools
import atuin_hub/cli_chat/engine/turn
import atuin_hub/cli_chat/http/limits
import atuin_hub/cli_chat/instance.{CapabilityBinding, StoredToolResult}
import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import support/catalogs

/// A backend that can't serve anything — the tests here never reach an
/// LLM call.
fn no_backend(_model_id: String, _session_id: String) {
  None
}

fn stateless() -> instance.Instance {
  instance.new(catalogs.catalog(), no_backend)
}

fn tool_names(
  inst: instance.Instance,
  caps: capabilities.Capabilities,
) -> List(String) {
  instance.tool_list(inst, caps)
  |> list.map(fn(definition) { definition.name })
}

// ---------------------------------------------------------------------
// Stateless defaults
// ---------------------------------------------------------------------

pub fn default_instance_has_no_server_tools_test() {
  let inst = stateless()
  assert tool_names(inst, capabilities.new()) == ["suggest_command"]
  assert !instance.is_server_tool(inst, "web_search")
}

pub fn default_limiter_admits_everyone_test() {
  let inst = stateless()
  assert inst.limiter.check("someone") == Ok(limits.User("someone"))
  assert inst.limiter.credits(limits.User("someone")) == None
}

pub fn default_tool_result_store_declines_test() {
  let inst = stateless()
  let stored =
    StoredToolResult(
      user_id: "someone",
      tool_use_id: "tu_1",
      tool_name: "web_search",
      content: "results",
      is_error: False,
    )
  // A failed store means the result streams inline to the client.
  assert inst.tool_results.store(stored) == Error(Nil)
  assert inst.tool_results.fetch("someone", "tu_1") == None
}

// ---------------------------------------------------------------------
// Capability bindings
// ---------------------------------------------------------------------

pub fn standard_bindings_match_client_tools_test() {
  // The registration-driven tool list must reproduce the compiled-in
  // gating exactly — same tools, same prompt-cache order — for every
  // capability combination. All-on covers the ordering.
  let all_caps =
    capabilities.from_list([
      "client_v1_read_file", "client_v1_edit_file", "client_v1_write_file",
      "client_v1_execute_shell_command", "client_v1_atuin_history",
      "client_v1_atuin_output", "client_v1_load_skill",
    ])

  let from_bindings =
    instance.tool_list(stateless(), all_caps)
    |> list.filter(fn(definition) { definition.name != "suggest_command" })

  assert from_bindings == tools.client_tools(all_caps)
}

pub fn capability_gating_test() {
  let caps = capabilities.from_list(["client_v1_read_file"])
  assert tool_names(stateless(), caps) == ["suggest_command", "read_file"]
}

pub fn capability_prompt_sections_test() {
  let inst =
    stateless()
    |> instance.with_capability(CapabilityBinding(
      capability: "client_v1_read_file",
      tool: tools.read_file(),
      prompt_section: Some("Reading files: prefer small ranges."),
    ))

  let sections =
    instance.capability_prompt_sections(
      inst,
      capabilities.from_list(["client_v1_read_file"]),
    )
  assert sections == ["Reading files: prefer small ranges."]

  assert instance.capability_prompt_sections(inst, capabilities.new()) == []
}

// ---------------------------------------------------------------------
// Server tools
// ---------------------------------------------------------------------

fn echo_tool() -> tools.ToolDefinition {
  tools.ToolDefinition(
    name: "echo",
    description: "Echoes.",
    parameter_schema: tools.suggest_command().parameter_schema,
  )
}

pub fn server_tools_precede_client_tools_test() {
  let inst =
    stateless()
    |> instance.with_server_tool(echo_tool(), fn(_) { Ok("echoed") })

  let caps = capabilities.from_list(["client_v1_read_file"])
  assert tool_names(inst, caps) == ["suggest_command", "echo", "read_file"]
  assert instance.is_server_tool(inst, "echo")
  assert !instance.is_server_tool(inst, "read_file")
}

pub fn execute_server_tool_test() {
  let inst =
    stateless()
    |> instance.with_server_tool(echo_tool(), fn(_) { Ok("echoed") })

  let call = turn.ToolCall(id: "tu_1", name: "echo", input: dynamic.nil())
  let result = instance.execute_server_tool(inst, call)
  assert result
    == turn.ToolResult(
      id: "tu_1",
      name: "echo",
      result: "echoed",
      is_error: False,
    )
}

pub fn execute_server_tool_error_becomes_error_result_test() {
  let inst =
    stateless()
    |> instance.with_server_tool(echo_tool(), fn(_) { Error("no upstream") })

  let call = turn.ToolCall(id: "tu_1", name: "echo", input: dynamic.nil())
  assert instance.execute_server_tool(inst, call).is_error
}

pub fn execute_unknown_tool_is_error_result_test() {
  let call = turn.ToolCall(id: "tu_1", name: "mystery", input: dynamic.nil())
  let result = instance.execute_server_tool(stateless(), call)
  assert result.is_error
  assert result.result == "Unknown tool: mystery"
}
