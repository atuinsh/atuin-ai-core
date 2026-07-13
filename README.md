# Atuin AI Core

This library is the core of the Atuin AI server: the host-agnostic chat
engine, in Gleam. It contains the domain logic, the turn loop, the LLM
provider adapters (OpenRouter, Fireworks, and any OpenAI-compatible
endpoint), and the HTTP layer — request decoding, SSE streaming to the
client, and the receive-loop driver that runs a turn.

A deployment composes an `instance.Instance` (the builder in
`src/atuin_ai_core/instance.gleam`) and serves `controller.serve`.
`instance.new(catalog, backend)` is a fully working stateless
deployment; each `with_*` builder call layers on one host concern —
server tools, usage limits, trace recording, tool-result persistence.
[Atuin AI Server](https://github.com/atuinsh/atuin-ai-server) is the
self-hosted deployment, built from the stateless defaults and a single
OpenAI-compatible backend.

The package targets Erlang and expects an Elixir host with Plug (see
the FFI notes in `gleam.toml`). It is consumed as a Gleam git
dependency rather than published to hex.

```sh
gleam test   # the engine's suite; hermetic, replay-fixture driven
```

## License

Apache-2.0; see [LICENSE](LICENSE).
