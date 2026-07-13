//// Receive-loop driver for a chat turn: the Plug request process owns the
//// conn and a typed mailbox, executes `engine/loop` dispatches, and turns
//// mailbox messages back into loop events. All async work — the LLM
//// stream, each server tool — runs in its own spawned process that
//// messages the mailbox, so the request process is never blocked inside a
//// transport pull and every wait carries a deadline: a hung upstream
//// becomes a failed turn, never a wedged request.
////
//// The LLM stream task deliberately pulls dream's *yielder* (blocking is
//// fine in a dedicated process) and forwards raw chunks here, where the
//// pure decode pipeline (ssevents -> openai_compat stream decoder ->
//// engine/stream FSM -> loop events) runs. dream's message-based
//// streaming is not used: it doesn't support recorder playback, which the
//// hermetic test suite depends on.
////
//// The driver makes no domain decisions. It executes sends (best-effort:
//// a failed conn write is reported to the loop once as ClientDisconnected
//// and the loop owns the policy), spawns effects, and stamps events with
//// elapsed time.

import atuin_ai_core/domain/tools.{type ToolDefinition}
import atuin_ai_core/domain/usage
import atuin_ai_core/engine/loop
import atuin_ai_core/engine/stream as engine_stream
import atuin_ai_core/engine/turn
import atuin_ai_core/ffi/callers
import atuin_ai_core/ffi/clock
import atuin_ai_core/ffi/log
import atuin_ai_core/ffi/plug.{type PlugConn}
import atuin_ai_core/http/request
import atuin_ai_core/http/streaming
import atuin_ai_core/http/trace
import atuin_ai_core/http/trace_payloads
import atuin_ai_core/llm/client as chat
import atuin_ai_core/llm/fireworks
import atuin_ai_core/llm/openai_compat/stream as sse_stream
import atuin_ai_core/llm/openai_endpoint
import atuin_ai_core/llm/openrouter
import dream_http_client/client as dream
import gleam/bytes_tree
import gleam/dynamic
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/yielder
import ssevents

/// Longest the driver will wait for *anything* to arrive — a stream chunk
/// (OpenRouter heartbeats during long prompt processing, so silence this
/// long means a dead connection) or a tool completion (the web tools'
/// own HTTP timeouts are shorter than this). On expiry the in-flight work
/// is killed and the turn ends through the loop as a failure, so a
/// blackholed upstream can't hold the request open forever.
const inactivity_timeout_ms = 60_000

/// Which LLM backend serves this turn, with that adapter's options. All
/// backends share the OpenAI-compatible wire shape and SSE decoding;
/// only request preparation differs.
pub type LlmOptions {
  OpenRouter(openrouter.OpenRouterOptions)
  Fireworks(fireworks.FireworksOptions)
  /// A custom OpenAI-compatible endpoint (Ollama, vLLM, LM Studio, ...) —
  /// the self-hosted route.
  OpenAiEndpoint(openai_endpoint.Options)
}

pub type Context {
  Context(
    session_id: String,
    options: LlmOptions,
    /// The dream request each LLM call starts from — `dream.new` in
    /// production, or one with a playback recorder attached in tests.
    base_request: dream.ClientRequest,
    /// Built once per request: must stay byte-identical across the loop's
    /// iterations so the prompt-cache prefix survives.
    system: Option(String),
    messages: List(request.Message),
    /// Appended as the final user message of every LLM call, after the
    /// cache breakpoints — never stored in the loop's conversation.
    turn_context: Option(String),
    tools: List(ToolDefinition),
    /// Which tool calls this server executes itself, from the instance's
    /// registrations.
    is_server_tool: fn(String) -> Bool,
    /// Executes one server tool, returning an error tool result (never a
    /// failure) when the tool is unknown or its upstream breaks. Runs in a
    /// spawned process, so the closure must not touch the conn.
    execute_tool: fn(turn.ToolCall) -> turn.ToolResult,
    /// Persists a server-tool result so only a reference streams to the
    /// client; an `Error` streams the full content inline instead.
    store_tool_result: fn(turn.ToolResult) -> Result(Nil, Nil),
    /// Sink for trace events. Fire-and-forget and conn-independent — the
    /// driver reports what happened, the host decides where it goes.
    trace: fn(trace.Event) -> Nil,
    /// Governs whether trace payloads carry content or metadata only; see
    /// `trace_payloads`.
    content_policy: trace.ContentPolicy,
    /// Builds the `credits` object for the done event from the turn's
    /// usage, or `None` if the snapshot can't be produced. Injected so the
    /// driver stays free of billing/limits knowledge.
    credits: fn(usage.Usage) -> Option(dynamic.Dynamic),
  )
}

