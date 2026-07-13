//// Decodes OpenAI-compatible chat-completions SSE items into provider
//// `AdapterEvent`s for the stream-assembly FSM (`engine/stream`).
////
//// The decoder is stateful for one reason: OpenAI-compatible streams carry
//// no per-tool-call stop signal (unlike Anthropic's `content_block_stop`).
//// A tool call is only known to be complete when the stream reports a
//// `finish_reason` — so open tool-call indexes are tracked here and
//// `ToolCallStopChunk`s are synthesized at that point (and, defensively, at
//// `[DONE]` if no finish_reason ever arrived).
////
//// Wire behavior pinned by recorded fixtures (test/fixtures/openrouter/):
//// - Comment items (`: OPENROUTER PROCESSING` heartbeats) carry nothing.
//// - Each tool call's first fragment has `index`, `id`, and `function.name`
////   (with empty arguments); later fragments carry only `index` and an
////   `function.arguments` delta.
//// - `finish_reason` arrives on a chunk of its own, then again on a final
////   chunk that also carries `usage`, then `data: [DONE]`.
//// - Content deltas repeat `role`, and bookkeeping chunks carry
////   `content: ""`; empty strings are dropped.
////
//// Fireworks streams differ in three tolerated ways: every non-final
//// chunk carries an explicit `usage: null` (OpenRouter omits the key),
//// the final usage chunk has an empty `choices` array, and reasoning
//// deltas arrive as `reasoning_content` rather than `reasoning`.

import atuin_ai_core/domain/usage.{type UsageReport}
import atuin_ai_core/engine/stream.{type AdapterEvent} as engine_stream
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import ssevents/event.{type Item, CommentItem, EventItem}

pub opaque type Decoder {
  Decoder(open_tool_indexes: List(Int))
}

pub fn new() -> Decoder {
  Decoder(open_tool_indexes: [])
}

/// Feeds one SSE item through the decoder, returning provider events in
/// stream order.
pub fn push(decoder: Decoder, item: Item) -> #(Decoder, List(AdapterEvent)) {
  case item {
    CommentItem(_) -> #(decoder, [])
    EventItem(event) -> push_data(decoder, event.data_of(event))
  }
}

fn push_data(decoder: Decoder, data: String) -> #(Decoder, List(AdapterEvent)) {
  case string.trim(data) {
    "[DONE]" -> {
      let #(decoder, stops) = close_open_tools(decoder)
      #(decoder, list.append(stops, [engine_stream.StreamDone]))
    }
    payload ->
      case json.parse(payload, chunk_decoder()) {
        Ok(chunk) -> apply_chunk(decoder, chunk)
        Error(_) -> #(decoder, [
          engine_stream.StreamFailed(engine_stream.StreamProcessingFailed),
        ])
      }
  }
}

type Chunk {
  Chunk(
    error: Option(ChunkError),
    delta: Delta,
    finish_reason: Option(String),
    usage: Option(UsageReport),
  )
}

type ChunkError {
  ChunkError(code: Option(Int))
}

type Delta {
  Delta(
    content: Option(String),
    reasoning: Option(String),
    tool_calls: List(ToolCallDelta),
  )
}

type ToolCallDelta {
  ToolCallDelta(
    index: Int,
    id: Option(String),
    name: Option(String),
    arguments: Option(String),
  )
}

fn apply_chunk(
  decoder: Decoder,
  chunk: Chunk,
) -> #(Decoder, List(AdapterEvent)) {
  case chunk.error {
    Some(error) -> #(decoder, [engine_stream.StreamFailed(map_error(error))])
    None -> {
      let text_events =
        [
          chunk.delta.reasoning |> option.map(engine_stream.ReasoningChunk),
          chunk.delta.content |> option.map(engine_stream.TextChunk),
        ]
        |> option.values

      let #(decoder, tool_events) =
        list.fold(chunk.delta.tool_calls, #(decoder, []), apply_tool_delta)

      let #(decoder, stop_events) = case chunk.finish_reason {
        Some(_) -> close_open_tools(decoder)
        None -> #(decoder, [])
      }

      let usage_events = case chunk.usage {
        Some(report) -> [engine_stream.UsageChunk(report)]
        None -> []
      }

      #(
        decoder,
        list.flatten([text_events, tool_events, stop_events, usage_events]),
      )
    }
  }
}

fn apply_tool_delta(
  acc: #(Decoder, List(AdapterEvent)),
  delta: ToolCallDelta,
) -> #(Decoder, List(AdapterEvent)) {
  let #(decoder, events) = acc

  let #(decoder, start_events) = case delta.id, delta.name {
    Some(id), Some(name) -> #(
      Decoder(open_tool_indexes: [delta.index, ..decoder.open_tool_indexes]),
      [engine_stream.ToolCallStartChunk(index: delta.index, id:, name:)],
    )
    _, _ -> #(decoder, [])
  }

  let input_events = case delta.arguments {
    Some("") | None -> []
    Some(arguments) -> [
      engine_stream.ToolCallInputChunk(index: delta.index, delta: arguments),
    ]
  }

  #(decoder, list.flatten([events, start_events, input_events]))
}

fn close_open_tools(decoder: Decoder) -> #(Decoder, List(AdapterEvent)) {
  let stops =
    decoder.open_tool_indexes
    |> list.sort(int.compare)
    |> list.map(engine_stream.ToolCallStopChunk)

  #(Decoder(open_tool_indexes: []), stops)
}

fn map_error(error: ChunkError) -> engine_stream.ProviderError {
  case error.code {
    Some(429) -> engine_stream.RateLimited
    Some(code) if code >= 500 -> engine_stream.Unavailable
    _ -> engine_stream.GenerationFailed
  }
}

