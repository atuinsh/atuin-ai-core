//// Provider adapter contracts and stream assembly for CLI chat.
////
//// Provider adapters are allowed to be provider-specific at the HTTP and wire
//// parsing layer. They should not pretend every model API is the same. The
//// seam into the CLI chat lifecycle is this module's fine-grained event
//// vocabulary: enough normalization for the lifecycle FSM to react to text,
//// tool calls, usage, and failures as they happen, without collapsing the
//// stream into a completed assistant message too early.

import atuin_ai_core/domain/usage
import atuin_ai_core/engine/turn
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Provider-adapter output. Adapters parse their native wire stream and feed
/// these facts into the provider stream FSM.
pub type AdapterEvent {
  TextChunk(text: String)
  ToolCallStartChunk(index: Int, id: String, name: String)
  ToolCallInputChunk(index: Int, delta: String)
  ToolCallStopChunk(index: Int)
  UsageChunk(usage.UsageReport)
  ReasoningChunk(text: String)
  StreamDone
  StreamFailed(ProviderError)
}

pub type ProviderError {
  RateLimited
  Unavailable
  GenerationFailed
  StreamProcessingFailed
  StreamCrashed
  /// The HTTP transport failed before or during the stream — a non-2xx
  /// response, a connect failure, or an inactivity cutoff. `detail` is
  /// operator/user-facing (e.g. "HTTP 404 Not Found: model ... not
  /// found") and rides into the error event and the recorded failure.
  TransportFailed(detail: String)
  InvalidToolInput(tool_id: String, input_json: String)
}

/// Fine-grained provider stream events consumed by the CLI chat lifecycle.
pub type StreamEvent {
  TextDelta(text: String)
  ToolCallStarted(id: String, name: String)
  ToolCallInputDelta(id: String, delta: String)
  ToolCallFinished(call: turn.ToolCall)
  ReasoningDelta(text: String)
  UsageReported(usage: usage.Usage)
  StreamFinished(
    response: turn.LlmResponse,
    usage: usage.Usage,
    no_usage_data: Bool,
  )
  StreamFailedEvent(error: ProviderError, partial_usage: Option(usage.Usage))
}

type ToolAssembly {
  ToolAssembly(index: Int, id: String, name: String, input_json: String)
}

pub opaque type StreamState {
  StreamState(
    provider: usage.Provider,
    text: Option(String),
    reasoning: Option(String),
    in_progress: List(ToolAssembly),
    completed: List(turn.ToolCall),
    usage_report: usage.UsageReport,
    finished: Bool,
  )
}

pub fn new_stream(provider: usage.Provider) -> StreamState {
  StreamState(
    provider: provider,
    text: None,
    reasoning: None,
    in_progress: [],
    completed: [],
    usage_report: usage.empty_report(),
    finished: False,
  )
}

pub fn update(
  state: StreamState,
  event: AdapterEvent,
) -> #(StreamState, List(StreamEvent)) {
  case state.finished {
    True -> #(state, [])
    False -> do_update(state, event)
  }
}

fn do_update(
  state: StreamState,
  event: AdapterEvent,
) -> #(StreamState, List(StreamEvent)) {
  case event {
    TextChunk(text) -> {
      let state = StreamState(..state, text: append_text(state.text, text))
      #(state, [TextDelta(text)])
    }

    ToolCallStartChunk(index, id, name) -> {
      let tool = ToolAssembly(index:, id:, name:, input_json: "")
      let state = StreamState(..state, in_progress: [tool, ..state.in_progress])
      #(state, [ToolCallStarted(id:, name:)])
    }

    ToolCallInputChunk(index, delta) -> {
      let id = tool_id(state.in_progress, index)
      let state =
        StreamState(
          ..state,
          in_progress: append_tool_input(state.in_progress, index, delta),
        )
      #(state, [ToolCallInputDelta(id:, delta:)])
    }

    ToolCallStopChunk(index) -> finish_tool_call(state, index)

    UsageChunk(report) -> {
      let usage.Extracted(usage: normalized, no_usage_data: _) =
        usage.extract(
          report,
          usage.empty_report(),
          usage.empty_report(),
          state.provider,
        )
      let state = StreamState(..state, usage_report: report)
      #(state, [UsageReported(normalized)])
    }

    ReasoningChunk(text) -> {
      let state =
        StreamState(..state, reasoning: append_text(state.reasoning, text))
      #(state, [ReasoningDelta(text)])
    }

    StreamDone -> finish_stream(state)

    StreamFailed(error) -> {
      let state = StreamState(..state, finished: True)
      let partial = usage.extract_partial(state.usage_report, state.provider)
      #(state, [StreamFailedEvent(error:, partial_usage: partial)])
    }
  }
}