pub type TurnResult {
  TurnResult(
    conn: PlugConn,
    outcome: loop.Outcome,
    /// The loop's accumulated model output (text + summarized tool calls),
    /// recorded as the usage record's response.
    responses: loop.Responses,
  )
}

/// Everything async work sends back to the request process.
type Msg {
  /// One transport chunk from the LLM stream task. Tagged with the
  /// stream's generation so chunks from a superseded stream are dropped.
  StreamChunk(stream_id: Int, chunk: Result(BitArray, String))
  /// The stream task's transport ended (the task is done).
  StreamExhausted(stream_id: Int)
  /// One server tool finished.
  ToolDone(result: turn.ToolResult, duration_ms: Int)
}

/// Runs one full turn and returns the conn plus the loop's outcome. Sends
/// are best-effort: once a send fails the client is treated as gone, the
/// in-flight generation is drained (so its usage still accrues), and the
/// loop finishes via `ClientDisconnected`/`Cancelled`.
pub fn run(conn: PlugConn, ctx: Context) -> TurnResult {
  let conversation =
    list.map(ctx.messages, fn(message) {
      loop.Inherited(role: loop_role(message.role))
    })

  let #(state, dispatch) =
    loop.start(ctx.session_id, conversation, ctx.is_server_tool)
  let driver =
    Driver(
      conn:,
      ctx:,
      inbox: process.new_subject(),
      disconnected: False,
      loop_notified: False,
      stream_id: 0,
      stream_task: None,
      pipeline: None,
      tools_outstanding: [],
      tool_tasks: [],
      callers: callers.callers(),
    )

  let #(driver, outcome, responses) = drive(driver, state, dispatch)
  kill_in_flight(driver)
  TurnResult(conn: driver.conn, outcome:, responses:)
}

type Driver {
  Driver(
    conn: PlugConn,
    ctx: Context,
    inbox: Subject(Msg),
    /// Transport guard only: a dead socket means later send attempts
    /// no-op. What a disconnect *means* is the loop's decision, told to it
    /// once via ClientDisconnected.
    disconnected: Bool,
    loop_notified: Bool,
    /// Generation counter for stream tasks; stale chunks are dropped.
    stream_id: Int,
    stream_task: Option(Pid),
    /// Decode state for the current stream (reset per LLM call).
    pipeline: Option(Pipeline),
    /// id/name of server tools whose completions are still awaited —
    /// driver bookkeeping for deadline synthesis, not domain state.
    tools_outstanding: List(#(String, String)),
    tool_tasks: List(Pid),
    callers: callers.Callers,
  )
}

/// The pure decode chain for one LLM stream.
type Pipeline {
  Pipeline(
    sse: ssevents.DecodeState,
    decoder: sse_stream.Decoder,
    fsm: engine_stream.StreamState,
    started_ms: Int,
  )
}

// ---------------------------------------------------------------------
// The loop: execute a dispatch, then wait for the next event.
// ---------------------------------------------------------------------

fn drive(
  driver: Driver,
  state: loop.State,
  dispatch: loop.Dispatch,
) -> #(Driver, loop.Outcome, loop.Responses) {
  case dispatch {
    loop.Terminal(sends:, outcome:) -> #(
      run_sends(driver, sends),
      outcome,
      state.responses,
    )

    loop.AwaitInput(sends:) -> {
      let driver = run_sends(driver, sends)
      case pending_disconnect(driver) {
        Some(driver) -> step(driver, state, loop.ClientDisconnected)
        None -> await(driver, state)
      }
    }

    loop.AwaitEvent(sends:, trigger:) -> {
      let driver = run_sends(driver, sends)
      // A send in this very batch may have revealed the disconnect; tell
      // the loop before starting new work (it will cancel rather than
      // call the LLM for a client that's gone).
      case pending_disconnect(driver) {
        Some(driver) -> step(driver, state, loop.ClientDisconnected)
        None -> await(start_trigger(driver, trigger), state)
      }
    }
  }
}