fn chunk_decoder() -> decode.Decoder(Chunk) {
  use error <- decode.optional_field(
    "error",
    None,
    error_decoder() |> decode.map(Some),
  )
  use choices <- decode.optional_field(
    "choices",
    [],
    decode.list(choice_decoder()),
  )
  // `decode.optional` because Fireworks sends `usage: null` on every
  // non-final chunk; a bare usage_decoder would fail the whole chunk.
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder()),
  )

  let #(delta, finish_reason) = case choices {
    [choice, ..] -> choice
    [] -> #(empty_delta(), None)
  }

  decode.success(Chunk(error:, delta:, finish_reason:, usage:))
}

fn error_decoder() -> decode.Decoder(ChunkError) {
  use code <- decode.optional_field("code", None, lenient_code_decoder())
  decode.success(ChunkError(code:))
}

/// The error code is documented as a number but arrives as a string from
/// some upstreams; anything unrecognizable degrades to None rather than
/// failing the whole chunk (a failed decode would mask the error itself).
fn lenient_code_decoder() -> decode.Decoder(Option(Int)) {
  decode.one_of(decode.int |> decode.map(Some), or: [
    decode.string |> decode.map(fn(raw) { option.from_result(int.parse(raw)) }),
    decode.success(None),
  ])
}

fn choice_decoder() -> decode.Decoder(#(Delta, Option(String))) {
  use delta <- decode.optional_field("delta", empty_delta(), delta_decoder())
  use finish_reason <- decode.optional_field(
    "finish_reason",
    None,
    decode.optional(decode.string),
  )
  decode.success(#(delta, finish_reason))
}

fn empty_delta() -> Delta {
  Delta(content: None, reasoning: None, tool_calls: [])
}

fn delta_decoder() -> decode.Decoder(Delta) {
  use content <- decode.optional_field("content", None, maybe_text_decoder())
  use reasoning <- decode.optional_field(
    "reasoning",
    None,
    maybe_text_decoder(),
  )
  // Fireworks' spelling of the reasoning delta.
  use reasoning_content <- decode.optional_field(
    "reasoning_content",
    None,
    maybe_text_decoder(),
  )
  use tool_calls <- decode.optional_field(
    "tool_calls",
    [],
    decode.list(tool_call_delta_decoder()),
  )
  decode.success(Delta(
    content:,
    reasoning: option.or(reasoning, reasoning_content),
    tool_calls:,
  ))
}

/// Text fields may be null or "" on bookkeeping chunks (role announcements,
/// finish chunks); both decode to None so they never become delta events.
fn maybe_text_decoder() -> decode.Decoder(Option(String)) {
  decode.optional(decode.string)
  |> decode.map(fn(text) {
    case text {
      Some("") -> None
      other -> other
    }
  })
}

fn tool_call_delta_decoder() -> decode.Decoder(ToolCallDelta) {
  use index <- decode.optional_field("index", 0, decode.int)
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use #(name, arguments) <- decode.optional_field(
    "function",
    #(None, None),
    function_decoder(),
  )
  decode.success(ToolCallDelta(index:, id:, name:, arguments:))
}

fn function_decoder() -> decode.Decoder(#(Option(String), Option(String))) {
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use arguments <- decode.optional_field(
    "arguments",
    None,
    decode.optional(decode.string),
  )
  decode.success(#(name, arguments))
}

fn usage_decoder() -> decode.Decoder(UsageReport) {
  use input_tokens <- decode.optional_field(
    "prompt_tokens",
    None,
    decode.optional(decode.int),
  )
  use output_tokens <- decode.optional_field(
    "completion_tokens",
    None,
    decode.optional(decode.int),
  )
  use #(cached_tokens, cache_creation_tokens) <- decode.optional_field(
    "prompt_tokens_details",
    #(None, None),
    prompt_tokens_details_decoder(),
  )
  use cost <- decode.optional_field(
    "cost",
    None,
    decode.optional(lenient_float_decoder()),
  )
  use is_byok <- decode.optional_field(
    "is_byok",
    None,
    decode.optional(decode.bool),
  )
  use upstream_cost <- decode.optional_field(
    "cost_details",
    None,
    cost_details_decoder(),
  )

  decode.success(usage.UsageReport(
    input_tokens:,
    output_tokens:,
    cached_tokens:,
    cache_read_input_tokens: None,
    cache_creation_tokens:,
    cache_creation_input_tokens: None,
    // OpenAI-style prompt_tokens are inclusive of cached tokens; stating it
    // here means usage.extract doesn't fall back on provider heuristics.
    input_includes_cached: Some(True),
    input_cost: None,
    output_cost: None,
    total_cost: None,
    cost:,
    is_byok:,
    upstream_cost:,
    present: True,
  ))
}

fn cost_details_decoder() -> decode.Decoder(Option(Float)) {
  use upstream <- decode.optional_field(
    "upstream_inference_cost",
    None,
    decode.optional(lenient_float_decoder()),
  )
  decode.success(upstream)
}

fn prompt_tokens_details_decoder() -> decode.Decoder(
  #(Option(Int), Option(Int)),
) {
  use cached <- decode.optional_field(
    "cached_tokens",
    None,
    decode.optional(decode.int),
  )
  use cache_write <- decode.optional_field(
    "cache_write_tokens",
    None,
    decode.optional(decode.int),
  )
  decode.success(#(cached, cache_write))
}

/// OpenRouter's cost is a JSON number that may serialize without a decimal
/// point; accept both.
fn lenient_float_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}
