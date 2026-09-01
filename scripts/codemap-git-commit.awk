# Decides whether a shell command string (stdin, possibly multiline) contains
# an actual `git … commit` invocation. Prints "yes" when one is found, nothing
# otherwise. Never executes or evaluates the input.
#
# The previous regex treated whitespace as a command boundary, so it missed
# `git -C "/path with spaces" commit` and false-fired on `git commit` inside
# quoted text. This scanner tokenizes with shell quoting rules instead.
#
# Supported command grammar (kept in sync with the guard's documentation):
#   - separators: newline ; & | ( ) ` and $(  — covers chains, pipes, subshells;
#     ` and $( also open a command context inside "…" (command substitution
#     executes inside double quotes, so `echo "$(git commit)"` is detected),
#     and the matching closer restores BOTH the enclosing quote context and
#     the interrupted outer command from a stack: text after "$(…)" inside
#     quotes stays literal, a real command after the closing quote is scanned,
#     and an argument containing a substitution stays that command's argument
#     (`git -C "$(pwd)" commit` is detected; `echo "$(git log)" git commit`
#     is not a git invocation) — nesting supported
#   - quoting: '…', "…" (with backslash escapes), bare backslash escapes,
#     backslash-newline line continuation, # comments at word start; empty
#     quoted arguments stay real tokens (`git -C "" commit` is detected)
#   - shell keywords in command position (if/then/elif/else/fi, while/until/
#     do/done, for, case/esac, {, }, !) are skipped, so the commands they
#     govern are scanned
#   - leading VAR=value assignments and the wrappers sudo/command/env/time/
#     nohup/nice are skipped (their own flags are not modeled)
#   - git global flags before the subcommand; -C, -c, --git-dir, --work-tree,
#     --namespace, --config-env consume a following value token
# Not modeled: heredoc bodies (scanned as ordinary lines), expansions ($VAR,
# aliases, functions) — a commit hidden behind those is not detected.

{ buf = buf $0 "\n" }

END {
  n = length(buf)
  w = ""; nw = 0; st = 0; atword = 0; found = 0; depth = 0
  for (i = 1; i <= n; i++) {
    c = substr(buf, i, 1)
    if (st == 1) { # inside '…'
      if (c == "'") st = 0; else w = w c
      continue
    }
    if (st == 2) { # inside "…"
      if (c == "\\") { i++; nc = substr(buf, i, 1); if (nc != "\n") w = w nc; continue }
      if (c == "\"") { st = 0; continue }
      # Command substitution executes inside double quotes: enter a fresh
      # command context and remember the quoted state AND the interrupted
      # outer command on the context stack — only the matching closer
      # restores them (review G3: a single toggle let the closing quote OPEN
      # a new string; review H4: discarding the outer words made the
      # remaining outer arguments scan as a new command).
      if (c == "`") { pushctx("b", 2); continue }
      if (c == "$" && substr(buf, i + 1, 1) == "(") { i++; pushctx("p", 2); continue }
      w = w c
      continue
    }
    if (st == 3) { # inside a comment
      if (c == "\n") { st = 0; endcmd() }
      continue
    }
    if (c == "'") { st = 1; atword = 1; continue }
    if (c == "\"") { st = 2; atword = 1; continue }
    if (c == "\\") { # escape; backslash-newline is a line continuation
      i++; nc = substr(buf, i, 1)
      if (nc != "\n") { w = w nc; atword = 1 }
      continue
    }
    if (c == "#" && atword == 0) { st = 3; continue }
    if (c == " " || c == "\t") { endword(); continue }
    if (c == "\n" || c == ";" || c == "&" || c == "|") { endcmd(); continue }
    # Parens and backticks are tracked on the context stack so a closer can
    # restore the quote context and outer command it interrupted. Bare ( … )
    # subshells push too — otherwise their ) would pop a $( pushed inside
    # double quotes; a subshell ends the command first (it cannot appear
    # mid-command), so its saved outer context is empty.
    if (c == "(") { endcmd(); pushctx("p", 0); continue }
    if (c == "$" && substr(buf, i + 1, 1) == "(") { i++; pushctx("p", 0); continue }
    if (c == ")") {
      endcmd()
      if (depth > 0 && ctype[depth] == "p") popctx()
      continue
    }
    if (c == "`") {
      if (depth > 0 && ctype[depth] == "b") { endcmd(); popctx() }
      else pushctx("b", 0)
      continue
    }
    w = w c; atword = 1
  }
  endcmd()
  if (found) print "yes"
}

function pushctx(t, s,   k) {
  # Open a substitution/subshell context: save the delimiter type, the quote
  # state to restore, and the in-progress outer command (its words, the word
  # under construction, and the word-in-progress flag), then start the inner
  # command from a clean slate (review H4: dropping the outer words made the
  # arguments after the closer scan as a fresh command).
  depth++
  ctype[depth] = t; csave[depth] = s
  snw[depth] = nw; sw[depth] = w; satw[depth] = atword
  for (k = 1; k <= nw; k++) sword[depth, k] = words[k]
  for (k in words) delete words[k]
  nw = 0; w = ""; atword = 0
  st = 0
}

function popctx(   k) {
  # Close the context opened by pushctx: the inner command was already
  # scanned (endcmd runs before this), so restore the interrupted outer
  # command and quote state. atword is forced on because the substitution is
  # itself part of the word under construction — an argument that is only
  # "$(…)" must stay a real (empty) token so value-taking flags like -C
  # still consume it instead of swallowing the next word.
  for (k in words) delete words[k]
  nw = snw[depth]
  for (k = 1; k <= nw; k++) { words[k] = sword[depth, k]; delete sword[depth, k] }
  w = sw[depth]; atword = 1
  st = csave[depth]
  depth--
}

function endword() {
  # atword covers empty quoted arguments: "" opened a word without adding a
  # character, and dropping it would shift value-taking flags onto the wrong
  # token (`git -C "" commit` must keep "" as -C's value).
  if (length(w) > 0 || atword) { nw++; words[nw] = w }
  w = ""; atword = 0
}

function iskeyword(t) {
  return (t == "if" || t == "then" || t == "elif" || t == "else" || t == "fi" || \
          t == "while" || t == "until" || t == "do" || t == "done" || t == "for" || \
          t == "case" || t == "esac" || t == "{" || t == "}" || t == "!")
}

function endcmd(   j, t, moved) {
  endword()
  if (nw > 0) {
    j = 1
    moved = 1 # peel keywords, VAR=value prefixes, and wrappers until the real command
    while (moved && j <= nw) {
      moved = 0
      while (j <= nw && iskeyword(words[j])) { j++; moved = 1 }
      while (j <= nw && words[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { j++; moved = 1 }
      if (j <= nw && (words[j] == "sudo" || words[j] == "command" || words[j] == "env" || words[j] == "time" || words[j] == "nohup" || words[j] == "nice")) { j++; moved = 1 }
    }
    if (j <= nw) {
      t = words[j]
      sub(/^.*\//, "", t) # /usr/bin/git
      if (t == "git") {
        j++
        while (j <= nw && words[j] ~ /^-/) {
          if (words[j] == "-C" || words[j] == "-c" || words[j] == "--git-dir" || words[j] == "--work-tree" || words[j] == "--namespace" || words[j] == "--config-env") j += 2
          else j++
        }
        if (j <= nw && words[j] == "commit") found = 1
      }
    }
  }
  for (j in words) delete words[j]
  nw = 0
}
