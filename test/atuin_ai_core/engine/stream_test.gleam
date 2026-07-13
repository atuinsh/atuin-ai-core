import atuin_ai_core/domain/usage
import atuin_ai_core/engine/stream
import atuin_ai_core/engine/turn
import gleam/dynamic/decode
import gleam/option.{None, Some}

fn report(input: Int, output: Int) -> usage.UsageReport {
  usage.UsageReport(
    ..usage.empty_report(),
    input_tokens: Some(input),
    output_tokens: Some(output),
    present: True,
  )
}

fn expected_usage(input: Int, output: Int) -> usage.Usage {
  usage.Usage(
    ..usage.zero(),
    input_tokens: input,
    output_tokens: output,
    total_tokens: input + output,
  )
}

pub fn text_stream_finishes_with_response_and_usage_test() {
  let state = stream.new_stream(usage.Anthropic)
  let #(state, events) = stream.update(state, stream.TextChunk("hello "))
  assert events == [stream.TextDelta("hello ")]

  let #(state, events) = stream.update(state, stream.TextChunk("world"))
  assert events == [stream.TextDelta("world")]

  let #(state, events) = stream.update(state, stream.UsageChunk(report(12, 4)))
  assert events == [stream.UsageReported(expected_usage(12, 4))]

  let #(_state, events) = stream.update(state, stream.StreamDone)
  assert events
    == [
      stream.StreamFinished(
        response: turn.LlmResponse(
          text: "hello world",
          reasoning: None,
          tool_calls: [],
        ),
        usage: expected_usage(12, 4),
        no_usage_data: False,
      ),
    ]
}

pub fn reasoning_stream_emits_deltas_and_final_reasoning_test() {
  let state = stream.new_stream(usage.Anthropic)
  let #(state, events) =
    stream.update(state, stream.ReasoningChunk("thinking "))
  assert events == [stream.ReasoningDelta("thinking ")]

  let #(state, events) = stream.update(state, stream.ReasoningChunk("hard"))
  assert events == [stream.ReasoningDelta("hard")]

  let #(state, events) = stream.update(state, stream.TextChunk("answer"))
  assert events == [stream.TextDelta("answer")]

  let #(_state, events) = stream.update(state, stream.StreamDone)
  let assert [stream.StreamFinished(response:, usage: _, no_usage_data: True)] =
    events
  assert response.text == "answer"
  assert response.reasoning == Some("thinking hard")
  assert response.tool_calls == []
}

pub fn interleaved_text_and_reasoning_accumulate_separately_test() {
  let state = stream.new_stream(usage.Anthropic)
  let #(state, _events) = stream.update(state, stream.TextChunk("hello "))
  let #(state, _events) = stream.update(state, stream.ReasoningChunk("think "))
  let #(state, _events) = stream.update(state, stream.TextChunk("world"))
  let #(state, _events) = stream.update(state, stream.ReasoningChunk("more"))

  let #(_state, events) = stream.update(state, stream.StreamDone)
  let assert [stream.StreamFinished(response:, usage: _, no_usage_data: True)] =
    events
  assert response.text == "hello world"
  assert response.reasoning == Some("think more")
}

pub fn blank_text_and_reasoning_are_dropped_on_finish_test() {
  let state = stream.new_stream(usage.Anthropic)
  let #(state, _events) = stream.update(state, stream.TextChunk("  "))
  let #(state, _events) = stream.update(state, stream.ReasoningChunk("\n"))

  let #(_state, events) = stream.update(state, stream.StreamDone)
  let assert [stream.StreamFinished(response:, usage: _, no_usage_data: True)] =
    events
  assert response.text == ""
  assert response.reasoning == None
}

pub fn tool_call_stream_emits_fine_grained_events_test() {
  let state = stream.new_stream(usage.Anthropic)
  let #(state, events) =
    stream.update(state, stream.ToolCallStartChunk(0, "toolu_1", "web_search"))
  assert events == [stream.ToolCallStarted("toolu_1", "web_search")]

  let #(state, events) =
    stream.update(state, stream.ToolCallInputChunk(0, "{\"query\":"))
  assert events == [stream.ToolCallInputDelta("toolu_1", "{\"query\":")]

  let #(state, events) =
    stream.update(state, stream.ToolCallInputChunk(0, "\"gleam\"}"))
  assert events == [stream.ToolCallInputDelta("toolu_1", "\"gleam\"}")]

  let #(state, events) = stream.update(state, stream.ToolCallStopChunk(0))
  let assert [stream.ToolCallFinished(call)] = events
  assert call.id == "toolu_1"
  assert call.name == "web_search"
  assert decode.run(call.input, decode.at(["query"], decode.string))
    == Ok("gleam")

  let #(_state, events) = stream.update(state, stream.StreamDone)
  let assert [stream.StreamFinished(response:, usage: _, no_usage_data: True)] =
    events
  assert response.text == ""
  assert response.tool_calls == [call]
}

pub fn provider_failure_reports_partial_usage_test() {
  let state = stream.new_stream(usage.Anthropic)
  let #(state, _events) = stream.update(state, stream.UsageChunk(report(10, 2)))
  let #(_state, events) =
    stream.update(state, stream.StreamFailed(stream.Unavailable))

  assert events
    == [
      stream.StreamFailedEvent(
        error: stream.Unavailable,
        partial_usage: Some(expected_usage(10, 2)),
      ),
    ]
}

pub fn invalid_tool_input_fails_stream_test() {
  let state = stream.new_stream(usage.Anthropic)
  let #(state, _events) =
    stream.update(state, stream.ToolCallStartChunk(0, "toolu_1", "web_search"))
  let #(state, _events) =
    stream.update(state, stream.ToolCallInputChunk(0, "{"))
  let #(state, events) = stream.update(state, stream.ToolCallStopChunk(0))

  assert events
    == [
      stream.StreamFailedEvent(
        error: stream.InvalidToolInput("toolu_1", "{"),
        partial_usage: None,
      ),
    ]

  let #(_state, events) = stream.update(state, stream.TextChunk("ignored"))
  assert events == []
}
