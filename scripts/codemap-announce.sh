#!/bin/bash
# SessionStart hook: if the active checkout has a codemap, inject the usage
# rules into context so Claude consults the index instead of re-exploring with
# grep. Emits nothing (zero context cost) in projects without docs/codemap/.

# Drain stdin first — exiting without reading the runner's payload risks a
# spurious EPIPE hook error, same as in the sibling hooks.
input=$(cat)

# shellcheck source=scripts/codemap-lib.sh disable=SC1091
. "${BASH_SOURCE[0]%/*}/codemap-lib.sh"

# jq is required by all three hooks. SessionStart stdout lands in context, so
# this is the one place the missing dependency can be reported without
# repeating itself on every edit; the tracking hooks stay disabled until then.
if ! command -v jq >/dev/null 2>&1; then
  codemap_nojq_optin || exit 0
  echo "[codemap] This project has a codemap (docs/codemap/), but jq is not on PATH, so stale tracking and commit reminders are disabled — $CODEMAP_JQ_HINT."
  exit 0
fi

# Resolve the active checkout from the payload's cwd — a session resumed
# inside a git worktree must announce that worktree's queue, not the original
# checkout's (CLAUDE_PROJECT_DIR keeps pointing at the original root).
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
root=$(codemap_root "$cwd") || exit 0

stale_count=$(codemap_pending_count "$root")
queue=$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P)/codemap-queue.sh

cat <<EOF
[codemap] This project maintains a semantic code index at docs/codemap/ (per-file summaries: role, key symbols, dependencies, gotchas).
- Before exploring structure or flow ("how does X work?", "which file owns Y?"), read docs/codemap/README.md and the relevant module file first — do not start with broad grep sweeps. When delegating exploration to subagents, tell them to consult docs/codemap/ first.
- For exact symbol locations, references, and call hierarchies, prefer the LSP tool (goToDefinition / findReferences / documentSymbol / incomingCalls) over grep when a language server is available.
- Edits to source files are auto-recorded in docs/codemap/.stale. Before a feature-complete commit, refresh the pending entries: run bash "$queue" claim (it prints a token and the claimed paths), refresh each path's entry, then run bash "$queue" complete <token>. If a refresh was interrupted, running claim again recovers its batch. Never edit .stale/.stale.claimed by hand and never clear them wholesale — files recorded while you refresh must stay queued — even if an older docs/codemap/README.md describes manual steps.
- If the codemap disagrees with the code, the code is canonical — fix the codemap.
EOF

if [[ "$stale_count" -gt 0 ]]; then
  echo "- Currently $stale_count stale file(s) pending a codemap refresh (see docs/codemap/.stale and, if a refresh was interrupted, .stale.claimed)."
fi
exit 0
