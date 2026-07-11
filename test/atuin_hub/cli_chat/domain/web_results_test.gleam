import atuin_hub/cli_chat/domain/web_results.{
  MissingMarkdown, UnexpectedScrapeFormat, UnexpectedSearchFormat,
}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string

fn obj(entries: List(#(String, Dynamic))) -> Dynamic {
  entries
  |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) })
  |> dynamic.properties
}

fn search_body(results: List(Dynamic)) -> Dynamic {
  obj([#("web", obj([#("results", dynamic.list(results))]))])
}

fn search_result(title: String, url: String, description: String) -> Dynamic {
  obj([
    #("title", dynamic.string(title)),
    #("url", dynamic.string(url)),
    #("description", dynamic.string(description)),
  ])
}

pub fn formats_and_escapes_results_test() {
  let assert Ok(text) =
    web_results.brave_results(
      search_body([search_result("A <b> title", "https://x", "desc & more")]),
    )
  assert string.contains(text, "<title>A &lt;b&gt; title</title>")
  assert string.contains(text, "<description>desc &amp; more</description>")
  assert string.starts_with(text, "This data comes from an external source.")
}

pub fn takes_at_most_three_results_test() {
  let results = list.repeat(search_result("t", "u", "d"), 5)
  let assert Ok(text) = web_results.brave_results(search_body(results))
  assert list.length(string.split(text, "<result>")) == 4
}

pub fn missing_fields_get_placeholders_test() {
  let assert Ok(text) = web_results.brave_results(search_body([obj([])]))
  assert string.contains(text, "<title>No title</title>")
  assert string.contains(text, "<url>No URL</url>")
  assert string.contains(text, "<description>No description</description>")
}

pub fn malformed_result_item_degrades_test() {
  // A non-map item renders placeholders instead of crashing the search
  let assert Ok(text) =
    web_results.brave_results(search_body([dynamic.int(42)]))
  assert string.contains(text, "<title>No title</title>")
}

pub fn empty_results_test() {
  let assert Ok("No search results found.") =
    web_results.brave_results(search_body([]))
}

pub fn unexpected_search_shape_test() {
  assert web_results.brave_results(obj([])) == Error(UnexpectedSearchFormat)
  assert web_results.brave_results(
      obj([#("web", obj([#("results", dynamic.string("nope"))]))]),
    )
    == Error(UnexpectedSearchFormat)
}

pub fn firecrawl_markdown_wraps_and_escapes_test() {
  let body =
    obj([#("data", obj([#("markdown", dynamic.string("# Hi <there>"))]))])
  let assert Ok(text) = web_results.firecrawl_result(body)
  assert string.contains(text, "<result>\n# Hi &lt;there&gt;\n</result>")
}

pub fn firecrawl_missing_markdown_test() {
  assert web_results.firecrawl_result(obj([#("data", obj([]))]))
    == Error(MissingMarkdown)
  assert web_results.firecrawl_result(
      obj([#("data", obj([#("markdown", dynamic.int(5))]))]),
    )
    == Error(MissingMarkdown)
}

pub fn firecrawl_unexpected_shape_test() {
  assert web_results.firecrawl_result(obj([])) == Error(UnexpectedScrapeFormat)
}
