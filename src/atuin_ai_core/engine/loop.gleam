//// The chat turn loop as a pure state machine.
////
//// `step(state, event)` consumes one typed event from the driver and
//// returns the new state plus a `Dispatch`: the fire-and-forget sends to
//// perform, and either the single effect that yields the next event
//// (`AwaitEvent`) or the turn's terminal outcome (`Terminal`). The FSM
//// performs no I/O: streaming, tool execution, persistence, and the LLM
//// call itself all live in the driver (`http/driver`), which decodes
//// their outcomes back into events.
////
//// Splitting "the sends" from "the one thing that ends the batch" lets the
//// type system enforce what used to be a convention — every transition
//// resolves to exactly one trigger-or-outcome, so the driver's loop is
//// total and can't be handed an ambiguous or empty command batch.
////
//// Multi-turn agent flow: the loop continues until the LLM completes its
//// turn (suggest_command or a plain text response), pauses for client
//// tool execution, the iteration cap is reached, or the client disconnects.

import atuin_ai_core/domain/usage.{type Usage}
import atuin_ai_core/engine/stream
import atuin_ai_core/engine/turn.{
  type LlmResponse, type SessionSummary, type SummarizedToolCall, type ToolCall,
  type ToolResult,
}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option}

const max_tool_iterations = 10

/// One entry in the loop's conversation. Client-transcript entries stay
/// opaque (the driver re-encodes them from its own typed originals);
/// messages appended by the loop are fully typed.
pub type LoopMessage {
  /// A message from the client transcript. Only the role is needed here —
  /// the loop counts user turns; the driver owns the content.
  Inherited(role: Role)
  /// Assistant output appended after a tool-bearing response.
  AssistantToolUse(text: String, tool_calls: List(ToolCall))
  /// A tool result message feeding an executed tool's output back to the
  /// model.
  ToolResultMessage(tool_call_id: String, content: String)
}

pub type Role {
  User
  Assistant
  OtherRole
}

/// Events the driver feeds into the loop.
pub type Event {
  /// A provider stream event, embedded rather than mirrored — the provider
  /// FSM (`engine/stream`) owns the streaming vocabulary and this loop
  /// consumes it directly. `elapsed_ms` is driver-stamped time since the
  /// LLM call started (the loop is pure and has no clock); it becomes the
  /// call's duration when the event is terminal.
  FromStream(event: stream.StreamEvent, elapsed_ms: Int)
  /// One server tool finished executing. The iteration continues once the
  /// stream has resolved and every requested tool has completed.
  ToolCompleted(result: ToolResult, duration_ms: Int)
  /// A conn-level send failed: the client is gone. A dumb transport fact,
  /// delivered as soon as the driver notices — what it *means* is decided
  /// here, per phase: mid-stream the loop keeps consuming (so usage
  /// accrues and bills) while muting all client sends, then cancels when
  /// the stream resolves; at any other point it cancels immediately.
  ClientDisconnected
}

/// Fire-and-forget effects: the driver performs them in order and they
/// never produce an event. A disconnected client makes them no-op.
pub type Command {
  SendTextDelta(text: String)
  SendReasoningDelta(text: String)
  SendToolCallStarted(id: String, name: String)
  SendToolCalls(calls: List(ToolCall))
  SendToolResults(results: List(ToolResult))
  SendStatus(status: Status)
  SendDone(usage: Usage)
  SendError(message: String, code: String)
  /// Surface that the provider reported no usage data (recorded as free).
  WarnNoUsageData
  EmitTrace(event: TraceEvent)
}

/// The single effect that produces the loop's next event. Executing it is
/// what advances the turn; the driver decodes its outcome back into an
/// `Event`.
pub type Trigger {
  /// Emit the llm_request trace for this iteration, send status thinking,
  /// then call the LLM. Yields `FromStream` events as the stream runs.
  CallLlm(conversation: List(LoopMessage), iteration: Int)
  /// Execute these server-side tools in parallel. Yields one
  /// `ToolCompleted` per call.
  ExecuteServerTools(calls: List(ToolCall))
}

