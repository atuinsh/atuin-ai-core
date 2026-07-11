//// The host-side caller-ancestry chain (`$callers`), captured in the
//// request process and re-established inside spawned tool processes so
//// test expectations and telemetry attribution survive the spawn. The
//// key is an Elixir-ecosystem convention (Task, Mox); under a host that
//// doesn't use it, the chain is carried but never read.

pub type Callers

@external(erlang, "callers_ffi", "callers")
pub fn callers() -> Callers

@external(erlang, "callers_ffi", "put_callers")
pub fn put_callers(callers: Callers) -> Nil
