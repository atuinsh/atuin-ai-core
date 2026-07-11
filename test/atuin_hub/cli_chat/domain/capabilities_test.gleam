import atuin_hub/cli_chat/domain/capabilities.{Capabilities}

pub fn from_list_enables_recognized_test() {
  let caps =
    capabilities.from_list(["client_v1_read_file", "client_v1_atuin_history"])
  assert caps.read_file
  assert caps.atuin_history
  assert !caps.execute_shell_command
  assert !caps.write_file
  assert !caps.invocations
}

pub fn from_list_drops_unknown_test() {
  let caps = capabilities.from_list(["client_v1_read_file", "bogus_capability"])
  assert caps == Capabilities(..capabilities.new(), read_file: True)
}

pub fn from_list_trims_whitespace_test() {
  let caps = capabilities.from_list(["  client_v1_read_file  "])
  assert caps.read_file
}

pub fn to_list_empty_for_all_false_test() {
  assert capabilities.to_list(capabilities.new()) == []
}

pub fn to_list_sorted_wire_strings_test() {
  let caps =
    capabilities.from_list(["client_v1_read_file", "client_v1_atuin_history"])
  assert capabilities.to_list(caps)
    == ["client_v1_atuin_history", "client_v1_read_file"]
}

pub fn roundtrip_test() {
  let input = [
    "client_invocations",
    "client_v1_atuin_history",
    "client_v1_atuin_output",
    "client_v1_edit_file",
    "client_v1_execute_shell_command",
    "client_v1_load_skill",
    "client_v1_read_file",
    "client_v1_write_file",
  ]
  assert capabilities.to_list(capabilities.from_list(input)) == input
}

pub fn has_by_wire_string_test() {
  let caps = capabilities.from_list(["client_v1_read_file"])
  assert capabilities.has(caps, "client_v1_read_file")
  assert !capabilities.has(caps, "client_v1_edit_file")
  assert !capabilities.has(caps, "unknown_thing")
}

pub fn merge_unions_test() {
  let a = capabilities.from_list(["client_v1_read_file"])
  let b = capabilities.from_list(["client_v1_edit_file"])
  let merged = capabilities.merge(a, b)
  assert merged.read_file
  assert merged.edit_file
  assert !merged.write_file
}
