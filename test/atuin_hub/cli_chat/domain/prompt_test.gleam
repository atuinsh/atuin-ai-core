import atuin_hub/cli_chat/domain/config
import atuin_hub/cli_chat/domain/prompt
import gleam/option.{None, Some}
import gleam/string

fn prompt_for_version(version: option.Option(String)) -> String {
  prompt.build_system_prompt(
    prompt.empty_context(),
    config.Config(..config.default(), app_version: version),
    prompt.Host(dev_mode: False, safety_prompt: ""),
  )
}

pub fn pty_proxy_included_at_supporting_version_test() {
  assert string.contains(prompt_for_version(Some("18.17.0")), "atuin pty-proxy")
  assert string.contains(prompt_for_version(Some("19.0.1")), "atuin pty-proxy")
}

pub fn pty_proxy_omitted_below_supporting_version_test() {
  assert !string.contains(prompt_for_version(Some("18.16.2")), "pty-proxy")
}

pub fn pty_proxy_omitted_for_unknown_or_invalid_version_test() {
  assert !string.contains(prompt_for_version(None), "pty-proxy")
  assert !string.contains(prompt_for_version(Some("banana")), "pty-proxy")
}
