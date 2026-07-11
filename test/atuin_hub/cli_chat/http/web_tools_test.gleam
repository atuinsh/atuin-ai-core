import atuin_hub/cli_chat/domain/tools/web_scrape
import atuin_hub/cli_chat/domain/tools/web_search
import atuin_hub/cli_chat/engine/turn.{
  type ToolCall, type ToolResult, ToolCall, ToolResult,
}
import atuin_hub/cli_chat/http/web_tools.{
  type Env, type HttpRequest, Env, Get, Post,
}
import atuin_hub/cli_chat/instance
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option
import gleam/string
import support/catalogs

/// Dispatches through the instance's server-tool registrations, the same
/// composition the hosted deployment uses.
fn execute(env: Env, call: ToolCall) -> ToolResult {
  instance.new(catalogs.catalog(), fn(_, _) { option.None })
  |> instance.with_server_tool(web_search.web_search(), web_tools.search(env, _))
  |> instance.with_server_tool(web_scrape.web_scrape(), web_tools.scrape(env, _))
  |> instance.execute_server_tool(call)
}

fn obj(entries: List(#(String, Dynamic))) -> Dynamic {
  entries
  |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) })
  |> dynamic.properties
}

fn search_call(query: String) {
  ToolCall(
    id: "t1",
    name: "web_search",
    input: obj([#("query", dynamic.string(query))]),
  )
}

fn scrape_call(url: String) {
  ToolCall(
    id: "t2",
    name: "web_scrape",
    input: obj([#("url", dynamic.string(url))]),
  )
}

fn env(transport: web_tools.Transport) -> Env {
  Env(
    brave_api_key: "brave-key",
    firecrawl_api_key: "firecrawl-key",
    transport: transport,
  )
}

const brave_body = "{\"web\":{\"results\":[{\"title\":\"Gleam\",\"url\":\"https://gleam.run\",\"description\":\"A language\"}]}}"

// ---------------------------------------------------------------------
// web_search
// ---------------------------------------------------------------------

pub fn web_search_builds_request_and_shapes_results_test() {
  let transport = fn(request: HttpRequest) {
    assert request.method == Get
    assert string.starts_with(
      request.url,
      "https://api.search.brave.com/res/v1/web/search?",
    )
    assert string.contains(request.url, "q=gleam%20actors")
    assert string.contains(request.url, "count=5")
    assert request.headers
      == [
        #("X-Subscription-Token", "brave-key"),
        #("Accept", "application/json"),
      ]
    assert request.timeout_ms == 10_000
    Ok(#(200, brave_body))
  }

  let result = execute(env(transport), search_call("gleam actors"))

  let assert ToolResult(
    id: "t1",
    name: "web_search",
    result: text,
    is_error: False,
  ) = result
  assert string.contains(text, "<title>Gleam</title>")
  assert string.contains(text, "<url>https://gleam.run</url>")
}

pub fn web_search_requires_query_test() {
  let call = ToolCall(id: "t1", name: "web_search", input: obj([]))
  let result = execute(env(fn(_) { panic as "no request expected" }), call)

  assert result
    == ToolResult(
      id: "t1",
      name: "web_search",
      result: "web_search requires 'query' parameter",
      is_error: True,
    )
}

pub fn web_search_requires_configured_key_test() {
  let unconfigured =
    Env(..env(fn(_) { panic as "no request expected" }), brave_api_key: "")
  let result = execute(unconfigured, search_call("gleam"))

  assert result.is_error
  assert result.result == "Brave API key not configured"
}

pub fn web_search_maps_statuses_to_errors_test() {
  let cases = [
    #(429, "Rate limit exceeded"),
    #(500, "Search failed: HTTP 500"),
    #(403, "Search failed: HTTP 403"),
  ]

  list.each(cases, fn(pair) {
    let #(status, message) = pair
    let result =
      execute(env(fn(_) { Ok(#(status, "irrelevant")) }), search_call("gleam"))
    assert result.is_error
    assert result.result == message
  })
}

pub fn web_search_transport_error_test() {
  let result = execute(env(fn(_) { Error("timeout") }), search_call("gleam"))
  assert result.is_error
  assert result.result == "Search failed: timeout"
}

pub fn web_search_invalid_json_test() {
  let result =
    execute(
      env(fn(_) { Ok(#(200, "<html>not json</html>")) }),
      search_call("gleam"),
    )
  assert result.is_error
  assert result.result == "Search failed: invalid JSON response"
}

pub fn web_search_unexpected_shape_test() {
  let result =
    execute(
      env(fn(_) { Ok(#(200, "{\"unexpected\":true}")) }),
      search_call("gleam"),
    )
  assert result.is_error
  assert result.result == "Search failed: unexpected response format"
}

// ---------------------------------------------------------------------
// web_scrape
// ---------------------------------------------------------------------

pub fn web_scrape_builds_request_and_shapes_markdown_test() {
  let transport = fn(request: HttpRequest) {
    assert request.method == Post
    assert request.url == "https://api.firecrawl.dev/v1/scrape"
    assert request.headers
      == [
        #("Authorization", "Bearer firecrawl-key"),
        #("Content-Type", "application/json"),
      ]
    assert string.contains(request.body, "\"url\":\"https://example.com\"")
    assert string.contains(request.body, "\"formats\":[\"markdown\"]")
    assert request.timeout_ms == 35_000
    Ok(#(200, "{\"data\":{\"markdown\":\"# Example Content\"}}"))
  }

  let result = execute(env(transport), scrape_call("https://example.com"))

  let assert ToolResult(
    id: "t2",
    name: "web_scrape",
    result: text,
    is_error: False,
  ) = result
  assert string.contains(text, "# Example Content")
}

pub fn web_scrape_requires_url_test() {
  let call = ToolCall(id: "t2", name: "web_scrape", input: obj([]))
  let result = execute(env(fn(_) { panic as "no request expected" }), call)

  assert result.is_error
  assert result.result == "web_scrape requires 'url' parameter"
}

pub fn web_scrape_requires_configured_key_test() {
  let unconfigured =
    Env(..env(fn(_) { panic as "no request expected" }), firecrawl_api_key: "")
  let result = execute(unconfigured, scrape_call("https://x.com"))

  assert result.is_error
  assert result.result == "Firecrawl API key not configured"
}

pub fn web_scrape_maps_statuses_to_errors_test() {
  let cases = [
    #(402, "Payment required for scraping service"),
    #(429, "Rate limit exceeded"),
    #(500, "Scrape failed: HTTP 500"),
  ]

  list.each(cases, fn(pair) {
    let #(status, message) = pair
    let result =
      execute(
        env(fn(_) { Ok(#(status, "irrelevant")) }),
        scrape_call("https://x.com"),
      )
    assert result.is_error
    assert result.result == message
  })
}

pub fn web_scrape_missing_markdown_test() {
  let result =
    execute(
      env(fn(_) { Ok(#(200, "{\"data\":{\"html\":\"<p>hi</p>\"}}")) }),
      scrape_call("https://x.com"),
    )
  assert result.is_error
  assert result.result == "Scrape failed: no markdown content returned"
}

// ---------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------

pub fn unknown_tools_yield_error_results_test() {
  let call = ToolCall(id: "t9", name: "not_a_tool", input: obj([]))
  let result = execute(env(fn(_) { panic as "no request expected" }), call)

  assert result
    == ToolResult(
      id: "t9",
      name: "not_a_tool",
      result: "Unknown tool: not_a_tool",
      is_error: True,
    )
}