fn step(
  driver: Driver,
  state: loop.State,
  event: loop.Event,
) -> #(Driver, loop.Outcome, loop.Responses) {
  let #(state, dispatch) = loop.step(state, event)
  drive(driver, state, dispatch)
}

fn await(
  driver: Driver,
  state: loop.State,
) -> #(Driver, loop.Outcome, loop.Responses) {
  case process.receive(driver.inbox, within: inactivity_timeout_ms) {
    Error(Nil) -> handle_deadline(driver, state)

    Ok(StreamChunk(stream_id, chunk)) if stream_id == driver.stream_id ->
      handle_chunk(driver, state, chunk)
    // A superseded stream still draining; ignore it.
    Ok(StreamChunk(_, _)) -> await(driver, state)

    Ok(StreamExhausted(stream_id)) if stream_id == driver.stream_id -> {
      let driver = Driver(..driver, stream_task: None)
      case state.stream {
        // The transport ended without a terminal provider event.
        loop.Connecting | loop.Streaming ->
          step(
            driver,
            state,
            loop.FromStream(
              engine_stream.StreamFailedEvent(
                engine_stream.TransportFailed(
                  "the LLM stream ended before the response completed",
                ),
                None,
              ),
              elapsed_ms(driver),
            ),
          )
        // Trailing bytes after the loop already moved on; nothing to do.
        _ -> await(driver, state)
      }
    }
    Ok(StreamExhausted(_)) -> await(driver, state)

    Ok(ToolDone(result, duration_ms)) -> {
      let driver =
        Driver(
          ..driver,
          tools_outstanding: list.filter(driver.tools_outstanding, fn(entry) {
            entry.0 != result.id
          }),
        )
      step(driver, state, loop.ToolCompleted(result, duration_ms))
    }
  }
}

// Nothing arrived within the inactivity window: kill the in-flight work
// and end the turn through the loop, so the failure is streamed (when the
// client is still there) and recorded like any other.
fn handle_deadline(
  driver: Driver,
  state: loop.State,
) -> #(Driver, loop.Outcome, loop.Responses) {
  let elapsed = elapsed_ms(driver)
  let outstanding = driver.tools_outstanding
  let driver = kill_in_flight(driver)

  case state.stream {
    loop.Connecting | loop.Streaming ->
      step(
        driver,
        state,
        loop.FromStream(
          engine_stream.StreamFailedEvent(
            engine_stream.TransportFailed(
              "no activity from the LLM stream within "
              <> int.to_string(inactivity_timeout_ms / 1000)
              <> "s",
            ),
            None,
          ),
          elapsed,
        ),
      )

    // The stream is resolved, so the wait was on tools: complete each
    // outstanding one with an error result and let the loop's completion
    // predicate end the iteration.
    _ ->
      case outstanding {
        [] ->
          // Waiting with nothing in flight is a driver bug; fail the turn
          // rather than wait forever.
          step(
            driver,
            state,
            loop.FromStream(
              engine_stream.StreamFailedEvent(engine_stream.StreamCrashed, None),
              elapsed,
            ),
          )
        [#(id, name), ..rest] -> {
          let result =
            turn.ToolResult(
              id: id,
              name: name,
              result: "Tool execution timeout",
              is_error: True,
            )
          let #(state, dispatch) =
            loop.step(state, loop.ToolCompleted(result, 0))
          case rest {
            [] -> drive(driver, state, dispatch)
            _ -> {
              let driver = case dispatch {
                loop.AwaitInput(sends:) -> run_sends(driver, sends)
                _ -> driver
              }
              handle_deadline(Driver(..driver, tools_outstanding: rest), state)
            }
          }
        }
      }
  }
}

