import atuin_hub/cli_chat/domain/upgrades
import gleam/list
import gleam/option.{None, Some}
import gleam/order.{Eq, Gt, Lt}
import gleam/string

pub fn unknown_version_returns_all_test() {
  let all = upgrades.upgrades_since(None)
  assert list.length(all) == 3
}

pub fn old_version_returns_newer_upgrades_test() {
  let since = upgrades.upgrades_since(Some("18.14.0"))
  assert list.length(since) == 2
  let assert [first, ..] = since
  assert string.starts_with(first, "- v18.15.0\n")
}

pub fn current_version_returns_none_test() {
  assert upgrades.upgrades_since(Some("18.16.0")) == []
  assert upgrades.upgrades_since(Some("19.0.0")) == []
}

pub fn invalid_version_returns_none_test() {
  assert upgrades.upgrades_since(Some("not-a-version")) == []
  assert upgrades.upgrades_since(Some("18.14")) == []
}

pub fn format_indents_description_test() {
  let assert [first, ..] = upgrades.upgrades_since(Some("18.15.0"))
  // "- v<version>\n" then every description line indented two spaces
  let assert ["- v18.16.0", ..lines] = string.split(first, "\n")
  assert lines
    |> list.filter(fn(line) { line != "" })
    |> list.all(string.starts_with(_, "  "))
}

pub fn prerelease_of_table_version_still_gets_upgrade_test() {
  // 18.16.0-beta.1 < 18.16.0, so the 18.16.0 upgrade note is included
  let since = upgrades.upgrades_since(Some("18.16.0-beta.1"))
  assert list.length(since) == 1
}

pub fn semver_compare_test() {
  let assert Ok(a) = upgrades.parse("1.2.3")
  let assert Ok(b) = upgrades.parse("1.2.4")
  let assert Ok(pre) = upgrades.parse("1.2.4-rc.1")
  assert upgrades.compare(a, b) == Lt
  assert upgrades.compare(b, a) == Gt
  assert upgrades.compare(a, a) == Eq
  assert upgrades.compare(pre, b) == Lt
  assert upgrades.compare(b, pre) == Gt
}