/// What `step` hands back: the sends to perform, then either start an effect,
/// wait for the next externally-fed stream event, or terminate the turn.
pub type Dispatch {
  AwaitEvent(sends: List(Command), trigger: Trigger)
  AwaitInput(sends: List(Command))
  Terminal(sends: List(Command), outcome: Outcome)
}

pub type Status {
  Thinking
  Searching
  WaitingForTools
}

/// Trace events carry what the loop knows; the driver fills in
/// request-stable context (model, prompts, tool list) when persisting.
/// event_order follows the iteration*3 + {1,2,3} convention the admin
/// trace UI sorts by.
pub type TraceEvent {
  /// An LLM call is about to start. The driver renders the conversation
  /// and adds the request-stable payload (model, prompts, tool list).
  LlmRequested(
    iteration: Int,
    event_order: Int,
    conversation: List(LoopMessage),
  )
  LlmResponded(
    iteration: Int,
    event_order: Int,
    text: String,
    tool_calls: List(ToolCall),
    usage: Usage,
    duration_ms: Int,
  )
  ToolExecuted(
    iteration: Int,
    event_order: Int,
    result: ToolResult,
    input: Dynamic,
    duration_ms: Int,
  )
}

pub type Outcome {
  /// The turn completed; summary is present unless the model answered
  /// with plain text only... it always is — text-only turns still carry a
  /// turn-count-only summary, matching historical behavior.
  Success(usage: Usage, summary: SessionSummary)
  /// The turn paused for client tool execution; the client will continue
  /// the session with a new request.
  PausedForClientTools(usage: Usage)
  Failed(error_type: String, usage: Usage)
  /// The client disconnected; the turn stopped after the in-flight
  /// generation. Billed for the usage that accrued, like `Success`.
  Cancelled(usage: Usage, summary: SessionSummary)
}

/// Accumulated model output across loop iterations, for analytics.
pub type Responses {
  Responses(text: List(String), tool_calls: List(SummarizedToolCall))
}

/// The current iteration's generation, one of the orthogonal lifecycles a
/// turn is made of. A disconnect during `Streaming` drains rather than
/// cancels (usage must bill); during `Connecting` nothing has been spent
/// yet, so the turn can stop cold.
pub type StreamPhase {
  /// An LLM call has been requested; no stream events have arrived yet.
  Connecting
  Streaming
  StreamResolved
  StreamErrored
}

/// One requested server tool's lifecycle within the current iteration.
pub type ToolExec {
  ToolExec(call: ToolCall, progress: ToolProgress)
}

pub type ToolProgress {
  Executing
  Resolved(result: ToolResult)
}

pub type TurnStatus {
  Active
  Finished(outcome: Outcome)
}

pub type State {
  State(
    /// The in-flight generation, independent of tool execution.
    stream: StreamPhase,
    /// This iteration's server tools, in call order. The iteration
    /// completes when the stream has resolved AND every entry is resolved
    /// — a predicate over the lifecycles, not a linear phase.
    tools: List(ToolExec),
    /// Client tools from the current generation, handed off when the
    /// iteration completes.
    pending_client_tools: List(ToolCall),
    /// The current generation's answer text, recorded with the tool
    /// exchange when the iteration continues.
    assistant_text: String,
    conversation: List(LoopMessage),
    accumulated_usage: Usage,
    iteration: Int,
    session_id: String,
    responses: Responses,
    /// Transport liveness. Once False, client-facing sends are muted (the
    /// socket is gone) while the loop keeps accruing usage and traces.
    client_connected: Bool,
    status: TurnStatus,
    /// Which tool calls this server executes itself, from the instance's
    /// registrations.
    is_server_tool: fn(String) -> Bool,
  )
}