fn kill_in_flight(driver: Driver) -> Driver {
  case driver.stream_task {
    Some(pid) -> process.kill(pid)
    None -> Nil
  }
  list.each(driver.tool_tasks, process.kill)
  Driver(
    ..driver,
    stream_task: None,
    pipeline: None,
    tools_outstanding: [],
    tool_tasks: [],
  )
}

fn elapsed_ms(driver: Driver) -> Int {
  case driver.pipeline {
    Some(pipeline) -> clock.monotonic_ms() - pipeline.started_ms
    None -> 0
  }
}

// A send failure the loop hasn't been told about yet. Delivered exactly
// once; the loop owns the policy from there.
fn pending_disconnect(driver: Driver) -> Option(Driver) {
  case driver.disconnected && !driver.loop_notified {
    True -> Some(Driver(..driver, loop_notified: True))
    False -> None
  }
}

// ---------------------------------------------------------------------
// Triggers: spawn the async work that will message the inbox.
// ---------------------------------------------------------------------

fn start_trigger(driver: Driver, trigger: loop.Trigger) -> Driver {
  case trigger {
    loop.CallLlm(conversation, _iteration) -> {
      let messages = conversation_messages(driver.ctx, conversation)
      let chat_req =
        chat.ClientRequest(
          inner: driver.ctx.base_request,
          system: driver.ctx.system,
          messages:,
          turn_context: driver.ctx.turn_context,
          tools: Some(driver.ctx.tools),
        )
      let #(req, provider) = case driver.ctx.options {
        OpenRouter(options) -> #(
          openrouter.prepare_request(options, chat_req),
          usage.Openrouter,
        )
        Fireworks(options) -> #(
          fireworks.prepare_request(options, chat_req),
          usage.Fireworks,
        )
        OpenAiEndpoint(options) -> #(
          openai_endpoint.prepare_request(options, chat_req),
          usage.OpenAiCompatible,
        )
      }

      // Supersede (and stop) any previous stream still draining.
      case driver.stream_task {
        Some(pid) -> process.kill(pid)
        None -> Nil
      }

      let stream_id = driver.stream_id + 1
      let inbox = driver.inbox
      let task =
        process.spawn_unlinked(fn() {
          dream.stream_yielder(req.inner)
          |> yielder.each(fn(chunk) {
            let chunk = case chunk {
              Ok(tree) -> Ok(bytes_tree.to_bit_array(tree))
              Error(reason) -> Error(reason)
            }
            process.send(inbox, StreamChunk(stream_id, chunk))
          })
          process.send(inbox, StreamExhausted(stream_id))
        })

      Driver(
        ..driver,
        stream_id:,
        stream_task: Some(task),
        pipeline: Some(Pipeline(
          sse: ssevents.new_decoder(),
          decoder: sse_stream.new(),
          fsm: engine_stream.new_stream(provider),
          started_ms: clock.monotonic_ms(),
        )),
      )
    }

    loop.ExecuteServerTools(calls) -> {
      let inbox = driver.inbox
      let caller_chain = driver.callers
      let execute = driver.ctx.execute_tool
      let tasks =
        list.map(calls, fn(call) {
          process.spawn_unlinked(fn() {
            callers.put_callers(caller_chain)
            let started_ms = clock.monotonic_ms()
            let result = execute(call)
            let duration_ms = clock.monotonic_ms() - started_ms
            process.send(inbox, ToolDone(result, duration_ms))
          })
        })

      Driver(
        ..driver,
        tools_outstanding: list.map(calls, fn(call) { #(call.id, call.name) }),
        tool_tasks: tasks,
      )
    }
  }
}

// ---------------------------------------------------------------------
// One transport chunk: run it through the pure decode pipeline and feed
// the resulting stream events to the loop.
// ---------------------------------------------------------------------

fn handle_chunk(
  driver: Driver,
  state: loop.State,
  chunk: Result(BitArray, String),
) -> #(Driver, loop.Outcome, loop.Responses) {
  case driver.pipeline {
    None -> await(driver, state)
    Some(pipeline) -> {
      let #(pipeline, events) = decode_chunk(pipeline, chunk)
      feed_events(Driver(..driver, pipeline: Some(pipeline)), state, events)
    }
  }
}

