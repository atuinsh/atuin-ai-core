import atuin_hub/cli_chat/domain/capabilities
import atuin_hub/cli_chat/domain/tools
import gleam/list

pub fn no_capabilities_means_no_client_tools_test() {
  assert tools.client_tools(capabilities.new()) == []
}

pub fn each_capability_gates_its_tool_test() {
  let cases = [
    #("client_v1_read_file", "read_file"),
    #("client_v1_edit_file", "edit_file"),
    #("client_v1_write_file", "write_file"),
    #("client_v1_atuin_history", "atuin_history"),
    #("client_v1_atuin_output", "atuin_output"),
    #("client_v1_execute_shell_command", "execute_shell_command"),
    #("client_v1_load_skill", "load_skill"),
  ]

  list.each(cases, fn(pair) {
    let #(capability, tool_name) = pair
    let assert [definition] =
      tools.client_tools(capabilities.from_list([capability]))
    assert definition.name == tool_name
  })
}

pub fn client_tools_keep_stable_order_test() {
  // Tool order is part of the cached prompt prefix; reordering would
  // invalidate prompt caches.
  let caps =
    capabilities.from_list([
      "client_v1_execute_shell_command",
      "client_v1_read_file",
      "client_v1_atuin_history",
    ])

  assert list.map(tools.client_tools(caps), fn(definition) { definition.name })
    == ["read_file", "atuin_history", "execute_shell_command"]
}
