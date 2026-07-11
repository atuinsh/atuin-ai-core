//// Native execution of the server-side web tools (web_search via Brave,
//// web_scrape via Firecrawl). The HTTP transport is injected — FFI-backed
//// in production (`web_fetch.send`), a stub in tests — so request
//// building, status mapping, and response shaping stay pure.
////
//// These are executors for the instance's server-tool registrations: an
//// `Error` becomes an error tool result for the model to react to, never
//// a failed turn.

import atuin_hub/cli_chat/domain/web_results
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/result
import gleam/uri

pub type Method {
  Get
  Post
}

pub type HttpRequest {
  HttpRequest(
    method: Method,
    url: String,
    headers: List(#(String, String)),
    body: String,
    timeout_ms: Int,
  )
}

/// Performs one HTTP request, returning the response status and body.
/// Transport-level failures (timeouts, DNS, refused connections) come back
/// as an error message.
pub type Transport =
  fn(HttpRequest) -> Result(#(Int, String), String)

pub type Env {
  Env(
    /// Empty string means unconfigured; the tool degrades to an error
    /// result rather than attempting an unauthenticated call.
    brave_api_key: String,
    firecrawl_api_key: String,
    transport: Transport,
  )
}

// ---------------------------------------------------------------------
// web_search (Brave Search API)
// ---------------------------------------------------------------------

pub fn search(env: Env, input: Dynamic) -> Result(String, String) {
  use query <- result.try(
    required_param(input, "query")
    |> result.replace_error("web_search requires 'query' parameter"),
  )
  use api_key <- result.try(configured_key(
    env.brave_api_key,
    "Brave API key not configured",
  ))

  let request =
    HttpRequest(
      method: Get,
      url: "https://api.search.brave.com/res/v1/web/search?"
        <> uri.query_to_string([
        #("q", query),
        #("count", "5"),
        #("search_lang", "en"),
      ]),
      headers: [
        #("X-Subscription-Token", api_key),
        #("Accept", "application/json"),
      ],
      body: "",
      timeout_ms: 10_000,
    )

  case env.transport(request) {
    Ok(#(200, body)) ->
      case parse_json(body) {
        Error(Nil) -> Error("Search failed: invalid JSON response")
        Ok(decoded) ->
          web_results.brave_results(decoded)
          |> result.replace_error("Search failed: unexpected response format")
      }
    Ok(#(429, _)) -> Error("Rate limit exceeded")
    Ok(#(status, _)) -> Error("Search failed: HTTP " <> int.to_string(status))
    Error(reason) -> Error("Search failed: " <> reason)
  }
}

// ---------------------------------------------------------------------
// web_scrape (Firecrawl API)
// ---------------------------------------------------------------------

pub fn scrape(env: Env, input: Dynamic) -> Result(String, String) {
  use url <- result.try(
    required_param(input, "url")
    |> result.replace_error("web_scrape requires 'url' parameter"),
  )
  use api_key <- result.try(configured_key(
    env.firecrawl_api_key,
    "Firecrawl API key not configured",
  ))

  let request =
    HttpRequest(
      method: Post,
      url: "https://api.firecrawl.dev/v1/scrape",
      headers: [
        #("Authorization", "Bearer " <> api_key),
        #("Content-Type", "application/json"),
      ],
      body: json.to_string(
        json.object([
          #("url", json.string(url)),
          #("formats", json.array(["markdown"], json.string)),
          #("onlyMainContent", json.bool(True)),
          #("timeout", json.int(30_000)),
        ]),
      ),
      timeout_ms: 35_000,
    )

  case env.transport(request) {
    Ok(#(200, body)) ->
      case parse_json(body) {
        Error(Nil) -> Error("Scrape failed: invalid JSON response")
        Ok(decoded) ->
          case web_results.firecrawl_result(decoded) {
            Ok(text) -> Ok(text)
            Error(web_results.MissingMarkdown) ->
              Error("Scrape failed: no markdown content returned")
            Error(web_results.UnexpectedScrapeFormat) ->
              Error("Scrape failed: unexpected response format")
          }
      }
    Ok(#(402, _)) -> Error("Payment required for scraping service")
    Ok(#(429, _)) -> Error("Rate limit exceeded")
    Ok(#(status, _)) -> Error("Scrape failed: HTTP " <> int.to_string(status))
    Error(reason) -> Error("Scrape failed: " <> reason)
  }
}

// ---------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------

fn required_param(input: Dynamic, name: String) -> Result(String, Nil) {
  decode.run(input, decode.at([name], decode.string))
  |> result.replace_error(Nil)
}

fn configured_key(key: String, message: String) -> Result(String, String) {
  case key {
    "" -> Error(message)
    _ -> Ok(key)
  }
}

fn parse_json(body: String) -> Result(Dynamic, Nil) {
  json.parse(from: body, using: decode.dynamic)
  |> result.replace_error(Nil)
}