fn feed_events(
  driver: Driver,
  state: loop.State,
  events: List(engine_stream.StreamEvent),
) -> #(Driver, loop.Outcome, loop.Responses) {
  case events {
    [] -> await(driver, state)
    [event, ..rest] -> {
      let #(state, dispatch) =
        loop.step(state, loop.FromStream(event, elapsed_ms(driver)))
      case dispatch {
        loop.AwaitInput(sends:) ->
          feed_events(run_sends(driver, sends), state, rest)
        // The loop left streaming mode; anything further from this chunk
        // is past the terminal event and dropped.
        other -> drive(driver, state, other)
      }
    }
  }
}

fn decode_chunk(
  pipeline: Pipeline,
  chunk: Result(BitArray, String),
) -> #(Pipeline, List(engine_stream.StreamEvent)) {
  case chunk {
    Error(reason) ->
      apply_adapter_events(pipeline, [
        engine_stream.StreamFailed(engine_stream.TransportFailed(reason)),
      ])
    Ok(bytes) ->
      case ssevents.push(pipeline.sse, bytes) {
        Error(_) ->
          apply_adapter_events(pipeline, [
            engine_stream.StreamFailed(engine_stream.StreamProcessingFailed),
          ])
        Ok(#(sse, items)) ->
          list.fold(items, #(Pipeline(..pipeline, sse:), []), fn(acc, item) {
            let #(pipeline, events) = acc
            let #(decoder, adapter_events) =
              sse_stream.push(pipeline.decoder, item)
            let #(pipeline, more) =
              apply_adapter_events(
                Pipeline(..pipeline, decoder:),
                adapter_events,
              )
            #(pipeline, list.append(events, more))
          })
      }
  }
}

fn apply_adapter_events(
  pipeline: Pipeline,
  adapter_events: List(engine_stream.AdapterEvent),
) -> #(Pipeline, List(engine_stream.StreamEvent)) {
  list.fold(adapter_events, #(pipeline, []), fn(acc, adapter_event) {
    let #(pipeline, events) = acc
    let #(fsm, more) = engine_stream.update(pipeline.fsm, adapter_event)
    #(Pipeline(..pipeline, fsm:), list.append(events, more))
  })
}

// ---------------------------------------------------------------------
// The messages for one LLM call.
// ---------------------------------------------------------------------

/// The messages for one LLM call: the client transcript plus whatever
/// tool exchanges the loop has appended this turn. The loop's conversation
/// is append-only — its `Inherited` prefix corresponds one-to-one with
/// `ctx.messages`, which carries the typed originals.
pub fn conversation_messages(
  ctx: Context,
  conversation: List(loop.LoopMessage),
) -> List(request.Message) {
  list.append(ctx.messages, list.filter_map(conversation, appended_message))
}

fn appended_message(message: loop.LoopMessage) -> Result(request.Message, Nil) {
  case message {
    loop.Inherited(..) -> Error(Nil)

    loop.AssistantToolUse(text:, tool_calls:) -> {
      let text_blocks = case text {
        "" -> []
        _ -> [request.TextBlock(text)]
      }
      let tool_blocks =
        list.map(tool_calls, fn(call) {
          request.ToolUse(id: call.id, name: call.name, input: call.input)
        })
      Ok(request.Message(
        role: request.Assistant,
        content: request.Blocks(list.append(text_blocks, tool_blocks)),
      ))
    }

    loop.ToolResultMessage(tool_call_id:, content:) ->
      Ok(request.Message(
        role: request.User,
        content: request.Blocks([
          request.ToolResult(
            tool_use_id: tool_call_id,
            body: request.Inline(content),
            is_error: False,
          ),
        ]),
      ))
  }
}

// ---------------------------------------------------------------------
// Fire-and-forget sends. Best-effort: a failed conn write flips the
// disconnected flag and all later sends no-op, but the turn keeps going so
// usage is still accounted.
// ---------------------------------------------------------------------

fn run_sends(driver: Driver, sends: List(loop.Command)) -> Driver {
  list.fold(sends, driver, execute_send)
}

