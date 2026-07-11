//// Dev harness: captures real OpenRouter SSE streams as dream_http_client
//// recordings, for use as decoder fixtures.
////
//// Run from gleam_cli_chat/ with OPENROUTER_API_KEY set:
////
////     gleam run -m openrouter_capture
////
//// Recordings land in test/fixtures/openrouter/<scenario>/. They contain the
//// full request, INCLUDING the authorization header — scrub it before
//// committing.

import atuin_hub/cli_chat/domain/capabilities
import atuin_hub/cli_chat/domain/tools
import atuin_hub/cli_chat/domain/tools/web_scrape
import atuin_hub/cli_chat/domain/tools/web_search
import atuin_hub/cli_chat/http/request
import atuin_hub/cli_chat/llm/client as chat
import atuin_hub/cli_chat/llm/openrouter
import dream_http_client/client as dream
import dream_http_client/matching
import dream_http_client/recorder
import envoy
import gleam/io
import gleam/list
import gleam/option.{None, Some}

pub fn main() {
  let assert Ok(api_key) = envoy.get("OPENROUTER_API_KEY")

  capture(
    api_key,
    "text_only",
    "Reply with one short sentence of greeting. Do not use any tools.",
    provider_options: None,
  )
  capture(
    api_key,
    "suggest_command",
    "Use the suggest_command tool to suggest a shell command that lists all"
      <> " files in the current directory, including hidden ones.",
    provider_options: None,
  )
  capture(
    api_key,
    "parallel_tools",
    "Use the read_file tool to read ./alpha.txt and ./beta.txt. Issue both"
      <> " tool calls in parallel, in this single response.",
    provider_options: None,
  )
  capture(
    api_key,
    "web_search_call",
    "Use the web_search tool to search for \"gleam language actors\"."
      <> " Call the tool immediately, without any preamble text.",
    provider_options: None,
  )
  // Whether a request routes through BYOK depends on the OpenRouter
  // account's per-provider key configuration (currently proportional for
  // Anthropic, always-on for DeepSeek), so these two scenarios pin both
  // shapes of the usage chunk. Note `cost_details` appears on *non-BYOK*
  // responses too, where `upstream_inference_cost` just mirrors `cost` —
  // `is_byok` is the discriminator.
  capture_with_model(
    api_key,
    "non_byok_anthropic",
    "Reply with one short sentence of greeting. Do not use any tools.",
    model: "anthropic/claude-opus-4.6",
    provider_options: Some(openrouter.ProviderOptions(
      order: None,
      allow_fallbacks: None,
      require_parameters: None,
      data_collection: None,
      zero_data_retention: None,
      enforce_distillable: None,
      only: Some(["anthropic"]),
      ignore: None,
    )),
  )
  // BYOK-routed: `cost` is only OpenRouter's fee (currently zero on this
  // account) and the real charge is `cost_details.upstream_inference_cost`,
  // billed directly by the provider.
  capture_with_model(
    api_key,
    "byok_deepseek",
    "Reply with one short sentence of greeting. Do not use any tools.",
    model: "deepseek/deepseek-v4-flash",
    provider_options: None,
  )
}

fn capture(
  api_key: String,
  scenario: String,
  prompt: String,
  provider_options provider_options: option.Option(openrouter.ProviderOptions),
) -> Nil {
  capture_with_model(
    api_key,
    scenario,
    prompt,
    model: "anthropic/claude-sonnet-4.6",
    provider_options:,
  )
}

fn capture_with_model(
  api_key: String,
  scenario: String,
  prompt: String,
  model model: String,
  provider_options provider_options: option.Option(openrouter.ProviderOptions),
) -> Nil {
  io.println("== capturing " <> scenario)

  let assert Ok(rec) =
    recorder.start(
      recorder.Record(directory: "test/fixtures/openrouter/" <> scenario),
      matching.match_url_only(),
    )

  let options =
    openrouter.OpenRouterOptions(
      api_key:,
      model:,
      session_id: Some("fixture-capture"),
      referer: Some("https://atuin.sh"),
      title: Some("Atuin AI"),
      anthropic_betas: [],
      model_options: None,
      provider_options:,
      cache_points: [-1],
    )

  let caps =
    capabilities.Capabilities(
      read_file: True,
      edit_file: True,
      write_file: True,
      execute_shell_command: True,
      atuin_history: True,
      atuin_output: True,
      invocations: False,
      load_skill: True,
    )
  let tool_list =
    list.append(
      [
        tools.suggest_command(),
        web_search.web_search(),
        web_scrape.web_scrape(),
      ],
      tools.client_tools(caps),
    )

  let req =
    chat.ClientRequest(
      inner: dream.new |> dream.recorder(rec),
      // No system/turn-context: fixtures pin the streaming wire format,
      // which the request framing doesn't affect.
      system: option.None,
      messages: [
        request.Message(role: request.User, content: request.Text(prompt)),
      ],
      turn_context: option.None,
      tools: Some(tool_list),
    )
  let req = openrouter.prepare_request(options, req)

  let stream_result =
    req.inner
    |> dream.on_stream_chunk(fn(_data) { io.print(".") })
    |> dream.on_stream_end(fn(_headers) { io.println(" end") })
    |> dream.on_stream_error(fn(reason) {
      io.println_error("stream error: " <> reason)
    })
    |> dream.start_stream

  case stream_result {
    Ok(stream) -> {
      dream.await_stream(stream)
      let _ = recorder.stop(rec)
      Nil
    }
    Error(reason) -> io.println_error("failed to start stream: " <> reason)
  }
}
