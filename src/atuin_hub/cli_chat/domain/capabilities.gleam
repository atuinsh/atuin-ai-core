//// Structured representation of the client capabilities declared by the
//// Atuin CLI.
////
//// Capabilities tell the server which client-side tools the CLI is willing
//// and able to execute on behalf of the model. They're carried on the wire
//// as a raw list of strings (e.g. `"client_v1_read_file"`); this module is
//// the canonical typed form. Unknown or misspelled wire strings are dropped
//// at the boundary rather than silently mismatching later in the pipeline,
//// so newer servers tolerate older clients and vice versa.

import gleam/list
import gleam/string

pub type Capabilities {
  Capabilities(
    read_file: Bool,
    edit_file: Bool,
    write_file: Bool,
    execute_shell_command: Bool,
    atuin_history: Bool,
    atuin_output: Bool,
    invocations: Bool,
    load_skill: Bool,
  )
}

pub fn new() -> Capabilities {
  Capabilities(
    read_file: False,
    edit_file: False,
    write_file: False,
    execute_shell_command: False,
    atuin_history: False,
    atuin_output: False,
    invocations: False,
    load_skill: False,
  )
}

/// Builds a `Capabilities` from wire strings. Unknown entries are silently
/// dropped; surrounding whitespace is tolerated.
pub fn from_list(wire_strings: List(String)) -> Capabilities {
  list.fold(wire_strings, new(), enable)
}

// Wire-string -> field mapping. Add a case here when introducing a new
// capability on the CLI side; `to_list` below must list it too.
fn enable(caps: Capabilities, wire: String) -> Capabilities {
  case string.trim(wire) {
    "client_v1_read_file" -> Capabilities(..caps, read_file: True)
    "client_v1_edit_file" -> Capabilities(..caps, edit_file: True)
    "client_v1_write_file" -> Capabilities(..caps, write_file: True)
    "client_v1_execute_shell_command" ->
      Capabilities(..caps, execute_shell_command: True)
    "client_v1_atuin_history" -> Capabilities(..caps, atuin_history: True)
    "client_v1_atuin_output" -> Capabilities(..caps, atuin_output: True)
    "client_invocations" -> Capabilities(..caps, invocations: True)
    "client_v1_load_skill" -> Capabilities(..caps, load_skill: True)
    _unknown -> caps
  }
}

/// The wire strings for all enabled capabilities, sorted.
///
/// Useful for tracing and analytics: we want to record *what the server
/// saw* rather than the raw input, since unknown strings were dropped
/// during parsing.
pub fn to_list(caps: Capabilities) -> List(String) {
  // Already in sorted wire-string order.
  [
    #("client_invocations", caps.invocations),
    #("client_v1_atuin_history", caps.atuin_history),
    #("client_v1_atuin_output", caps.atuin_output),
    #("client_v1_edit_file", caps.edit_file),
    #("client_v1_execute_shell_command", caps.execute_shell_command),
    #("client_v1_load_skill", caps.load_skill),
    #("client_v1_read_file", caps.read_file),
    #("client_v1_write_file", caps.write_file),
  ]
  |> list.filter_map(fn(entry) {
    case entry.1 {
      True -> Ok(entry.0)
      False -> Error(Nil)
    }
  })
}

/// Whether a capability is enabled, looked up by wire string. Unknown
/// strings return `False`. Unlike `from_list`, the lookup is exact — no
/// whitespace trimming — matching the historical boundary behavior.
pub fn has(caps: Capabilities, wire: String) -> Bool {
  case wire {
    "client_v1_read_file" -> caps.read_file
    "client_v1_edit_file" -> caps.edit_file
    "client_v1_write_file" -> caps.write_file
    "client_v1_execute_shell_command" -> caps.execute_shell_command
    "client_v1_atuin_history" -> caps.atuin_history
    "client_v1_atuin_output" -> caps.atuin_output
    "client_invocations" -> caps.invocations
    "client_v1_load_skill" -> caps.load_skill
    _unknown -> False
  }
}

/// Unions two capability sets — enabled in either means enabled in the
/// result. Used to merge a nested `config.capabilities` list with the
/// legacy top-level `capabilities` list without either side "winning".
pub fn merge(a: Capabilities, b: Capabilities) -> Capabilities {
  Capabilities(
    read_file: a.read_file || b.read_file,
    edit_file: a.edit_file || b.edit_file,
    write_file: a.write_file || b.write_file,
    execute_shell_command: a.execute_shell_command || b.execute_shell_command,
    atuin_history: a.atuin_history || b.atuin_history,
    atuin_output: a.atuin_output || b.atuin_output,
    invocations: a.invocations || b.invocations,
    load_skill: a.load_skill || b.load_skill,
  )
}