/// The loop's accumulated model output, for the turn's usage record.
pub fn responses(state: State) -> Responses {
  state.responses
}

/// Starts a turn: asks the driver to make the first LLM call.
pub fn start(
  session_id: String,
  conversation: List(LoopMessage),
  is_server_tool: fn(String) -> Bool,
) -> #(State, Dispatch) {
  let state =
    State(
      stream: Connecting,
      tools: [],
      pending_client_tools: [],
      assistant_text: "",
      conversation: conversation,
      accumulated_usage: usage.zero(),
      iteration: 0,
      session_id: session_id,
      responses: Responses(text: [], tool_calls: []),
      client_connected: True,
      status: Active,
      is_server_tool:,
    )

  #(state, call_llm_dispatch(state))
}

// Every LLM call is announced the same way: the llm_request trace and the
// thinking status precede the trigger.
fn call_llm_dispatch(state: State) -> Dispatch {
  AwaitEvent(
    sends: [
      EmitTrace(LlmRequested(
        iteration: state.iteration,
        event_order: state.iteration * 3 + 1,
        conversation: state.conversation,
      )),
      SendStatus(Thinking),
    ],
    trigger: CallLlm(state.conversation, state.iteration),
  )
}

pub fn step(state: State, event: Event) -> #(State, Dispatch) {
  let #(state, dispatch) = transition(state, event)
  #(state, mute_sends_when_disconnected(state, dispatch))
}

fn transition(state: State, event: Event) -> #(State, Dispatch) {
  case state.status {
    // Late events after termination change nothing; restate the outcome.
    Finished(outcome) -> #(state, Terminal(sends: [], outcome:))
    Active -> handle_active(state, event)
  }
}

fn handle_active(state: State, event: Event) -> #(State, Dispatch) {
  case state.stream, event {
    // Mid-stream disconnect: keep consuming the stream (usage accrues and
    // bills) with sends muted; the cancel happens when the stream
    // resolves. Anywhere else — before the call has produced anything, or
    // while tools run after it — cancel immediately so no new work starts
    // for a client that's gone.
    Streaming, ClientDisconnected -> #(
      State(..state, client_connected: False),
      AwaitInput(sends: []),
    )
    _, ClientDisconnected ->
      terminate_cancelled(State(..state, client_connected: False))

    Connecting, FromStream(stream_event, elapsed_ms)
    | Streaming, FromStream(stream_event, elapsed_ms)
    ->
      handle_stream_event(
        State(..state, stream: Streaming),
        stream_event,
        elapsed_ms,
      )

    _, ToolCompleted(result, duration_ms) ->
      handle_tool_completed(state, result, duration_ms)

    // A lifecycle/event mismatch can't occur with the current driver —
    // each effect only ever yields the event it produces. Finish cleanly
    // rather than loop, as a defensive backstop.
    _, _ -> complete_turn(state, [])
  }
}

// Mid-stream events forward deltas to the client and otherwise wait — the
// provider FSM owns accumulation, so the loop only acts when the stream
// resolves.
fn handle_stream_event(
  state: State,
  event: stream.StreamEvent,
  elapsed_ms: Int,
) -> #(State, Dispatch) {
  case event {
    stream.TextDelta(text) -> continue_streaming(state, [SendTextDelta(text)])

    stream.ReasoningDelta(text) ->
      continue_streaming(state, [SendReasoningDelta(text)])

    stream.ToolCallStarted(id, name) ->
      continue_streaming(state, [SendToolCallStarted(id:, name:)])

    stream.ToolCallInputDelta(_, _) -> continue_streaming(state, [])

    stream.ToolCallFinished(_) -> continue_streaming(state, [])

    // Interim usage: the loop waits for the terminal stream event before
    // billing or recording.
    stream.UsageReported(_) -> continue_streaming(state, [])

    stream.StreamFinished(response, call_usage, no_usage_data) ->
      handle_llm_response(
        state,
        response,
        call_usage,
        no_usage_data,
        elapsed_ms,
      )

    stream.StreamFailedEvent(error, partial_usage) ->
      fail(state, error, partial_usage)
  }
}

