//// Fixture-driven tests for the OpenAI-compat SSE decoder.
////
//// Fixtures are real OpenRouter streams recorded by the
//// `openrouter_capture` dev harness (dream_http_client recordings with the
//// raw SSE chunk bytes preserved). Each test replays the recorded bytes
//// through the full pure pipeline:
////
////     bytes -> ssevents -> openai_compat/stream -> engine/stream
////
//// and asserts on the resulting provider StreamEvents.

import atuin_ai_core/domain/usage
import atuin_ai_core/engine/stream as engine_stream
import atuin_ai_core/llm/openai_compat/stream as sse_stream
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import ssevents

pub fn text_only_stream_test() {
  let events = replay_fixture("text_only")

  let assert Ok(engine_stream.StreamFinished(response, final_usage, False)) =
    list.last(events)
  assert response.tool_calls == []
  assert response.reasoning == None

  // The assembled response is exactly the concatenation of the deltas the
  // lifecycle would have forwarded to the client.
  let streamed_text =
    events
    |> list.filter_map(fn(event) {
      case event {
        engine_stream.TextDelta(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> string.concat
  assert streamed_text != ""
  assert response.text == streamed_text

  assert final_usage.output_tokens > 0
}

pub fn suggest_command_stream_test() {
  let events = replay_fixture("suggest_command")

  let assert Ok(engine_stream.StreamFinished(response, _usage, False)) =
    list.last(events)
  let assert [call] = response.tool_calls
  assert call.name == "suggest_command"

  // The start event surfaced mid-stream with the same identity the
  // finished call carries.
  assert list.contains(
    events,
    engine_stream.ToolCallStarted(id: call.id, name: call.name),
  )
}

pub fn parallel_tool_calls_stream_test() {
  let events = replay_fixture("parallel_tools")

  let assert Ok(engine_stream.StreamFinished(response, final_usage, False)) =
    list.last(events)

  // Two read_file calls with distinct ids, finished in stream order even
  // though the wire never sent an explicit per-call stop.
  let assert [first, second] = response.tool_calls
  assert first.name == "read_file"
  assert second.name == "read_file"
  assert first.id != second.id

  let assert [
    engine_stream.ToolCallFinished(finished_first),
    engine_stream.ToolCallFinished(finished_second),
  ] =
    list.filter(events, fn(event) {
      case event {
        engine_stream.ToolCallFinished(_) -> True
        _ -> False
      }
    })
  assert finished_first == first
  assert finished_second == second

  // The recorded usage chunk was normalized: prompt_tokens (3445) minus the
  // cache-write tokens (3442) leaves the uncached input, and OpenRouter's
  // exact cost survives as provider cost.
  assert final_usage.input_tokens == 3
  assert final_usage.cache_creation_tokens == 3442
  assert final_usage.output_tokens == 112
  let assert Some(_) = final_usage.provider_cost
}

pub fn non_byok_upstream_cost_is_not_double_counted_test() {
  let events = replay_fixture("non_byok_anthropic")

  let assert Ok(engine_stream.StreamFinished(_response, final_usage, False)) =
    list.last(events)

  // The recorded response was routed through OpenRouter's own key
  // (is_byok: false), so `cost_details.upstream_inference_cost` merely
  // mirrors `cost` (0.017565): the full charge lands in provider_cost and
  // nothing may be attributed to a separate provider bill.
  assert final_usage.provider_cost == Some(17_565)
  assert final_usage.upstream_cost == None
}

pub fn byok_upstream_cost_lands_in_upstream_test() {
  let events = replay_fixture("byok_deepseek")

  let assert Ok(engine_stream.StreamFinished(_response, final_usage, False)) =
    list.last(events)

  // BYOK-routed (is_byok: true): OpenRouter's own charge is just the fee
  // (zero on this account) and the real inference cost is billed directly
  // by the provider, so it lands in upstream_cost.
  assert final_usage.provider_cost == Some(0)
  assert final_usage.upstream_cost == Some(418)
}

pub fn byok_usage_chunk_decodes_fee_and_upstream_cost_test() {
  // Synthetic variant with a non-zero fee (the byok_deepseek fixture has
  // fee 0, which can't distinguish provider_cost from an accidental None).
  let assert [engine_stream.UsageChunk(report)] =
    decode_single(
      "{\"usage\": {\"prompt_tokens\": 100, \"completion_tokens\": 5,"
      <> " \"cost\": 0.0009, \"is_byok\": true,"
      <> " \"cost_details\": {\"upstream_inference_cost\": 0.018}}}",
    )

  assert report.cost == Some(0.0009)
  assert report.is_byok == Some(True)
  assert report.upstream_cost == Some(0.018)
}

pub fn heartbeat_comments_produce_no_events_test() {
  let decoder = sse_stream.new()
  let assert Ok(#(_state, items)) =
    ssevents.push(ssevents.new_decoder(), <<": OPENROUTER PROCESSING\n\n":utf8>>)

  let #(_decoder, events) =
    list.fold(items, #(decoder, []), fn(acc, item) {
      let #(decoder, events) = acc
      let #(decoder, new_events) = sse_stream.push(decoder, item)
      #(decoder, list.append(events, new_events))
    })

  assert events == []
}

pub fn error_chunk_maps_to_stream_failed_test() {
  assert decode_single(
      "{\"error\": {\"code\": 429, \"message\": \"slow down\"}}",
    )
    == [engine_stream.StreamFailed(engine_stream.RateLimited)]
  assert decode_single("{\"error\": {\"code\": 502, \"message\": \"bad\"}}")
    == [engine_stream.StreamFailed(engine_stream.Unavailable)]
  assert decode_single("{\"error\": {\"message\": \"nope\"}}")
    == [engine_stream.StreamFailed(engine_stream.GenerationFailed)]
}

pub fn malformed_chunk_maps_to_stream_failed_test() {
  assert decode_single("this is not json")
    == [engine_stream.StreamFailed(engine_stream.StreamProcessingFailed)]
}

// --- Fireworks wire-shape tolerances (payloads captured from a live
// dedicated-deployment stream) -----------------------------------------------

pub fn fireworks_usage_null_chunk_decodes_test() {
  // Fireworks sends an explicit `usage: null` on every non-final chunk.
  assert decode_single(
      "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":null,\"raw_output\":null}],\"usage\":null}",
    )
    == [engine_stream.TextChunk("hi")]
}

pub fn fireworks_reasoning_content_maps_to_reasoning_test() {
  assert decode_single(
      "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"The user\"},\"finish_reason\":null}],\"usage\":null}",
    )
    == [engine_stream.ReasoningChunk("The user")]
}

pub fn fireworks_final_usage_chunk_has_empty_choices_test() {
  let assert [engine_stream.UsageChunk(report)] =
    decode_single(
      "{\"choices\":[],\"usage\":{\"prompt_tokens\":284,\"total_tokens\":315,\"completion_tokens\":31,\"prompt_tokens_details\":{\"cached_tokens\":0}}}",
    )
  assert report.input_tokens == Some(284)
  assert report.output_tokens == Some(31)
}

// --- helpers ---------------------------------------------------------------

/// Runs a single data payload through a fresh decoder.
fn decode_single(payload: String) -> List(engine_stream.AdapterEvent) {
  let assert Ok(#(_state, items)) =
    ssevents.push(
      ssevents.new_decoder(),
      bit_array.from_string("data: " <> payload <> "\n\n"),
    )
  let #(_decoder, events) =
    list.fold(items, #(sse_stream.new(), []), fn(acc, item) {
      let #(decoder, events) = acc
      let #(decoder, new_events) = sse_stream.push(decoder, item)
      #(decoder, list.append(events, new_events))
    })
  events
}

type Replay {
  Replay(
    sse: ssevents.DecodeState,
    decoder: sse_stream.Decoder,
    fsm: engine_stream.StreamState,
    events: List(engine_stream.StreamEvent),
  )
}

/// Replays a recorded stream's chunk bytes through the full pipeline and
/// returns every StreamEvent the provider FSM emitted.
fn replay_fixture(scenario: String) -> List(engine_stream.StreamEvent) {
  let replay =
    Replay(
      sse: ssevents.new_decoder(),
      decoder: sse_stream.new(),
      fsm: engine_stream.new_stream(usage.Openrouter),
      events: [],
    )

  fixture_chunks(scenario)
  |> list.fold(replay, push_chunk)
  |> fn(replay) { replay.events }
}

fn push_chunk(replay: Replay, chunk: BitArray) -> Replay {
  let assert Ok(#(sse, items)) = ssevents.push(replay.sse, chunk)
  list.fold(items, Replay(..replay, sse:), push_item)
}

fn push_item(replay: Replay, item: ssevents.Item) -> Replay {
  let #(decoder, adapter_events) = sse_stream.push(replay.decoder, item)
  list.fold(
    adapter_events,
    Replay(..replay, decoder:),
    fn(replay, adapter_event) {
      let #(fsm, stream_events) =
        engine_stream.update(replay.fsm, adapter_event)
      Replay(..replay, fsm:, events: list.append(replay.events, stream_events))
    },
  )
}

/// Reads the raw SSE chunk bytes out of a dream_http_client recording.
/// Scenario directories may also hold a Fireworks-keyed copy of the
/// recording (for the controller tests' URL-matched playback); these
/// OpenRouter-pinned tests read the OpenRouter one.
fn fixture_chunks(scenario: String) -> List(BitArray) {
  let dir = "test/fixtures/openrouter/" <> scenario
  let assert Ok(files) = simplifile.read_directory(dir)
  let assert Ok(file) =
    list.find(files, string.starts_with(_, "POST_openrouter.ai"))
  let assert Ok(content) = simplifile.read(dir <> "/" <> file)
  let assert Ok(chunks) = json.parse(content, recording_chunks_decoder())
  list.map(chunks, bit_array.from_string)
}

fn recording_chunks_decoder() -> decode.Decoder(List(String)) {
  decode.at(
    ["entries"],
    decode.list(decode.at(
      ["response", "chunks"],
      decode.list(decode.at(["data"], decode.string)),
    )),
  )
  |> decode.map(list.flatten)
}
