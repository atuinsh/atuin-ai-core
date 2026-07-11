import atuin_hub/cli_chat/domain/usage.{Usage}
import atuin_hub/cli_chat/engine/loop.{
  AssistantToolUse, AwaitEvent, AwaitInput, CallLlm, Cancelled,
  ClientDisconnected, EmitTrace, ExecuteServerTools, Failed, Finished,
  FromStream, Inherited, PausedForClientTools, Searching, SendDone, SendError,
  SendReasoningDelta, SendStatus, SendTextDelta, SendToolCallStarted,
  SendToolCalls, SendToolResults, Success, Terminal, ToolCompleted, ToolExecuted,
  ToolResultMessage, User, WaitingForTools, WarnNoUsageData,
}
import atuin_hub/cli_chat/engine/stream
import atuin_hub/cli_chat/engine/turn.{
  type LlmResponse, LlmResponse, ToolCall, ToolResult,
}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}

fn obj(entries: List(#(String, Dynamic))) -> Dynamic {
  entries
  |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) })
  |> dynamic.properties
}

fn conversation() {
  [Inherited(role: User), Inherited(role: User)]
}

// The server-tool set these tests assume, standing in for an instance's
// registrations.
fn server_tools(name: String) -> Bool {
  name == "web_search" || name == "web_scrape"
}

fn some_usage(input: Int, output: Int) {
  Usage(
    ..usage.zero(),
    input_tokens: input,
    output_tokens: output,
    total_tokens: input + output,
  )
}

fn text_response(text: String) {
  LlmResponse(text: text, reasoning: None, tool_calls: [])
}

fn completed(response: LlmResponse, used: usage.Usage) {
  FromStream(
    stream.StreamFinished(response:, usage: used, no_usage_data: False),
    42,
  )
}

fn suggest_call() {
  ToolCall(
    id: "tc_1",
    name: "suggest_command",
    input: obj([
      #("command", dynamic.string("ls")),
      #("confidence", dynamic.string("high")),
      #("danger", dynamic.string("low")),
    ]),
  )
}

fn search_call() {
  ToolCall(
    id: "tc_s",
    name: "web_search",
    input: obj([#("query", dynamic.string("gleam"))]),
  )
}

fn client_call() {
  ToolCall(id: "tc_c", name: "read_file", input: obj([]))
}

pub fn start_requests_first_llm_call_test() {
  let #(state, dispatch) = loop.start("sess", conversation(), server_tools)
  assert state.status == loop.Active
  assert state.iteration == 0
  // The call is announced by the FSM itself: llm_request trace, then the
  // thinking status, then the trigger.
  assert dispatch
    == AwaitEvent(
      sends: [
        EmitTrace(loop.LlmRequested(
          iteration: 0,
          event_order: 1,
          conversation: conversation(),
        )),
        SendStatus(loop.Thinking),
      ],
      trigger: CallLlm(conversation(), 0),
    )
}

pub fn stream_deltas_are_forwarded_without_lifecycle_decisions_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)

  let #(state, dispatch) =
    loop.step(state, FromStream(stream.TextDelta("hello "), 1))
  assert state.status == loop.Active
  assert dispatch == AwaitInput(sends: [SendTextDelta("hello ")])

  let #(state, dispatch) =
    loop.step(state, FromStream(stream.ReasoningDelta("thinking"), 2))
  assert state.status == loop.Active
  assert dispatch == AwaitInput(sends: [SendReasoningDelta("thinking")])

  let #(state, dispatch) =
    loop.step(state, FromStream(stream.UsageReported(some_usage(1, 0)), 3))
  assert state.status == loop.Active
  assert dispatch == AwaitInput(sends: [])
}

pub fn streaming_tool_progress_is_forwarded_but_not_classified_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let call = search_call()

  let #(state, dispatch) =
    loop.step(
      state,
      FromStream(stream.ToolCallStarted(id: call.id, name: call.name), 1),
    )
  assert state.status == loop.Active
  assert dispatch
    == AwaitInput(sends: [
      SendToolCallStarted(id: "tc_s", name: "web_search"),
    ])

  let #(state, dispatch) =
    loop.step(
      state,
      FromStream(
        stream.ToolCallInputDelta(id: call.id, delta: "{\"query\":"),
        2,
      ),
    )
  assert state.status == loop.Active
  assert dispatch == AwaitInput(sends: [])

  let #(state, dispatch) =
    loop.step(state, FromStream(stream.ToolCallFinished(call), 3))
  assert state.status == loop.Active
  assert dispatch == AwaitInput(sends: [])
}