fn continue_streaming(
  state: State,
  sends: List(Command),
) -> #(State, Dispatch) {
  #(state, AwaitInput(sends: sends))
}

fn fail(
  state: State,
  error: stream.ProviderError,
  partial_usage: Option(Usage),
) -> #(State, Dispatch) {
  let #(message, code, error_type) = describe_error(error)
  let total =
    usage.aggregate(
      state.accumulated_usage,
      option.unwrap(partial_usage, usage.zero()),
    )

  finish(
    State(..state, stream: StreamErrored),
    sends: [SendError(message, code)],
    outcome: Failed(error_type: error_type, usage: total),
  )
}

// Terminates the turn: the outcome is recorded as state (the receive-loop
// driver's completion predicate) and returned as the Terminal dispatch for
// the synchronous drivers.
fn finish(
  state: State,
  sends sends: List(Command),
  outcome outcome: Outcome,
) -> #(State, Dispatch) {
  #(State(..state, status: Finished(outcome)), Terminal(sends:, outcome:))
}

fn handle_llm_response(
  state: State,
  response: LlmResponse,
  call_usage: Usage,
  no_usage_data: Bool,
  duration_ms: Int,
) -> #(State, Dispatch) {
  let total = usage.aggregate(state.accumulated_usage, call_usage)
  let state =
    State(
      ..state,
      stream: StreamResolved,
      accumulated_usage: total,
      responses: accumulate_responses(state.responses, response),
    )

  let warn = case no_usage_data {
    True -> [WarnNoUsageData]
    False -> []
  }

  let trace =
    EmitTrace(LlmResponded(
      iteration: state.iteration,
      event_order: state.iteration * 3 + 2,
      text: response.text,
      tool_calls: response.tool_calls,
      usage: call_usage,
      duration_ms: duration_ms,
    ))

  let #(state, dispatch) = case state.client_connected {
    // The client disconnected mid-stream: the generation was drained for
    // billing; now that it has resolved, cancel instead of continuing.
    False -> terminate_cancelled(state)

    True ->
      case turn.classify(response, state.is_server_tool) {
        turn.EmptyResponse -> advance_iteration(state)

        turn.TextOnly -> complete_turn(state, [])

        turn.FinalSuggest -> {
          let #(state, dispatch) = complete_turn(state, response.tool_calls)
          #(
            state,
            prepend_sends([SendToolCalls(response.tool_calls)], dispatch),
          )
        }

        turn.NeedsClientTools(server: [], client:) ->
          pause_for_client(state, client)

        turn.NeedsClientTools(server:, client:) ->
          start_server_tools(state, server, client, response.text)

        turn.ServerToolsOnly(server:) ->
          start_server_tools(state, server, [], response.text)
      }
  }

  #(state, prepend_sends(list.append(warn, [trace]), dispatch))
}

fn start_server_tools(
  state: State,
  server: List(ToolCall),
  client: List(ToolCall),
  assistant_text: String,
) -> #(State, Dispatch) {
  #(
    State(
      ..state,
      tools: list.map(server, ToolExec(_, Executing)),
      pending_client_tools: client,
      assistant_text: assistant_text,
    ),
    AwaitEvent(
      sends: [SendToolCalls(server), SendStatus(Searching)],
      trigger: ExecuteServerTools(server),
    ),
  )
}

