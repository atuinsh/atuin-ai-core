/// Milliseconds on the BEAM's monotonic clock. Only differences are
/// meaningful; the absolute value can be negative.
@external(erlang, "atuin_ai_clock_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int