pub fn stream_finished_uses_existing_completion_decisions_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let response = text_response("hello")
  let #(state, dispatch) =
    loop.step(
      state,
      FromStream(
        stream.StreamFinished(
          response: response,
          usage: some_usage(10, 5),
          no_usage_data: False,
        ),
        42,
      ),
    )

  let assert Finished(_) = state.status
  let assert Terminal(
    sends: [
      EmitTrace(loop.LlmResponded(text: "hello", usage: _, duration_ms: 42, ..)),
      SendDone(done_usage),
    ],
    outcome: Success(usage: total, summary: _),
  ) = dispatch
  assert done_usage == some_usage(10, 5)
  assert total == some_usage(10, 5)
}

pub fn stream_finished_without_usage_warns_and_records_zero_usage_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let #(state, dispatch) =
    loop.step(
      state,
      FromStream(
        stream.StreamFinished(
          response: text_response("hello"),
          usage: usage.zero(),
          no_usage_data: True,
        ),
        42,
      ),
    )

  let assert Finished(_) = state.status
  let assert Terminal(
    sends: [WarnNoUsageData, EmitTrace(_), SendDone(done_usage)],
    outcome: Success(usage: total, summary: _),
  ) = dispatch
  assert done_usage == usage.zero()
  assert total == usage.zero()
}

pub fn text_only_completes_the_turn_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let #(state, dispatch) =
    loop.step(state, completed(text_response("hello"), some_usage(10, 5)))

  let assert Finished(_) = state.status
  let assert Terminal(
    sends: [
      EmitTrace(loop.LlmResponded(
        iteration: 0,
        event_order: 2,
        text: "hello",
        tool_calls: [],
        usage: _,
        duration_ms: 42,
      )),
      SendDone(done_usage),
    ],
    outcome: Success(usage: total, summary: summary),
  ) = dispatch
  assert done_usage == some_usage(10, 5)
  assert total == some_usage(10, 5)
  // Two user messages in the inherited transcript
  assert summary.turn_count == 2
  assert summary.confidence == None
  assert summary.danger == None
}

pub fn final_suggest_sends_tool_calls_and_summary_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let response =
    LlmResponse(text: "", reasoning: None, tool_calls: [suggest_call()])
  let #(state, dispatch) =
    loop.step(state, completed(response, some_usage(10, 5)))

  let assert Finished(_) = state.status
  let assert Terminal(
    sends: [
      EmitTrace(_),
      SendToolCalls([ToolCall(id: "tc_1", name: "suggest_command", input: _)]),
      SendDone(_),
    ],
    outcome: Success(usage: _, summary: summary),
  ) = dispatch
  assert summary.confidence == Some("high")
  assert summary.danger == Some("low")
  assert summary.confidence_notes == None
}

pub fn empty_response_retries_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let #(state, dispatch) =
    loop.step(state, completed(text_response("   "), some_usage(3, 0)))

  assert state.status == loop.Active
  assert state.iteration == 1
  let assert AwaitEvent(
    sends: [
      EmitTrace(loop.LlmResponded(..)),
      EmitTrace(loop.LlmRequested(iteration: 1, event_order: 4, ..)),
      SendStatus(loop.Thinking),
    ],
    trigger: CallLlm(conv, 1),
  ) = dispatch
  assert conv == conversation()
}

pub fn empty_responses_hit_iteration_cap_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)

  // 9 empty responses advance to iteration 9; the 10th hits the cap.
  let state =
    list.fold(list.repeat(Nil, 9), state, fn(state, _) {
      let #(state, _) =
        loop.step(state, completed(text_response(""), some_usage(1, 0)))
      state
    })
  assert state.iteration == 9

  let #(state, dispatch) =
    loop.step(state, completed(text_response(""), some_usage(1, 0)))
  let assert Finished(_) = state.status
  let assert Terminal(
    sends: [
      EmitTrace(_),
      SendError("Max tool execution limit reached", "generation_failed"),
    ],
    outcome: Failed(error_type: "max_tool_iterations", usage: total),
  ) = dispatch
  // All ten calls' usage accumulated
  assert total.input_tokens == 10
}