// Resolves one tool, emits its trace and result send, and — once the
// completion predicate holds (stream resolved, every tool resolved) —
// records the exchange and either continues the loop or hands off to the
// client's tools.
fn handle_tool_completed(
  state: State,
  result: ToolResult,
  duration_ms: Int,
) -> #(State, Dispatch) {
  case resolve_tool(state.tools, result) {
    // Unknown or already-resolved id: nothing to act on. (Unreachable
    // with the current drivers; a duplicate delivery under a concurrent
    // driver must not wedge or double-record the turn.)
    Error(Nil) -> #(state, AwaitInput(sends: []))

    Ok(#(tools, call)) -> {
      let state = State(..state, tools:)
      let sends = [
        EmitTrace(ToolExecuted(
          iteration: state.iteration,
          event_order: state.iteration * 3 + 3,
          result: result,
          input: call.input,
          duration_ms: duration_ms,
        )),
        SendToolResults([result]),
      ]

      let #(state, dispatch) = check_iteration_complete(state)
      #(state, prepend_sends(sends, dispatch))
    }
  }
}

fn resolve_tool(
  tools: List(ToolExec),
  result: ToolResult,
) -> Result(#(List(ToolExec), ToolCall), Nil) {
  case
    list.find(tools, fn(exec) {
      exec.call.id == result.id && exec.progress == Executing
    })
  {
    Error(Nil) -> Error(Nil)
    Ok(matched) -> {
      let tools =
        list.map(tools, fn(exec) {
          case exec.call.id == result.id {
            True -> ToolExec(..exec, progress: Resolved(result))
            False -> exec
          }
        })
      Ok(#(tools, matched.call))
    }
  }
}

// The iteration is complete when the generation has resolved AND every
// requested server tool has resolved; until then, keep waiting. On
// completion the tool exchange is recorded in the conversation, and the
// turn either loops (another LLM call) or pauses for the client's tools.
fn check_iteration_complete(state: State) -> #(State, Dispatch) {
  let all_resolved =
    list.all(state.tools, fn(exec) { exec.progress != Executing })

  case state.stream == StreamResolved && all_resolved {
    False -> #(state, AwaitInput(sends: []))
    True -> {
      let calls = list.map(state.tools, fn(exec) { exec.call })
      let results =
        list.filter_map(state.tools, fn(exec) {
          case exec.progress {
            Resolved(result) -> Ok(result)
            Executing -> Error(Nil)
          }
        })

      let state =
        State(
          ..state,
          conversation: append_tool_exchange(
            state,
            state.assistant_text,
            calls,
            results,
          ),
        )

      case state.pending_client_tools {
        [] -> advance_iteration(state)
        client -> pause_for_client(state, client)
      }
    }
  }
}

fn complete_turn(
  state: State,
  final_calls: List(ToolCall),
) -> #(State, Dispatch) {
  let summary =
    turn.build_session_summary(
      final_calls,
      count_user_messages(state.conversation),
    )

  finish(
    state,
    sends: [SendDone(state.accumulated_usage)],
    outcome: Success(usage: state.accumulated_usage, summary: summary),
  )
}

// Client disconnected: bill the accumulated usage and stop. No sends — the
// socket is gone, so SendDone would only no-op.
fn terminate_cancelled(state: State) -> #(State, Dispatch) {
  let summary =
    turn.build_session_summary([], count_user_messages(state.conversation))

  finish(
    state,
    sends: [],
    outcome: Cancelled(usage: state.accumulated_usage, summary: summary),
  )
}

fn pause_for_client(
  state: State,
  client: List(ToolCall),
) -> #(State, Dispatch) {
  finish(
    state,
    sends: [
      SendToolCalls(client),
      SendStatus(WaitingForTools),
      SendDone(state.accumulated_usage),
    ],
    outcome: PausedForClientTools(usage: state.accumulated_usage),
  )
}

