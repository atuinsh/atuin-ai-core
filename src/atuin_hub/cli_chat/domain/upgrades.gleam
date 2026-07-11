//// Client-upgrade nudges for the system prompt: each entry describes a
//// CLI capability added in a given version, so the model can recommend
//// upgrading when a user on an older client asks for something their
//// version can't do.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/string

fn upgrades() -> List(#(String, String)) {
  [
    #(
      "18.14.0",
      "Added the ability for Atuin AI to search the user's Atuin history directly, rather than by suggesting a command.\nRecommend upgrading if the user asks you about their command history and having direct access would help you fulfill the request.",
    ),
    #(
      "18.15.0",
      "Added the ability for users to resume prior conversations, and automatically resumes within a timeframe, allowing natural followups to prior invocations of the app.\nRecommend upgrading if the user asks you something like \"What did we talk about last time?\" or \"Please continue\" or \"What's next?\" or similar.",
    ),
    #(
      "18.16.0",
      "Added the ability for Atuin AI to read, write, and edit files, as well as execute commands with user approval.\nThis allows Atuin AI to perform a much wider range of tasks, like \"Edit my .bashrc to add a new alias\" or \"Create a Python script that prints the current date and time every minute\".",
    ),
  ]
}

/// Formatted upgrade notes for everything newer than the client's version.
/// `None` (client version unknown) returns all of them; an unparseable
/// version returns none.
pub fn upgrades_since(version: Option(String)) -> List(String) {
  case version {
    None -> list.map(upgrades(), format_upgrade)
    Some(raw) ->
      case parse(raw) {
        Error(Nil) -> []
        Ok(client) ->
          upgrades()
          |> list.filter(fn(upgrade) {
            case parse(upgrade.0) {
              Ok(upgrade_version) -> compare(upgrade_version, client) == Gt
              Error(Nil) -> False
            }
          })
          |> list.map(format_upgrade)
      }
  }
}

pub type Semver {
  Semver(major: Int, minor: Int, patch: Int, prerelease: Option(String))
}

/// Parses a `major.minor.patch[-prerelease][+build]` version string. All
/// three numeric parts are required, matching Elixir's `Version.parse/1`.
pub fn parse(version: String) -> Result(Semver, Nil) {
  let version = case string.split_once(version, "+") {
    Ok(#(core, _build_metadata)) -> core
    Error(Nil) -> version
  }

  let #(core, prerelease) = case string.split_once(version, "-") {
    Ok(#(core, pre)) -> #(core, Some(pre))
    Error(Nil) -> #(version, None)
  }

  case string.split(core, ".") {
    [major, minor, patch] ->
      case int.parse(major), int.parse(minor), int.parse(patch) {
        Ok(major), Ok(minor), Ok(patch) ->
          Ok(Semver(major:, minor:, patch:, prerelease:))
        _, _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

pub fn compare(a: Semver, b: Semver) -> Order {
  int.compare(a.major, b.major)
  |> order.lazy_break_tie(fn() { int.compare(a.minor, b.minor) })
  |> order.lazy_break_tie(fn() { int.compare(a.patch, b.patch) })
  |> order.lazy_break_tie(fn() {
    compare_prerelease(a.prerelease, b.prerelease)
  })
}

// Semver rule: a release outranks any prerelease of the same version.
fn compare_prerelease(a: Option(String), b: Option(String)) -> Order {
  case a, b {
    None, None -> Eq
    None, Some(_) -> Gt
    Some(_), None -> Lt
    Some(a), Some(b) ->
      compare_identifiers(string.split(a, "."), string.split(b, "."))
  }
}

// Semver prerelease comparison: identifier by identifier, numeric
// identifiers compare numerically and rank below alphanumeric ones, and a
// shorter identifier list ranks below a longer one it prefixes.
fn compare_identifiers(a: List(String), b: List(String)) -> Order {
  case a, b {
    [], [] -> Eq
    [], _ -> Lt
    _, [] -> Gt
    [x, ..rest_a], [y, ..rest_b] ->
      compare_identifier(x, y)
      |> order.lazy_break_tie(fn() { compare_identifiers(rest_a, rest_b) })
  }
}

fn compare_identifier(x: String, y: String) -> Order {
  case int.parse(x), int.parse(y) {
    Ok(x), Ok(y) -> int.compare(x, y)
    Ok(_), Error(_) -> Lt
    Error(_), Ok(_) -> Gt
    Error(_), Error(_) -> string.compare(x, y)
  }
}

fn format_upgrade(upgrade: #(String, String)) -> String {
  "- v" <> upgrade.0 <> "\n" <> indent_lines(upgrade.1) <> "\n"
}

fn indent_lines(text: String) -> String {
  text
  |> string.trim
  |> string.split("\n")
  |> list.map(fn(line) { "  " <> line })
  |> string.join("\n")
  |> trim_trailing("  \n")
}

// Repeatedly strips a trailing occurrence of `suffix`, mirroring Elixir's
// String.trim_trailing/2 (defensive against descriptions whose final line
// is blank, which would otherwise leave dangling indentation).
fn trim_trailing(text: String, suffix: String) -> String {
  case string.ends_with(text, suffix) {
    True ->
      text
      |> string.drop_end(string.length(suffix))
      |> trim_trailing(suffix)
    False -> text
  }
}