pub fn server_tools_execute_and_continue_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let response =
    LlmResponse(text: "searching...", reasoning: None, tool_calls: [
      search_call(),
    ])
  let #(state, dispatch) =
    loop.step(state, completed(response, some_usage(10, 5)))

  let assert AwaitEvent(
    sends: [
      EmitTrace(_),
      SendToolCalls([ToolCall(id: "tc_s", ..)]),
      SendStatus(Searching),
    ],
    trigger: ExecuteServerTools([ToolCall(id: "tc_s", ..)]),
  ) = dispatch

  let result =
    ToolResult(id: "tc_s", name: "web_search", result: "found", is_error: False)
  let #(state, dispatch) = loop.step(state, ToolCompleted(result, 7))

  assert state.status == loop.Active
  assert state.iteration == 1
  let assert AwaitEvent(
    sends: [
      EmitTrace(ToolExecuted(
        iteration: 0,
        event_order: 3,
        result: _,
        input: _,
        duration_ms: 7,
      )),
      SendToolResults([_]),
      EmitTrace(loop.LlmRequested(iteration: 1, ..)),
      SendStatus(loop.Thinking),
    ],
    trigger: CallLlm(conv, 1),
  ) = dispatch

  // Conversation grew by the assistant tool-use message and the result.
  assert conv
    == list.append(conversation(), [
      AssistantToolUse(text: "searching...", tool_calls: [search_call()]),
      ToolResultMessage(tool_call_id: "tc_s", content: "found"),
    ])

  // A subsequent text answer completes with aggregated usage.
  let #(_, dispatch) =
    loop.step(state, completed(text_response("answer"), some_usage(20, 10)))
  let assert Terminal(sends: [_, SendDone(done_usage)], outcome: Success(..)) =
    dispatch
  assert done_usage.input_tokens == 30
  assert done_usage.output_tokens == 15
}

pub fn client_tools_pause_directly_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let response =
    LlmResponse(text: "", reasoning: None, tool_calls: [client_call()])
  let #(state, dispatch) =
    loop.step(state, completed(response, some_usage(10, 5)))

  let assert Finished(_) = state.status
  let assert Terminal(
    sends: [
      EmitTrace(_),
      SendToolCalls([ToolCall(id: "tc_c", ..)]),
      SendStatus(WaitingForTools),
      SendDone(_),
    ],
    outcome: PausedForClientTools(usage: paused_usage),
  ) = dispatch
  assert paused_usage == some_usage(10, 5)
}

pub fn mixed_tools_run_server_then_hand_off_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let response =
    LlmResponse(text: "", reasoning: None, tool_calls: [
      search_call(),
      client_call(),
    ])
  let #(state, dispatch) =
    loop.step(state, completed(response, some_usage(10, 5)))

  let assert AwaitEvent(
    sends: [
      EmitTrace(_),
      SendToolCalls([ToolCall(id: "tc_s", ..)]),
      SendStatus(Searching),
    ],
    trigger: ExecuteServerTools([ToolCall(id: "tc_s", ..)]),
  ) = dispatch

  let result =
    ToolResult(id: "tc_s", name: "web_search", result: "found", is_error: False)
  let #(state, dispatch) = loop.step(state, ToolCompleted(result, 3))

  let assert Finished(_) = state.status
  let assert Terminal(
    sends: [
      EmitTrace(ToolExecuted(..)),
      SendToolResults([_]),
      SendToolCalls([ToolCall(id: "tc_c", ..)]),
      SendStatus(WaitingForTools),
      SendDone(_),
    ],
    outcome: PausedForClientTools(usage: _),
  ) = dispatch

  // The executed server tool exchange is recorded in the conversation even
  // though the turn pauses for the client tool.
  assert state.conversation
    == list.append(conversation(), [
      AssistantToolUse(text: "", tool_calls: [search_call()]),
      ToolResultMessage(tool_call_id: "tc_s", content: "found"),
    ])
}

