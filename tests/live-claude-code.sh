#!/bin/bash
# End-to-end Claude Code validation for the local codemap plugin checkout.
# This is intentionally separate from tests/run.sh: --live calls a model and
# may consume paid tokens, while --dry-run is deterministic and free.

set -u

usage() {
  cat <<'EOF'
Usage:
  bash tests/live-claude-code.sh --dry-run [--keep]
  bash tests/live-claude-code.sh --live [--keep]

Modes:
  --dry-run  Build an isolated fixture and print all four Claude commands.
             No model calls are made and authentication is not required.
  --live     Run the real Claude Code sessions and verify their filesystem,
             Git, queue, hook, and codemap results.

Options:
  --keep     Preserve a successful temporary project and its JSONL logs.
             Failed runs and CODEMAP_LIVE_WORKDIR runs are always preserved.

Environment:
  CODEMAP_LIVE_WORKDIR        Use this empty/nonexistent directory as the fixture.
  CODEMAP_LIVE_CLAUDE         Claude Code executable (default: claude).
  CODEMAP_LIVE_MODEL          Claude model or alias (default: sonnet).
  CODEMAP_LIVE_MAX_BUDGET_USD Per-session cost ceiling (default: 0.50).
EOF
}

die() {
  printf 'live-codemap: %s\n' "$1" >&2
  exit 1
}

mode=""
keep=0
while (( $# > 0 )); do
  case "$1" in
    --dry-run|--live)
      [[ -z "$mode" ]] || die "choose exactly one of --dry-run or --live"
      mode="$1"
      ;;
    --keep) keep=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done
[[ -n "$mode" ]] || { usage >&2; die "choose --dry-run or --live"; }

for command_name in bash git jq; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
done

test_dir=$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P) || die "cannot resolve the tests directory"
plugin_root=$(cd "$test_dir/.." 2>/dev/null && pwd -P) || die "cannot resolve the plugin root"
[[ -f "$plugin_root/.claude-plugin/plugin.json" ]] || die "plugin manifest not found under $plugin_root"

