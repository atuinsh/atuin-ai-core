//// A dream-backed implementation of the web tools' `Transport`, for
//// deployments without a host-side HTTP client of their own (the hosted
//// deployment injects its mockable Elixir transport instead). Status
//// codes survive: `dream.send_with_status` exists for exactly this
//// seam.

import atuin_ai_core/http/web_tools.{type HttpRequest}
import dream_http_client/client as dream
import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/uri

pub fn send(request: HttpRequest) -> Result(#(Int, String), String) {
  use req <- result.try(build(request))
  dream.send_with_status(req)
}

fn build(request: HttpRequest) -> Result(dream.ClientRequest, String) {
  use parsed <- result.try(
    uri.parse(request.url)
    |> result.replace_error("invalid URL: " <> request.url),
  )
  use scheme <- result.try(case parsed.scheme {
    Some("http") -> Ok(http.Http)
    Some("https") -> Ok(http.Https)
    _ -> Error("unsupported URL scheme: " <> request.url)
  })
  use host <- result.try(case parsed.host {
    Some("") | None -> Error("URL has no host: " <> request.url)
    Some(host) -> Ok(host)
  })

  dream.new
  |> dream.method(case request.method {
    web_tools.Get -> http.Get
    web_tools.Post -> http.Post
  })
  |> dream.scheme(scheme)
  |> dream.host(host)
  |> add_port(parsed.port)
  |> dream.path(parsed.path)
  |> add_query(parsed.query)
  |> add_headers(request.headers)
  |> dream.body(request.body)
  |> dream.timeout(request.timeout_ms)
  |> Ok
}

fn add_port(req: dream.ClientRequest, port: option.Option(Int)) {
  case port {
    None -> req
    Some(port) -> dream.port(req, port)
  }
}

fn add_query(req: dream.ClientRequest, query: option.Option(String)) {
  case query {
    None -> req
    Some(query) -> dream.query(req, query)
  }
}

fn add_headers(req: dream.ClientRequest, headers: List(#(String, String))) {
  list.fold(headers, req, fn(req, header) {
    dream.add_header(req, header.0, header.1)
  })
}