fn execute_send(driver: Driver, command: loop.Command) -> Driver {
  case command {
    loop.SendTextDelta(text) -> send(driver, streaming.send_text(_, text))
    loop.SendToolCalls(calls) ->
      list.fold(calls, driver, fn(driver, call) {
        send(driver, streaming.send_tool_call(_, call))
      })
    loop.SendStatus(status) ->
      send(driver, streaming.send_status(_, status_string(status)))
    loop.SendDone(usage) -> {
      // Skip the snapshot query when nobody is listening.
      let credits = case driver.disconnected {
        True -> None
        False -> driver.ctx.credits(usage)
      }
      send(driver, streaming.send_done(_, driver.ctx.session_id, usage, credits))
    }
    loop.SendError(message, code) ->
      send(driver, streaming.send_error(_, message, Some(code)))

    // No wire events exist for these yet; the CLI protocol sends completed
    // tool calls only.
    loop.SendReasoningDelta(_) -> driver
    loop.SendToolCallStarted(_, _) -> driver

    loop.SendToolResults(results) ->
      list.fold(results, driver, fn(driver, result) {
        send(driver, streaming.send_tool_result(
          _,
          result,
          driver.ctx.store_tool_result,
        ))
      })

    loop.WarnNoUsageData -> log_warning(driver, "no usage data in LLM response")

    loop.EmitTrace(event) -> {
      driver.ctx.trace(to_trace_event(driver.ctx, event))
      driver
    }
  }
}

fn send(
  driver: Driver,
  send_fn: fn(PlugConn) -> Result(PlugConn, String),
) -> Driver {
  case driver.disconnected {
    True -> driver
    False ->
      case send_fn(driver.conn) {
        Ok(conn) -> Driver(..driver, conn:)
        Error(_reason) -> Driver(..driver, disconnected: True)
      }
  }
}

// ---------------------------------------------------------------------
// Trace events. Payload shapes (and the metadata/content allowlists) live
// in `trace_payloads`.
// ---------------------------------------------------------------------

fn to_trace_event(ctx: Context, event: loop.TraceEvent) -> trace.Event {
  case event {
    loop.LlmRequested(iteration:, event_order:, conversation:) ->
      trace.event(
        event_type: "llm_request",
        event_order:,
        payload: trace_payloads.llm_request(
          policy: ctx.content_policy,
          iteration:,
          model: options_model(ctx.options),
          messages: conversation_messages(ctx, conversation),
          system: ctx.system,
          turn_context: ctx.turn_context,
          tools: ctx.tools,
        ),
      )

    loop.LlmResponded(
      iteration:,
      event_order:,
      text:,
      tool_calls:,
      usage:,
      duration_ms:,
    ) ->
      trace.Event(
        ..trace.event(
          event_type: "llm_response",
          event_order:,
          payload: trace_payloads.llm_response(
            policy: ctx.content_policy,
            iteration:,
            text:,
            tool_calls:,
          ),
        ),
        input_tokens: Some(usage.input_tokens),
        output_tokens: Some(usage.output_tokens),
        cached_tokens: Some(usage.cached_tokens),
        cache_creation_tokens: Some(usage.cache_creation_tokens),
        duration_ms: Some(duration_ms),
      )

    loop.ToolExecuted(iteration: _, event_order:, result:, input:, duration_ms:) ->
      trace.Event(
        ..trace.event(
          event_type: "tool_execution",
          event_order:,
          payload: trace_payloads.tool_execution(
            policy: ctx.content_policy,
            result:,
            input:,
          ),
        ),
        duration_ms: Some(duration_ms),
      )
  }
}

fn options_model(options: LlmOptions) -> String {
  case options {
    OpenRouter(options) -> options.model
    Fireworks(options) -> options.model
    OpenAiEndpoint(options) -> options.model
  }
}

fn status_string(status: loop.Status) -> String {
  case status {
    loop.Thinking -> "thinking"
    loop.Searching -> "searching"
    loop.WaitingForTools -> "waiting_for_tools"
  }
}

fn loop_role(role: request.Role) -> loop.Role {
  case role {
    request.User -> loop.User
    request.Assistant -> loop.Assistant
  }
}

fn log_warning(driver: Driver, message: String) -> Driver {
  log.warning("[cli_chat driver] " <> message)
  driver
}