claude_bin="${CODEMAP_LIVE_CLAUDE:-claude}"
if [[ "$mode" == "--live" ]]; then
  command -v "$claude_bin" >/dev/null 2>&1 || die "Claude Code executable not found: $claude_bin"
  auth_json=$("$claude_bin" auth status 2>/dev/null || true)
  if ! printf '%s' "$auth_json" | jq -e '.loggedIn == true' >/dev/null 2>&1 \
    && [[ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${CLAUDE_CODE_USE_BEDROCK:-}${CLAUDE_CODE_USE_VERTEX:-}${CLAUDE_CODE_USE_FOUNDRY:-}" ]]; then
    die "Claude Code is not authenticated. Run '$claude_bin auth login' or configure a supported API provider, then retry --live"
  fi
fi

owns_work=0
tmp_base="${TMPDIR:-/tmp}"
tmp_base="${tmp_base%/}"
tmp_base=$(cd "$tmp_base" 2>/dev/null && pwd -P) || die "cannot resolve the temporary directory"
if [[ -n "${CODEMAP_LIVE_WORKDIR:-}" ]]; then
  work="$CODEMAP_LIVE_WORKDIR"
  if [[ -d "$work" && -n "$(find "$work" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    die "CODEMAP_LIVE_WORKDIR must be empty or nonexistent: $work"
  fi
  mkdir -p "$work" || die "cannot create $work"
else
  work=$(mktemp -d "$tmp_base/claude-codemap-live.XXXXXX") || die "cannot create a temporary project"
  owns_work=1
fi
work=$(cd "$work" 2>/dev/null && pwd -P) || die "cannot resolve the fixture path"

cleanup() {
  rc=$?
  if (( owns_work == 1 && keep == 0 && rc == 0 )); then
    case "$work" in
      "$tmp_base"/claude-codemap-live.*) rm -rf -- "$work" ;;
      *) printf 'live-codemap: refusing to remove unexpected path: %s\n' "$work" >&2 ;;
    esac
  else
    printf 'live-codemap: preserved fixture and logs at %s\n' "$work" >&2
  fi
}
trap cleanup EXIT

mkdir -p "$work/src" "$work/logs" || die "cannot create fixture directories"
cat > "$work/src/inventory.ts" <<'EOF'
export interface InventoryItem {
  sku: string;
  quantity: number;
}

export const LOW_STOCK_THRESHOLD = 3;

export function countLowStock(items: InventoryItem[]): number {
  return items.filter((item) => item.quantity < LOW_STOCK_THRESHOLD).length;
}
EOF
cat > "$work/src/report.ts" <<'EOF'
import { countLowStock, type InventoryItem } from "./inventory";

export function formatInventoryReport(items: InventoryItem[]): string {
  return "inventory-report:" + countLowStock(items);
}
EOF
cat > "$work/README.md" <<'EOF'
# codemap live fixture

Small disposable TypeScript project used only by the live plugin scenario.
EOF

git init -q -b main "$work" || die "failed to initialize the fixture repository"
git -C "$work" config user.name "codemap live test"
git -C "$work" config user.email "codemap-live@example.invalid"
git -C "$work" add README.md src
git -C "$work" commit -qm "fixture: initial state" || die "failed to commit the fixture"

model="${CODEMAP_LIVE_MODEL:-sonnet}"
budget="${CODEMAP_LIVE_MAX_BUDGET_USD:-0.50}"
[[ "$budget" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "CODEMAP_LIVE_MAX_BUDGET_USD must be a non-negative number"

claude_args=(
  "$claude_bin" -p
  --plugin-dir "$plugin_root"
  --setting-sources project
  --strict-mcp-config
  --no-chrome
  --no-session-persistence
  --permission-mode acceptEdits
  --tools "Bash,Read,Write,Edit,Glob,Grep,Agent"
  --allowedTools "Bash,Read,Write,Edit,Glob,Grep,Agent"
  --output-format stream-json
  --include-hook-events
  --verbose
  --max-budget-usd "$budget"
  --model "$model"
  --append-system-prompt "This is an isolated local integration test. Work only inside the current directory. Do not access the network or any path outside the current directory. Follow the phase prompt exactly."
)

phase_log=""
phase_stderr=""
run_phase() {
  local phase="$1" prompt="$2" slug="$3" rc result_summary
  phase_log="$work/logs/$slug.jsonl"
  phase_stderr="$work/logs/$slug.stderr.log"
  printf '\n[%s]\n' "$phase"
  if [[ "$mode" == "--dry-run" ]]; then
    printf '  (cd %q &&' "$work"
    printf ' %q' "${claude_args[@]}" "$prompt"
    printf ') > %q 2> %q\n' "$phase_log" "$phase_stderr"
    return 0
  fi

  (cd "$work" && CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 "${claude_args[@]}" "$prompt") > "$phase_log" 2> "$phase_stderr"
  rc=$?
  if (( rc != 0 )); then
    printf 'live-codemap: Claude exited %s during %s\n' "$rc" "$phase" >&2
    tail -30 "$phase_stderr" >&2
    return 1
  fi
  if ! jq -s -e '[.[] | select(.type == "result")] | last | .subtype == "success"' "$phase_log" >/dev/null 2>&1; then
    printf 'live-codemap: Claude did not report success during %s\n' "$phase" >&2
    tail -20 "$phase_log" >&2
    return 1
  fi
  result_summary=$(jq -sr '[.[] | select(.type == "result")] | last | "turns=\(.num_turns // "?") cost_usd=\(.total_cost_usd // "?")"' "$phase_log")
  printf '  Claude completed: %s\n' "$result_summary"
}

pass() { printf '  PASS: %s\n' "$1"; }
require() {
  local description="$1"
  shift
  if "$@"; then pass "$description"; else die "$description"; fi
}
queue_pending() { bash "$plugin_root/scripts/codemap-queue.sh" pending "$work" 2>/dev/null; }
no_not_found() { ! grep -Rqs 'NOT FOUND' "$work/docs/codemap"; }

init_prompt=$(cat <<'EOF'
/codemap:codemap-init

Create a complete codemap for this project. This fixture intentionally has fewer than 30 source files; I understand the maintenance warning and explicitly approve continuing. Index both TypeScript files, do not modify anything under src/, and perform the mandatory set-equality and NOT FOUND checks before finishing.
EOF
)

edit_prompt='Use the Edit tool to insert this exact line immediately after LOW_STOCK_THRESHOLD in src/inventory.ts:
export const LIVE_REFRESH_MARKER = "phase-2";

Do not edit docs/codemap, do not run the codemap queue, and do not run Git commands. This phase tests only whether the plugin hook records the source edit. Stop immediately after the source edit succeeds.'

refresh_prompt='Follow the codemap instructions injected at session start. Refresh every currently pending codemap entry through the plugin queue: claim the batch, update the matching entry from the current source, then complete the same token. Do not modify source files. Before finishing, verify that the queue reports zero pending paths.'

commit_prompt='This phase tests the codemap commit reminder. First use the Edit tool to change the string "inventory-report:" to "live-inventory-report:" in src/report.ts. Then use Bash to run exactly:
git add src/report.ts && git commit -m "live hook check"

Do not refresh the codemap and do not run any more tools after that Bash call. The pending queue must remain for the test harness to inspect. Stop after reporting what happened.'

run_phase "1/4 init" "$init_prompt" "01-init" || exit 1
if [[ "$mode" == "--live" ]]; then
  require "codemap README was generated" test -s "$work/docs/codemap/README.md"
  require "inventory entry was generated" grep -Rqs '^### src/inventory.ts' "$work/docs/codemap"
  require "report entry was generated" grep -Rqs '^### src/report.ts' "$work/docs/codemap"
  require "generation contains no NOT FOUND marker" no_not_found
  require "generation did not modify source files" git -C "$work" diff --quiet -- src
  require "initial queue is empty" test "$(queue_pending)" = "0"
fi

run_phase "2/4 edit" "$edit_prompt" "02-edit" || exit 1
if [[ "$mode" == "--live" ]]; then
  require "Claude made the requested source edit" grep -qxF 'export const LIVE_REFRESH_MARKER = "phase-2";' "$work/src/inventory.ts"
  require "PostToolUse recorded src/inventory.ts" grep -qxF 'src/inventory.ts' "$work/docs/codemap/.stale"
  require "queue reports one pending path" test "$(queue_pending)" = "1"
  require "SessionStart injected codemap context" grep -Fq '[codemap]' "$phase_log"
fi

run_phase "3/4 refresh" "$refresh_prompt" "03-refresh" || exit 1
if [[ "$mode" == "--live" ]]; then
  require "refreshed entry includes the new symbol" grep -Rqs 'LIVE_REFRESH_MARKER' "$work/docs/codemap"
  require "refresh completed the pending batch" test "$(queue_pending)" = "0"
  require "refresh left no claimed batch" test ! -e "$work/docs/codemap/.stale.claimed"
  require "refresh left no claim token" test ! -e "$work/docs/codemap/.stale.claim-token"
fi

run_phase "4/4 commit-guard" "$commit_prompt" "04-commit-guard" || exit 1
if [[ "$mode" == "--live" ]]; then
  require "Claude made the commit-phase source edit" grep -q 'live-inventory-report:' "$work/src/report.ts"
  require "Claude created the requested Git commit" test "$(git -C "$work" log -1 --format=%s)" = "live hook check"
  require "commit hook emitted the pending-refresh reminder" grep -Fq 'pending a codemap refresh' "$phase_log" "$phase_stderr"
  require "commit-phase edit remains pending" grep -qxF 'src/report.ts' "$work/docs/codemap/.stale"
fi

if [[ "$mode" == "--dry-run" ]]; then
  printf '\nDry run ready: all four phases were constructed; no model calls were made.\n'
else
  printf '\nLIVE CODEMAP VALIDATION PASSED\n'
fi
printf 'Fixture: %s\n' "$work"
