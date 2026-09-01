# Changelog

## Unreleased

## 0.2.1 — 2026-09-01

- Hooks now keep each Git worktree's pending paths in that worktree, including projects located below a monorepo root. Edits made after moving into another checkout no longer update or lose state in the original checkout.
- Edit tracking now reports queue write failures instead of silently losing the edited path. Refresh completion likewise reports batch or token cleanup failures and preserves a retryable state instead of printing a false success message.
- Refreshes now use `scripts/codemap-queue.sh` to claim and complete pending paths. The queue shares a lock with edit tracking, recovers work left by an interrupted refresh, and rejects stale completion tokens. Failed reads, writes, normalization, and snapshot delivery leave the batch pending instead of reporting success or discarding paths.
- Hook payloads are parsed with jq only. Projects with a codemap now get an actionable error when jq is missing instead of falling back to parsing that could mishandle escaped paths or multiline commands.
- Lock recovery now works on Linux. Stale-lock detection asked BSD `stat` first, which GNU `stat` misreads as a file-system query, so on GNU systems a lock left by a crashed process was never reclaimed.
- Commit reminders use a quote-aware awk tokenizer. It recognizes common shell forms such as `git -C "/path with spaces" commit` and command substitutions without treating quoted text, comments, or command output as executed commits.
- Public documentation now explains installation, tracking limits, recovery, and measurement caveats consistently in English, Korean, and Japanese. The recorded experiment is kept in `docs/measurement-notes.md` rather than presented as a general performance claim.
- A separate live Claude Code scenario loads the current checkout with `--plugin-dir` and verifies codemap generation, edit tracking, queue refresh, and commit reminders in a disposable Git project. Its dry-run mode makes no model calls.
- The deterministic test suite now covers worktree routing, concurrent queue operations, interrupted refresh recovery, filesystem cleanup failures, shell quoting, JSON escapes, missing dependencies, and live-scenario setup. It contains 197 checks.

## 0.2.0 — 2026-08-31

Initial release. 0.1.0 below was internal and never published.

- `codemap-init` skill: enumerate sources, fan out parallel read-only Haiku scanners (15–25 files each), write `docs/codemap/`, then diff the entry-path set against the source set before declaring success (NOT FOUND stubs count as failures).
- Entry headings use repo-relative paths, so a `.stale` path maps to exactly one entry.
- SessionStart hook injects the codemap/LSP/grep reading order (~225 tokens), only in projects with `docs/codemap/`.
- Edit/Write hook records edited source paths into `docs/codemap/.stale`. A built-in extension list decides what counts as source, and `docs/codemap/.extensions` extends it; vendored directories are excluded at any depth; under `docs/`, only `docs/codemap/` itself is excluded.
- Commit guard: after a `git commit` with entries pending in `.stale`, remind Claude to refresh them. Detect-and-insist — LLM-written entries can't be rebuilt mechanically, so the hook detects and insists.
- Scanners fold rationale comments (NOTE, WHY, HACK, IMPORTANT, FIXME) into Gotchas lines; the generated README marks hub files.
- Scanner agent is read-only by construction: Read, Grep, Glob, no Bash.
- Hooks drain stdin, then guard before spawning jq (jq optional; non-greedy sed fallback).
- Test suite `tests/run.sh` (32 cases) and CI (shellcheck + tests). README and homepage in EN/KO/JA.

## 0.1.0 (internal, unreleased)

- First working version: scanning skill, stale tracking, session routing injection.