fn advance_iteration(state: State) -> #(State, Dispatch) {
  let next = state.iteration + 1

  case next >= max_tool_iterations {
    True ->
      finish(
        state,
        sends: [
          SendError("Max tool execution limit reached", "generation_failed"),
        ],
        outcome: Failed(
          error_type: "max_tool_iterations",
          usage: state.accumulated_usage,
        ),
      )
    False -> {
      let state =
        State(
          ..state,
          iteration: next,
          stream: Connecting,
          tools: [],
          pending_client_tools: [],
          assistant_text: "",
        )
      #(state, call_llm_dispatch(state))
    }
  }
}

// Once the client is gone, conn-facing commands are dropped at the source
// — the socket is dead — while host-facing ones (traces, warnings) still
// run, so a cancelled turn is fully recorded.
fn mute_sends_when_disconnected(state: State, dispatch: Dispatch) -> Dispatch {
  case state.client_connected {
    True -> dispatch
    False ->
      case dispatch {
        AwaitEvent(sends:, trigger:) ->
          AwaitEvent(sends: host_commands(sends), trigger:)
        AwaitInput(sends:) -> AwaitInput(sends: host_commands(sends))
        Terminal(sends:, outcome:) ->
          Terminal(sends: host_commands(sends), outcome:)
      }
  }
}

fn host_commands(sends: List(Command)) -> List(Command) {
  list.filter(sends, fn(command) {
    case command {
      EmitTrace(_) | WarnNoUsageData -> True
      _ -> False
    }
  })
}

// Prepends fire-and-forget sends ahead of whatever the dispatch already
// carries, preserving its trigger/outcome.
fn prepend_sends(extra: List(Command), dispatch: Dispatch) -> Dispatch {
  case dispatch {
    AwaitEvent(sends:, trigger:) ->
      AwaitEvent(sends: list.append(extra, sends), trigger:)
    AwaitInput(sends:) -> AwaitInput(sends: list.append(extra, sends))
    Terminal(sends:, outcome:) ->
      Terminal(sends: list.append(extra, sends), outcome:)
  }
}

// The assistant message carrying the tool calls, followed by one tool
// result message per executed tool.
fn append_tool_exchange(
  state: State,
  assistant_text: String,
  calls: List(ToolCall),
  results: List(ToolResult),
) -> List(LoopMessage) {
  let result_messages =
    list.map(results, fn(result) {
      ToolResultMessage(tool_call_id: result.id, content: result.result)
    })

  list.flatten([
    state.conversation,
    [AssistantToolUse(text: assistant_text, tool_calls: calls)],
    result_messages,
  ])
}

fn accumulate_responses(
  responses: Responses,
  response: LlmResponse,
) -> Responses {
  let text = case response.text {
    "" -> responses.text
    text -> list.append(responses.text, [text])
  }

  Responses(
    text: text,
    tool_calls: list.append(
      responses.tool_calls,
      list.map(response.tool_calls, turn.summarize),
    ),
  )
}

fn count_user_messages(conversation: List(LoopMessage)) -> Int {
  list.count(conversation, fn(message) {
    case message {
      Inherited(role: User) -> True
      _ -> False
    }
  })
}

// Message, wire code, and recorded error_type for a provider failure.
fn describe_error(error: stream.ProviderError) -> #(String, String, String) {
  case error {
    stream.RateLimited -> #(
      "LLM rate limit exceeded, please retry",
      "llm_rate_limit",
      "llm_rate_limit",
    )
    stream.Unavailable -> #(
      "LLM service temporarily unavailable",
      "llm_unavailable",
      "llm_unavailable",
    )
    stream.GenerationFailed -> #(
      "Failed to generate response",
      "generation_failed",
      "generation_failed",
    )
    stream.StreamProcessingFailed | stream.InvalidToolInput(_, _) -> #(
      "Failed to process LLM response",
      "generation_failed",
      "generation_failed",
    )
    stream.StreamCrashed -> #(
      "Streaming error occurred",
      "internal_error",
      "internal_error",
    )
    stream.TransportFailed(detail) -> #(
      "LLM request failed: " <> detail,
      "upstream_error",
      "upstream_error",
    )
  }
}