fn finish_tool_call(
  state: StreamState,
  index: Int,
) -> #(StreamState, List(StreamEvent)) {
  case take_tool(state.in_progress, index) {
    Error(Nil) -> {
      let state = StreamState(..state, finished: True)
      #(state, [
        StreamFailedEvent(
          error: StreamProcessingFailed,
          partial_usage: usage.extract_partial(
            state.usage_report,
            state.provider,
          ),
        ),
      ])
    }

    Ok(#(tool, remaining)) ->
      case decode_tool_input(tool.input_json) {
        Error(Nil) -> {
          let state =
            StreamState(..state, in_progress: remaining, finished: True)
          #(state, [
            StreamFailedEvent(
              error: InvalidToolInput(tool.id, tool.input_json),
              partial_usage: usage.extract_partial(
                state.usage_report,
                state.provider,
              ),
            ),
          ])
        }

        Ok(input) -> {
          let call = turn.ToolCall(id: tool.id, name: tool.name, input: input)
          let state =
            StreamState(..state, in_progress: remaining, completed: [
              call,
              ..state.completed
            ])
          #(state, [ToolCallFinished(call:)])
        }
      }
  }
}

fn finish_stream(state: StreamState) -> #(StreamState, List(StreamEvent)) {
  let usage.Extracted(usage: normalized, no_usage_data:) =
    usage.extract(
      state.usage_report,
      usage.empty_report(),
      usage.empty_report(),
      state.provider,
    )

  let response =
    turn.LlmResponse(
      reasoning: non_blank_text(state.reasoning),
      text: non_blank_text(state.text) |> option.unwrap(""),
      tool_calls: list.reverse(state.completed),
    )
  let state = StreamState(..state, finished: True)
  #(state, [
    StreamFinished(
      response: response,
      usage: normalized,
      no_usage_data: no_usage_data,
    ),
  ])
}

fn append_text(current: Option(String), delta: String) -> Option(String) {
  case current {
    Some(text) -> Some(text <> delta)
    None -> Some(delta)
  }
}

fn non_blank_text(text: Option(String)) -> Option(String) {
  case text {
    Some(text) ->
      case string.trim(text) {
        "" -> None
        _ -> Some(text)
      }
    None -> None
  }
}

fn append_tool_input(
  tools: List(ToolAssembly),
  index: Int,
  delta: String,
) -> List(ToolAssembly) {
  list.map(tools, fn(tool) {
    case tool.index == index {
      True -> ToolAssembly(..tool, input_json: tool.input_json <> delta)
      False -> tool
    }
  })
}

fn tool_id(tools: List(ToolAssembly), index: Int) -> String {
  case tools {
    [] -> ""
    [tool, ..rest] ->
      case tool.index == index {
        True -> tool.id
        False -> tool_id(rest, index)
      }
  }
}

fn take_tool(
  tools: List(ToolAssembly),
  index: Int,
) -> Result(#(ToolAssembly, List(ToolAssembly)), Nil) {
  case tools {
    [] -> Error(Nil)
    [tool, ..rest] ->
      case tool.index == index {
        True -> Ok(#(tool, rest))
        False ->
          case take_tool(rest, index) {
            Ok(#(found, remaining)) -> Ok(#(found, [tool, ..remaining]))
            Error(Nil) -> Error(Nil)
          }
      }
  }
}

fn decode_tool_input(input_json: String) -> Result(Dynamic, Nil) {
  let input_json = case string.trim(input_json) {
    "" -> "{}"
    _ -> input_json
  }

  json.parse(input_json, decode.dynamic)
  |> result.replace_error(Nil)
}
