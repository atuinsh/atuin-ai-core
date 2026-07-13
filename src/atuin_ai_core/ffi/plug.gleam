import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/result

pub type PlugConn

// SAFETY: shimmed to return result
@external(erlang, "atuin_ai_plug_ffi", "put_resp_header")
pub fn put_resp_header(
  conn: PlugConn,
  key: String,
  value: String,
) -> Result(PlugConn, String)

// SAFETY: shimmed to return result
@external(erlang, "atuin_ai_plug_ffi", "send_chunked")
pub fn send_chunked(conn: PlugConn, status: Int) -> Result(PlugConn, String)

// SAFETY: shimmed to return result
@external(erlang, "atuin_ai_plug_ffi", "put_status")
pub fn put_status(conn: PlugConn, status: Int) -> Result(PlugConn, String)

pub fn chunk(conn: PlugConn, chunk: String) -> Result(PlugConn, String) {
  case do_chunk(conn, chunk) {
    Ok(conn) -> Ok(conn)
    Error(error) -> {
      use error <- result.try(
        decode.run(error, chunk_error_decoder())
        |> result.map_error(fn(_) { "Unknown reply from Plug.Conn.chunk" }),
      )

      Error("Failed to send chunk: " <> error)
    }
  }
}

// Plug.Conn.chunk returns `{:ok, conn}` or `{:error, reason}`, which we can interpret
// directly as a Result. However, the error reason can be an atom or a string, so we
// need to decode it into a String.
//
// SAFETY: does not raise; returns result tuple
@external(erlang, "Elixir.Plug.Conn", "chunk")
fn do_chunk(conn: PlugConn, chunk: String) -> Result(PlugConn, dynamic.Dynamic)

fn chunk_error_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, or: [
    atom.decoder() |> decode.map(atom.to_string),
  ])
}

// SAFETY: shimmed to return result
@external(erlang, "atuin_ai_plug_ffi", "json")
pub fn json(conn: PlugConn, data: dynamic.Dynamic) -> Result(PlugConn, String)

// SAFETY: does not raise; returns raw value
@external(erlang, "Elixir.Plug.Conn", "get_req_header")
pub fn get_req_header(conn: PlugConn, key: String) -> List(String)
