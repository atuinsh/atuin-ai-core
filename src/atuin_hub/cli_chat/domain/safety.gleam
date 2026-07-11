//// Three-tier safety detection for shell commands.
////
//// Tier 1: Quick keyword presence check (<10us)
//// Tier 2: Context classification (is it in executable context?)
//// Tier 3: Full regex pattern matching on executable spans

import gleam/list
import gleam/regexp
import gleam/string

pub type Category {
  DestructiveDelete
  DiskOverwrite
  FilesystemDestroy
  PermissionRisk
  PipeToShell
  ForkBomb
}

pub type Warning {
  Warning(category: Category, message: String)
}

pub type Verdict {
  Safe
  Unsafe(warnings: List(Warning))
}

const dangerous_keywords = ["rm", "dd", "mkfs", "wipefs", "format", "shred"]

fn patterns() -> List(#(String, Category, String)) {
  [
    #(
      "rm\\s+-[rf]*r[rf]*\\s+(/|~|\\$HOME|\\*)",
      DestructiveDelete,
      "Recursive delete of critical directory",
    ),
    #(
      "dd\\s+.*of=/dev/[sh]d",
      DiskOverwrite,
      "Direct disk write - will destroy data",
    ),
    #(
      "mkfs|wipefs|sgdisk",
      FilesystemDestroy,
      "Filesystem destruction operation",
    ),
    #(
      "chmod\\s+-R\\s+777",
      PermissionRisk,
      "Recursive 777 permissions - security risk",
    ),
    #(
      "curl.*\\|\\s*(ba)?sh|wget.*\\|\\s*(ba)?sh",
      PipeToShell,
      "Piping download to shell - code execution risk",
    ),
    #(
      ":()\\s*\\{\\s*:\\s*\\|\\s*:\\s*&\\s*\\}\\s*;\\s*:",
      ForkBomb,
      "Fork bomb detected",
    ),
  ]
}

pub fn check_safety(command: String) -> Verdict {
  case has_dangerous_keywords(command) {
    False -> Safe
    True ->
      // Tier 2 is simplified: treat as executable unless it's a comment
      case is_comment(command) {
        True -> Safe
        False -> check_patterns(command)
      }
  }
}

fn has_dangerous_keywords(command: String) -> Bool {
  let lower = string.lowercase(command)
  list.any(dangerous_keywords, string.contains(lower, _))
}

fn is_comment(command: String) -> Bool {
  string.starts_with(string.trim(command), "#")
}

fn check_patterns(command: String) -> Verdict {
  let warnings =
    patterns()
    |> list.filter_map(fn(pattern) {
      let #(source, category, message) = pattern
      let assert Ok(re) =
        regexp.compile(
          source,
          regexp.Options(case_insensitive: True, multi_line: False),
        )
      case regexp.check(re, command) {
        True -> Ok(Warning(category:, message:))
        False -> Error(Nil)
      }
    })

  case warnings {
    [] -> Safe
    _ -> Unsafe(warnings)
  }
}
