---
name: codemap-init
description: Use when the user asks to bootstrap, generate, or rebuild a semantic code index for the current project — "create a codemap", "init the codemap", "rebuild the code index", "/codemap-init", "코드맵 만들어", "코드맵 생성", "코드 인덱스 다시 만들어", "コードマップを作って", "コードマップ生成". Generates per-file summaries (docs/codemap/) via parallel scanner agents and enables stale tracking through the codemap plugin hook.
---

# codemap-init — bootstrap a semantic code index

Build a per-file map of the whole project — `role · symbols · dependencies · gotchas` — written by Claude after actually reading the code, stored in `docs/codemap/`. Afterwards, structure/flow exploration starts from the codemap instead of grep sweeps; exact symbol locations remain the LSP tool's job. The plugin's SessionStart hook auto-injects usage rules in any project where `docs/codemap/` exists.

## Procedure

### 1. Enumerate sources and judge scale
Run from the project root:
```sh
find <source roots> \( -name node_modules -o -name vendor -o -name .build -o -name build \
    -o -name dist -o -name out -o -name target -o -name Pods -o -name DerivedData -o -name .git \) -prune \
  -o -type f \( -name '*.ts' -o -name '*.py' ... \) -print \
  | sed 's|^\./||' | grep -v '^docs/codemap/'
```
Adjust extensions to the project's languages. The pruned names mirror the tracking hook's exclusions — keep them consistent, and match them as whole directory names: a substring filter like `grep -v 'out/'` would silently drop real sources such as `src/layout/` or `src/checkout/`. The `sed` strips the `./` prefix a `find .` produces, so the list uses the same repo-relative form as entry headings and `.stale` lines. Report the total count to the user.
- **Under ~30 files**: warn that codemap maintenance may cost more than it saves; confirm before continuing.
- **Over ~500 files**: propose phased generation (core logic first, UI/utilities as a follow-up).

### 2. Split into buckets
**15–25 files per bucket**, respecting directory/module boundaries. If one directory must be split, split by role (e.g. audio-related vs data-related), not alphabetically.

### 3. Run scanners in parallel
Spawn one `codemap-scanner` agent per bucket (fall back to a general-purpose read-only agent if unavailable), **all in a single message** so they run concurrently. Prompt template:

```
Codemap (semantic index) survey for the project at <project path>.
Read each file below and summarize it per your entry format.
Write in <user's language>.

Files (all under <directory>): <repo-relative file list>
```

List files by their repo-relative path — entry headings reuse these paths verbatim, and the stale-tracking hook records the same form, so this is what lets a stale path be matched to its entry later.

### 4. Write the index files
- Each bucket's result → `docs/codemap/<module>.md`, with a header line: `> See [README.md](README.md) for update rules. Location: <path>`
- Strip any preamble/epilogue sentences and HTML entities (`&gt;` etc.) from agent output before writing.
- `docs/codemap/README.md`: a table (file | coverage) + update rules + generation timestamp and commit hash. Also add a **Hub files** list: from the assembled entries' "Depends on" lines, pick the ~5 most-depended-on files and list them with one line each on why they are load-bearing — changes to these files have the widest blast radius, so check their entries first. The update rules must state:
  - Source edits are auto-recorded in `.stale` by the plugin hook.
  - Before a feature-complete commit, refresh pending entries through the plugin's queue tool `codemap-queue.sh` (the session-start `[codemap]` note and the commit reminder print its full path) — never edit `.stale`/`.stale.claimed` by hand and never clear them wholesale, because edits recorded while the refresh runs (including re-edits of files being refreshed) must stay queued:
    1. Run `codemap-queue.sh claim` — it atomically claims everything pending (recovering any batch an interrupted refresh left behind) and prints a `token <value>` line followed by the claimed paths.
    2. Refresh the entry for every printed path. The hook keeps appending new work to a fresh `.stale` meanwhile.
    3. Run `codemap-queue.sh complete <token>` with the token from step 1. If the refresh fails or is interrupted, skip this — the batch stays counted as pending, and the next `claim` takes it over (issuing a new token; the old one is then refused, so a superseded refresher can never delete another's batch).
  - When codemap and code disagree, the code is canonical — fix the codemap.
  - When files are added/removed/moved, update the module file and the README table.
- `touch docs/codemap/.stale` — **activation switch: the `docs/codemap/` directory turns on all three hooks (session injection, stale tracking, commit guard); the touch gives the queue file a defined empty starting state.**
- If step 1 chose source extensions outside the tracking hook's built-in list (it covers the mainstream languages — see the `case` in the plugin's `codemap-stale.sh`), write those to `docs/codemap/.extensions` (one per line, no dot, e.g. `tf`). The hook records edits matching either its built-in list or this file — the file extends the list, so mainstream extensions never need repeating. Skip the file entirely when the built-in list already covers the project.

### 5. Verify coverage (mandatory — no completion claims without evidence)
Compare the entry set against the source set — set equality, not just counts:
```sh
tmp=$(mktemp -d)   # not fixed /tmp names — concurrent sessions would clobber them
find docs/codemap -name '*.md' ! -name README.md -exec grep -h '^### ' {} + \
  | sed -e 's/^### //' -e 's/ — .*//' | sort > "$tmp/entries.txt"
find <source roots> ... | sort > "$tmp/sources.txt"   # same command as step 1, run from the project root
diff "$tmp/sources.txt" "$tmp/entries.txt"
```
The two-step sed splits headings at the first ` — `, so paths containing spaces survive; running both finds from the project root (with step 1's `./`-stripping `sed`) keeps the two sides in the identical repo-relative form. The diff must be empty, and `grep -rn 'NOT FOUND' docs/codemap/` must find nothing — a NOT FOUND stub means a bucket prompt carried a bad path; fix it and re-run that bucket. Counting alone is not enough: stubs and duplicate entries can make counts match while files are unindexed.

### 6. Wire into project conventions
If the project has a CLAUDE.md, offer to add a one-liner ("consult docs/codemap/ before structural exploration; refresh .stale entries before commit") — skip if you judge the SessionStart injection sufficient. If the project tracks work in TODO/DONE files, record completion there.

## Refreshing later
- One module went stale → re-run just that bucket's scanner and overwrite that module file.
- A path in the pending queue that no longer exists on disk means the file was deleted or moved: after `codemap-queue.sh claim` lists it, remove its entry from the module file and the README table (add an entry under the new path if it moved) — that counts as refreshing the path, so `complete <token>` as usual.
- The project adopts a new language → index the new files with a scanner bucket, and add the extension to `docs/codemap/.extensions` only if the hook's built-in list doesn't cover it.
- Full rebuild → repeat steps 1–6 (overwrite existing files).

## Notes
- Scanners are read-only; the orchestrating session writes all files.
- Never put code snippets in the codemap — stale code is worse than grep. Roles, relationships, and gotchas only.
