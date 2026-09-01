#!/bin/bash
# PostToolUse hook (Edit|Write): records source-file edits into the owning
# checkout's docs/codemap/.stale so the semantic index can be refreshed before
# the next feature commit.
#
# Opt-in per project: does nothing unless the checkout that owns the edited
# file has docs/codemap/. Bootstrap a project with the `codemap-init` skill.

# Drain stdin first (exiting without reading risks EPIPE on the hook runner).
input=$(cat)

# shellcheck source=scripts/codemap-lib.sh disable=SC1091
. "${BASH_SOURCE[0]%/*}/codemap-lib.sh"

# jq is required to parse the payload. Without it, stay silent in projects
# that never opted in, but where tracking is expected — in the original
# project or in the checkout owning this hook's working directory — say so
# loudly instead of dropping the edit on the floor.
if ! command -v jq >/dev/null 2>&1; then
  codemap_nojq_optin || exit 0
  echo "codemap: jq not found on PATH — this edit was NOT recorded to docs/codemap/.stale; $CODEMAP_JQ_HINT." >&2
  exit 2
fi

file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[[ -n "$file" && "$file" == /* && -f "$file" ]] || exit 0

# .stale is line-based, so a path containing a newline cannot be stored;
# skip it rather than split it into two bogus entries.
case "$file" in *$'\n'*) exit 0 ;; esac

# Canonicalize to the physical path so the containment check below cannot be
# fooled by symlinked prefixes (macOS /tmp -> /private/tmp and the like).
dir=$(cd "${file%/*}" 2>/dev/null && pwd -P) || exit 0
file="$dir/${file##*/}"

# Resolve the checkout that owns the file — not the session's original project
# root: a git worktree keeps its own index and its own .stale.
root=$(codemap_root "$dir") || exit 0
root=$(cd "$root" 2>/dev/null && pwd -P) || exit 0

# Ignore files outside the resolved checkout.
case "$file" in "$root"/*) ;; *) exit 0 ;; esac

# Source files only: the built-in list below, plus any extensions the project
# added via docs/codemap/.extensions (one per line, no dot). The file extends
# the built-in list rather than replacing it, so a language adopted after
# codemap-init keeps being tracked without anyone editing .extensions.
extfile="$root/docs/codemap/.extensions"
if [[ -s "$extfile" ]] && grep -qxF "${file##*.}" "$extfile"; then
  : # project-declared extension
else
  case "$file" in
    *.swift|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.go|*.rs|*.java|*.kt|*.kts|*.c|*.cc|*.cpp|*.h|*.hpp|*.m|*.mm|*.rb|*.php|*.cs|*.scala|*.sh|*.vue|*.svelte|*.dart|*.ex|*.exs|*.lua|*.zig) ;;
    *) exit 0 ;;
  esac
fi

rel="${file#"$root"/}"

# Skip vendored code and build output at any depth, and the codemap tree itself.
# (A blanket docs/* exclusion would silently drop real source hosted under docs/.)
case "$rel" in
  node_modules/*|*/node_modules/*|vendor/*|*/vendor/*|.build/*|*/.build/*|build/*|*/build/*|dist/*|*/dist/*|out/*|*/out/*|target/*|*/target/*|Pods/*|*/Pods/*|DerivedData/*|*/DerivedData/*|.git/*|*/.git/*|docs/codemap/*) exit 0 ;;
esac

stale="$root/docs/codemap/.stale"
# The dedup check and the append run under the same lock codemap-queue.sh
# takes for claim/complete, so a claim can never rename .stale between this
# hook opening its append descriptor and writing the path (that interleaving
# silently dropped the edit). Failing to record must be loud, not silent.
if ! codemap_lock "$root"; then
  echo "codemap: could not acquire docs/codemap/.stale.lock — this edit was NOT recorded to docs/codemap/.stale; re-record it, or if no codemap process is running, remove the stuck .stale.lock (and .stale.lock.breaker if present) by hand." >&2
  exit 2
fi
trap codemap_unlock EXIT
# Dedup against the live queue only — never against .stale.claimed: a re-edit
# of a file some refresh already claimed must be queued again, or completing
# that refresh would clear an entry that is stale again.
grep -qxF "$rel" "$stale" 2>/dev/null && exit 0
# Repair a missing trailing newline (a partial rewrite of .stale can leave one)
# so the append below can't concatenate two paths into one line.
if [[ -s "$stale" && -n "$(tail -c1 "$stale" 2>/dev/null)" ]]; then
  if ! echo >> "$stale"; then
    printf 'codemap: failed to repair docs/codemap/.stale before recording %s; this edit was NOT recorded.\n' "$rel" >&2
    exit 2
  fi
fi
if ! echo "$rel" >> "$stale"; then
  printf 'codemap: failed to write %s to docs/codemap/.stale; this edit was NOT recorded.\n' "$rel" >&2
  exit 2
fi
exit 0