pub fn llm_failures_map_to_errors_test() {
  let cases = [
    #(
      stream.RateLimited,
      "LLM rate limit exceeded, please retry",
      "llm_rate_limit",
      "llm_rate_limit",
    ),
    #(
      stream.Unavailable,
      "LLM service temporarily unavailable",
      "llm_unavailable",
      "llm_unavailable",
    ),
    #(
      stream.GenerationFailed,
      "Failed to generate response",
      "generation_failed",
      "generation_failed",
    ),
    #(
      stream.StreamProcessingFailed,
      "Failed to process LLM response",
      "generation_failed",
      "generation_failed",
    ),
    #(
      stream.InvalidToolInput("tc_1", "{"),
      "Failed to process LLM response",
      "generation_failed",
      "generation_failed",
    ),
    #(
      stream.StreamCrashed,
      "Streaming error occurred",
      "internal_error",
      "internal_error",
    ),
  ]

  list.each(cases, fn(test_case) {
    let #(error, message, code, error_type) = test_case
    let #(state, _) = loop.start("sess", conversation(), server_tools)
    let #(state, dispatch) =
      loop.step(
        state,
        FromStream(stream.StreamFailedEvent(error, partial_usage: None), 5),
      )
    let assert Finished(_) = state.status
    assert dispatch
      == Terminal(
        sends: [SendError(message, code)],
        outcome: Failed(error_type: error_type, usage: usage.zero()),
      )
  })
}

pub fn llm_failure_rolls_up_partial_usage_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  // First a successful tool loop iteration accrues usage
  let response =
    LlmResponse(text: "", reasoning: None, tool_calls: [search_call()])
  let #(state, _) = loop.step(state, completed(response, some_usage(10, 5)))
  let result =
    ToolResult(id: "tc_s", name: "web_search", result: "ok", is_error: False)
  let #(state, _) = loop.step(state, ToolCompleted(result, 1))

  // Then the next call dies with partial usage reported
  let #(_, dispatch) =
    loop.step(
      state,
      FromStream(
        stream.StreamFailedEvent(
          error: stream.GenerationFailed,
          partial_usage: Some(some_usage(4, 0)),
        ),
        5,
      ),
    )
  let assert Terminal(sends: _, outcome: Failed(error_type: _, usage: total)) =
    dispatch
  assert total.input_tokens == 14
  assert total.output_tokens == 5
}

pub fn no_usage_data_warns_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let event =
    FromStream(
      stream.StreamFinished(
        response: text_response("hi"),
        usage: usage.zero(),
        no_usage_data: True,
      ),
      1,
    )
  let #(_, dispatch) = loop.step(state, event)
  let assert Terminal(sends: [WarnNoUsageData, EmitTrace(_), ..], outcome: _) =
    dispatch
}

pub fn responses_accumulate_for_analytics_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let response =
    LlmResponse(text: "looking", reasoning: None, tool_calls: [search_call()])
  let #(state, _) = loop.step(state, completed(response, some_usage(1, 1)))
  let result =
    ToolResult(id: "tc_s", name: "web_search", result: "ok", is_error: False)
  let #(state, _) = loop.step(state, ToolCompleted(result, 1))
  let #(state, _) =
    loop.step(state, completed(text_response("answer"), some_usage(1, 1)))

  assert state.responses.text == ["looking", "answer"]
  let assert [summarized] = state.responses.tool_calls
  assert summarized.summary == "[TOOL] Searched for \"gleam\""
}

// --- ClientDisconnected: FSM-owned disconnect policy ------------------------

pub fn disconnect_mid_stream_drains_muted_then_cancels_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)

  // The stream is producing events when the client drops.
  let #(state, _) = loop.step(state, FromStream(stream.TextDelta("hel"), 1))
  let #(state, dispatch) = loop.step(state, ClientDisconnected)
  assert state.status == loop.Active
  assert dispatch == AwaitInput(sends: [])

  // Further deltas are consumed but no longer produce client sends.
  let #(state, dispatch) =
    loop.step(state, FromStream(stream.TextDelta("lo"), 2))
  assert dispatch == AwaitInput(sends: [])

  // When the stream resolves, the turn cancels — billing the drained
  // call's usage and still emitting its trace (a host effect, not a send).
  let #(state, dispatch) =
    loop.step(
      state,
      FromStream(
        stream.StreamFinished(
          response: text_response("hello"),
          usage: some_usage(10, 5),
          no_usage_data: False,
        ),
        42,
      ),
    )
  let assert Finished(_) = state.status
  let assert Terminal(
    sends: [EmitTrace(loop.LlmResponded(..))],
    outcome: Cancelled(usage: total, summary: _),
  ) = dispatch
  assert total == some_usage(10, 5)
}

