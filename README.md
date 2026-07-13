# Atuin AI Core

This library is the core of the Atuin AI server: the host-agnostic chat
engine, in Gleam. It contains the domain logic, the turn loop, the LLM
provider adapters (OpenRouter, Fireworks, and any OpenAI-compatible
endpoint), and the host-agnostic HTTP layer — request decoding, SSE
streaming to the client, and the receive-loop driver that runs a turn.

A deployment composes an `instance.Instance` (the builder in
`src/atuin_hub/cli_chat/instance.gleam`) and serves `controller.serve`.
`instance.new(catalog, backend)` is a fully working stateless
deployment; each `with_*` builder call layers on one host concern —
server tools, usage limits, trace recording, tool-result persistence.
Two consumers live in this repository:

- `../gleam_cli_chat` — the hosted composition root (Atuin Hub), which
  layers on web tools, credit limits, and recording backed by the hub's
  Elixir services.
- `../cli_chat_standalone` — the self-hosted Atuin AI Server, which uses
  the stateless defaults and a single OpenAI-compatible backend.

The package targets Erlang and expects an Elixir host with Plug (see the
FFI notes in `gleam.toml`). Modules keep their historical `atuin_hub/...`
paths until the package is published under its public name.

```sh
gleam test   # the engine's suite; hermetic, replay-fixture driven
```
