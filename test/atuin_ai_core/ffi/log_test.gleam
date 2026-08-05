import atuin_ai_core/ffi/log
import gleeunit/should

pub fn escape_encodes_line_breaks_test() {
  log.escape("line one\nline two\r\nline three\ttab")
  |> should.equal("line one\\nline two\\r\\nline three\\ttab")
}

pub fn escape_drops_other_control_characters_test() {
  // bell, vertical tab, null, ESC, DEL
  log.escape("a\u{7}b\u{B}c\u{0}d\u{1B}e\u{7F}f")
  |> should.equal("abcdef")
}

pub fn escape_drops_c1_control_characters_test() {
  // NEL, single-byte CSI (terminals treat U+009B like `ESC [`), and the
  // C1 range boundaries
  log.escape("a\u{85}b\u{9B}31mc\u{80}d\u{9F}e")
  |> should.equal("ab31mcde")
}

pub fn escape_keeps_printable_unicode_test() {
  log.escape("rate limit exceeded — try again ✓")
  |> should.equal("rate limit exceeded — try again ✓")
}