pub fn disconnect_before_stream_cancels_without_calling_llm_test() {
  // A send failed before this iteration's stream produced anything (e.g.
  // the thinking status): cancel immediately, no LLM call.
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let #(state, dispatch) = loop.step(state, ClientDisconnected)
  let assert Finished(_) = state.status
  let assert Terminal(sends: [], outcome: Cancelled(usage: u, summary: _)) =
    dispatch
  assert u == usage.zero()
}

pub fn disconnect_at_tools_boundary_cancels_before_executing_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let response =
    LlmResponse(text: "", reasoning: None, tool_calls: [search_call()])
  let #(state, _) = loop.step(state, completed(response, some_usage(10, 5)))

  // AwaitingServerTools: the disconnect cancels rather than running tools,
  // billing the generation that already completed.
  let #(state, dispatch) = loop.step(state, ClientDisconnected)
  let assert Finished(_) = state.status
  let assert Terminal(sends: [], outcome: Cancelled(usage: total, summary: _)) =
    dispatch
  assert total == some_usage(10, 5)
}

pub fn disconnect_mutes_stream_failure_error_send_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let #(state, _) = loop.step(state, FromStream(stream.TextDelta("x"), 1))
  let #(state, _) = loop.step(state, ClientDisconnected)

  // A stream failure after disconnect still records the failure outcome,
  // but the error send is muted — the socket is gone.
  let #(state, dispatch) =
    loop.step(
      state,
      FromStream(
        stream.StreamFailedEvent(
          error: stream.Unavailable,
          partial_usage: Some(some_usage(3, 0)),
        ),
        9,
      ),
    )
  let assert Finished(_) = state.status
  assert dispatch
    == Terminal(
      sends: [],
      outcome: Failed(error_type: "llm_unavailable", usage: some_usage(3, 0)),
    )
}

// --- Per-tool completion (the receive-loop driver's event shape) -----------

pub fn tools_resolve_one_at_a_time_and_complete_by_predicate_test() {
  let second_call = ToolCall(id: "tc_2", name: "web_scrape", input: obj([]))

  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let response =
    LlmResponse(text: "looking", reasoning: None, tool_calls: [
      search_call(),
      second_call,
    ])
  let #(state, _) = loop.step(state, completed(response, some_usage(10, 5)))

  // First completion: traced and sent, but the iteration keeps waiting on
  // the other tool.
  let first =
    ToolResult(id: "tc_s", name: "web_search", result: "found", is_error: False)
  let #(state, dispatch) = loop.step(state, loop.ToolCompleted(first, 7))
  assert state.status == loop.Active
  assert dispatch
    == AwaitInput(sends: [
      EmitTrace(ToolExecuted(
        iteration: 0,
        event_order: 3,
        result: first,
        input: search_call().input,
        duration_ms: 7,
      )),
      SendToolResults([first]),
    ])

  // Second completion satisfies the predicate: the exchange is recorded
  // (in call order) and the loop continues with another LLM call.
  let second =
    ToolResult(id: "tc_2", name: "web_scrape", result: "page", is_error: False)
  let #(state, dispatch) = loop.step(state, loop.ToolCompleted(second, 3))
  assert state.iteration == 1
  let assert AwaitEvent(
    sends: [EmitTrace(ToolExecuted(..)), SendToolResults([_]), ..],
    trigger: CallLlm(conv, 1),
  ) = dispatch

  assert conv
    == list.append(conversation(), [
      AssistantToolUse(text: "looking", tool_calls: [
        search_call(),
        second_call,
      ]),
      ToolResultMessage(tool_call_id: "tc_s", content: "found"),
      ToolResultMessage(tool_call_id: "tc_2", content: "page"),
    ])
  assert state.conversation == conv
}

pub fn duplicate_tool_completion_is_ignored_test() {
  let #(state, _) = loop.start("sess", conversation(), server_tools)
  let response =
    LlmResponse(text: "", reasoning: None, tool_calls: [
      search_call(),
      ToolCall(id: "tc_2", name: "web_scrape", input: obj([])),
    ])
  let #(state, _) = loop.step(state, completed(response, some_usage(1, 1)))

  let first =
    ToolResult(id: "tc_s", name: "web_search", result: "found", is_error: False)
  let #(state, _) = loop.step(state, loop.ToolCompleted(first, 1))

  // A duplicate delivery neither double-records nor completes the turn.
  let #(state, dispatch) = loop.step(state, loop.ToolCompleted(first, 1))
  assert state.status == loop.Active
  assert dispatch == AwaitInput(sends: [])
}
