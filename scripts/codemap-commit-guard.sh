#!/bin/bash
# PostToolUse hook (Bash): after a `git commit`, if the active checkout still
# has codemap entries pending a refresh, remind Claude to refresh them.
# Codemap entries are LLM-written, so the automation ceiling is
# "detect + insist", not silent rebuild.
#
# Opt-in per project: does nothing unless the active checkout has docs/codemap/.

# Drain stdin first (exiting without reading risks EPIPE on the hook runner).
input=$(cat)

# shellcheck source=scripts/codemap-lib.sh disable=SC1091
. "${BASH_SOURCE[0]%/*}/codemap-lib.sh"

# jq is required to parse the payload. Silent where codemap was never set up;
# loud where a pending refresh could otherwise slip past unnoticed.
if ! command -v jq >/dev/null 2>&1; then
  codemap_nojq_optin || exit 0
  echo "codemap: jq not found on PATH — could not check for a pending codemap refresh after this command; $CODEMAP_JQ_HINT." >&2
  exit 2
fi

# The active checkout comes from the payload's cwd (a worktree entered
# mid-session has its own queue); CLAUDE_PROJECT_DIR alone would consult the
# original checkout's state. Note the scope limit: a `git -C <elsewhere>
# commit` is detected as a commit, but pending work is always evaluated
# against the active checkout, not the -C target.
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
root=$(codemap_root "$cwd") || exit 0

count=$(codemap_pending_count "$root")
[[ "$count" -gt 0 ]] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[[ -n "$cmd" ]] || exit 0

# Quote-aware detection: the tokenizer applies shell quoting rules, so
# `git -C "/path with spaces" commit` fires while `git commit` inside quoted
# text, comments, or tool output does not. See the .awk header for the
# supported grammar. The command text is only scanned, never executed.
[[ -n $(printf '%s' "$cmd" | awk -f "${BASH_SOURCE[0]%/*}/codemap-git-commit.awk") ]] || exit 0

queue=$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P)/codemap-queue.sh
echo "codemap: ${count} file(s) are pending a codemap refresh. If that commit completed a feature: run bash \"$queue\" claim (it prints a token and the paths), refresh those entries, then run bash \"$queue\" complete <token>, and follow up with a commit. Never edit .stale/.stale.claimed by hand, even if an older docs/codemap/README.md says to. (If the commit failed or was an intermediate commit, ignore this and continue.)" >&2
exit 2
