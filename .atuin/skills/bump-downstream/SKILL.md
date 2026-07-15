---
name: bump-downstream
description: Tag the latest atuin-ai-core commit and update the dependency pin in the downstream consumers (atuin_hub's gleam_cli_chat and atuin-ai-server), cutting a branch in each. Use when a new atuin-ai-core version needs to be rolled out to its consumers.
disable-model-invocation: true
---

# Bump atuin-ai-core in downstream projects

Release the current atuin-ai-core `HEAD` as a tagged version and update the two
downstream consumers to point at it:

- **atuin_hub** — `gleam_cli_chat/gleam.toml` pins `atuin_ai_core` as a git
  dependency by `ref` (a `vX.Y.Z` tag); `gleam_cli_chat/manifest.toml` locks the
  commit SHA.
- **atuin-ai-server** — `mix.exs` pins `:atuin_ai_core` as a git dependency by
  `tag:`; `mix.lock` locks the commit SHA.

## Arguments

ARGUMENTS: $ARGUMENTS

The user may pass project directories and a version bump, in any order, as
`key=value` pairs or plain prose:

- `core=<dir>` — atuin-ai-core checkout (defaults to the current repo if it is
  atuin-ai-core, i.e. its `gleam.toml` has `name = "atuin_ai_core"`)
- `hub=<dir>` — atuin_hub checkout
- `server=<dir>` — atuin-ai-server checkout
- `bump=<major|minor|patch>` or an explicit version like `v0.3.0`

If the hub or server directory is not given and cannot be found at an obvious
sibling path of the core checkout (e.g. `../atuin_hub`, `../atuin-ai-server` —
verify by checking for `gleam_cli_chat/gleam.toml` and `mix.exs` respectively),
ask the user for it. Do not guess.

## Steps

### 1. Tag atuin-ai-core

In the core directory:

1. Confirm the working tree is clean and the checkout is on `main`, up to date
   with `origin/main` (`git fetch` first). If there are unpushed or uncommitted
   changes, stop and ask the user how to proceed.
2. Check whether `HEAD` is already tagged: `git tag --points-at HEAD`.
   - If it has a `vX.Y.Z` tag, use that tag and skip to step 2 — no new tag.
   - Otherwise, find the latest version tag
     (`git tag --sort=-v:refname | head -1`) and compute the next version. Use
     the bump the user specified; if they didn't specify one, ask whether this
     is a patch, minor, or major release — don't assume.
3. Create the tag on `HEAD` (`git tag vX.Y.Z`) and push it
   (`git push origin vX.Y.Z`). The downstream updates fetch from GitHub, so the
   tag must be pushed before continuing.

Record the tag name and the commit SHA it points at.

### 2. Update atuin_hub

In the hub directory:

1. Confirm a clean working tree; fetch and start a branch off the latest
   default branch, e.g. `git switch -c <user>/bump-ai-core-vX.Y.Z origin/main`.
   Follow the repo's existing branch-naming convention if one is evident from
   recent branches.
2. In `gleam_cli_chat/gleam.toml`, update the `ref` of the `atuin_ai_core`
   dependency to the new tag.
3. From `gleam_cli_chat/`, refresh the lockfile:
   `gleam deps update atuin_ai_core` (fall back to `gleam deps download` if
   that fails). Verify `manifest.toml` now records the expected commit SHA from
   step 1.
4. Build to confirm the update compiles: `gleam build` in `gleam_cli_chat/`.
5. Commit `gleam.toml` and `manifest.toml` with a message like
   `Bump atuin_ai_core to vX.Y.Z`.

### 3. Update atuin-ai-server

In the server directory:

1. Same as above: clean tree, branch off the latest default branch.
2. In `mix.exs`, update the `tag:` of the `:atuin_ai_core` dependency to the
   new tag.
3. Refresh the lockfile: `mix deps.update atuin_ai_core`. Verify `mix.lock`
   records the expected commit SHA.
4. Compile to confirm: `mix compile`.
5. Commit `mix.exs` and `mix.lock` with a message like
   `Bump atuin_ai_core to vX.Y.Z`.

### 4. Report

Summarize: the tag created (or reused) and its SHA, and the branch + commit in
each downstream repo. Do not push the downstream branches or open PRs unless
the user asks.

## Notes

- If a downstream repo already pins the target tag, say so and skip it rather
  than making an empty commit.
- If any build or lockfile refresh fails, report the error and stop rather
  than committing a broken pin.
