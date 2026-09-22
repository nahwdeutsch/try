#!/usr/bin/env bash
#
# ralph.sh — long-running autonomous Claude Code loop.
#
# Core idea: the conversation is NOT the state. The filesystem and git are.
# Every iteration is a brand-new `claude -p` call with a fresh, small context
# that rebuilds its understanding from .ralph/plan.md + progress.md + git.
# The loop can therefore die at any moment (usage limit, crash, reboot)
# without losing the project.
#
# Usage:
#   ./ralph.sh                 # run until plan is finished or limits hit
#   ./ralph.sh --iterations 5  # run at most 5 iterations
#   ./ralph.sh --dry-run       # print what would run, don't call claude
#
set -uo pipefail

# ---------------------------------------------------------------- defaults ---
RALPH_DIR="${RALPH_DIR:-.ralph}"
MAX_ITERATIONS=1000        # hard ceiling on loop turns
MAX_TURNS=120              # agent turns inside ONE iteration
TASKS_PER_ITERATION=1      # keep at 1-3; higher = bigger context = worse
MAX_STALLS=3               # consecutive no-progress iterations before stopping
PLAN_GUARD=strict          # strict = stop if an iteration deletes/renames tasks
VERIFY_CMD=""              # e.g. "npm run typecheck && npm test"
MODEL=""                   # e.g. "opus" / "sonnet"; empty = account default
PERMISSION_MODE="acceptEdits"
# Headless mode has nobody to answer a permission prompt: a tool that is not
# pre-approved is simply refused, so the agent can never commit or verify.
# This allowlist is what makes the loop able to run unattended. Extend it with
# whatever VERIFY_CMD needs (e.g. "Bash(npm:*)", "Bash(cargo:*)").
ALLOWED_TOOLS=(Read Write Edit Glob Grep TodoWrite
               "Bash(git add:*)" "Bash(git commit:*)" "Bash(git status:*)"
               "Bash(git log:*)" "Bash(git diff:*)" "Bash(git rev-parse:*)"
               "Bash(git show:*)" "Bash(grep:*)" "Bash(awk:*)" "Bash(head:*)"
               "Bash(tail:*)" "Bash(wc:*)" "Bash(find:*)" "Bash(ls:*)" "Bash(cat:*)")
LIMIT_WAIT_SECONDS=1800    # fallback wait when reset time can't be parsed
MAX_LIMIT_WAITS=0          # 0 = never sleep, exit instead (default: stop clean)
COOLDOWN_SECONDS=5         # pause between iterations

DRY_RUN=0
CLI_ITERATIONS=""

# --------------------------------------------------------------- arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) CLI_ITERATIONS="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --wait-on-limit) MAX_LIMIT_WAITS=99; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ config ---
[[ -f "$RALPH_DIR/config.sh" ]] && source "$RALPH_DIR/config.sh"
[[ -n "$CLI_ITERATIONS" ]] && MAX_ITERATIONS="$CLI_ITERATIONS"

PLAN="$RALPH_DIR/plan.md"
PROGRESS="$RALPH_DIR/progress.md"
PROMPT="$RALPH_DIR/prompt.md"
LOG_DIR="$RALPH_DIR/logs"
RUN_LOG="$LOG_DIR/ralph.log"

# ------------------------------------------------------------------- utils ---
ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '%s  %s\n' "$(ts)" "$*" | tee -a "$RUN_LOG"; }
die() { log "FATAL: $*"; exit 1; }

# Literal placeholder substitution. Deliberately not sed and not bash's
# ${v//p/r}: VERIFY_CMD normally contains && and |, which sed treats as
# metacharacters and which bash >= 5.2 expands via patsub_replacement.
# awk with ENVIRON is literal on every version.
subst() {
  SUBST_TEXT="$1" SUBST_KEY="$2" SUBST_VAL="$3" awk 'BEGIN {
    text = ENVIRON["SUBST_TEXT"]; key = ENVIRON["SUBST_KEY"]; val = ENVIRON["SUBST_VAL"]
    out = ""
    while ((i = index(text, key)) > 0) {
      out = out substr(text, 1, i - 1) val
      text = substr(text, i + length(key))
    }
    printf "%s", out text
  }'
}

open_tasks() { grep -cE '^[[:space:]]*-[[:space:]]\[[[:space:]]\]' "$PLAN" 2>/dev/null || true; }
head_sha()   { git rev-parse --short HEAD 2>/dev/null || echo "none"; }

# ------------------------------------------------------------- preconditions --
command -v claude >/dev/null || die "claude CLI not found in PATH"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository — run: git init"
[[ -f "$PLAN" ]]   || die "$PLAN not found — run ./ralph-init.sh first"
[[ -f "$PROMPT" ]] || die "$PROMPT not found — run ./ralph-init.sh first"
mkdir -p "$LOG_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
  log "WARNING: working tree is dirty. Ralph commits everything it touches;"
  log "         commit or stash your own changes first to keep history clean."
fi

# -------------------------------------------------- usage-limit handling ------
# The stream-json result carries a structured rate_limit_info:
#   {"status":"allowed","resetsAt":1790038800,"rateLimitType":"five_hour",...}
# Read that field rather than grepping the transcript for "rate limit" — the
# happy-path output contains that phrase too, and a text match aborts healthy
# runs. Text matching is kept only as a fallback for non-JSON CLI errors.
#
# Echoes "LIMITED <epoch>" or "OK"; epoch is 0 when the reset time is unknown.
limit_status() {
  local jsonl="$1" err="$2" verdict=""

  if [[ -s "$jsonl" ]]; then
    # status is "allowed" while requests are being served and "allowed_warning"
    # when the quota is merely close to its cap — neither blocks anything, so
    # only a status that does NOT start with "allowed" counts as limited.
    # Treating the warning as a stop wastes the rest of the window.
    verdict="$(jq -rs '
        [ .. | objects | select(has("status") and has("resetsAt")) ] as $rl
        | ([ $rl[] | select(.status | startswith("allowed") | not) ] | first) as $hit
        | ([ .. | objects | .api_error_status? // empty ] | map(select(. == 429)) | length) as $e429
        | if $hit    then "LIMITED \($hit.resetsAt // 0)"
          elif $e429 > 0 then "LIMITED 0"
          else "OK" end
      ' "$jsonl" 2>/dev/null)"
  fi

  # Fallback: the CLI can fail before emitting any JSON at all.
  if [[ -z "$verdict" || "$verdict" == "OK" ]]; then
    local f
    for f in "$jsonl" "$err"; do
      [[ -s "$f" ]] || continue
      if grep -qiE 'usage limit reached|quota exceeded|too many requests' "$f"; then
        local epoch
        epoch="$(grep -ohE 'limit reached\|[0-9]{10}' "$f" | head -1 | cut -d"|" -f2)"
        echo "LIMITED ${epoch:-0}"; return 0
      fi
    done
  fi

  echo "${verdict:-OK}"
}

wait_for_reset() {
  local epoch="$1" now secs
  now="$(date +%s)"
  if [[ "${epoch:-0}" -gt "$now" ]]; then
    secs=$(( epoch - now + 60 ))
    log "quota resets at $(date -d "@$epoch" 2>/dev/null || echo "epoch $epoch")"
  else
    secs="$LIMIT_WAIT_SECONDS"
    log "reset time not reported, waiting ${secs}s"
  fi
  log "sleeping ${secs}s — state is on disk and in git, nothing is lost"
  sleep "$secs"
}

# Surface how close the quota is to its cap, so an approaching stop is not a
# surprise. This is informational only — it never stops the loop.
report_quota() {
  local jsonl="$1" u
  [[ -s "$jsonl" ]] || return 0
  u="$(jq -rs '[ .. | objects | select(has("status") and has("utilization")) | .utilization ]
               | max // empty' "$jsonl" 2>/dev/null)"
  [[ -z "$u" || "$u" == "null" ]] && return 0
  awk -v u="$u" 'BEGIN { exit !(u >= 0.8) }' && log "quota utilization: $(awk -v u="$u" 'BEGIN{printf "%.0f%%", u*100}')"
  return 0
}

# A tool the agent asked for but was not allowed is the quietest way for a run
# to fail: it cannot commit or verify, and just stalls. Surface it loudly.
report_denials() {
  local jsonl="$1" denied
  [[ -s "$jsonl" ]] || return 0
  denied="$(jq -rs '[ .. | objects | .permission_denials? // empty | .[]? |
                      (.tool_name // "?") + "(" + ((.tool_input.command // "") | tostring) + ")" ]
                    | unique | join(", ")' "$jsonl" 2>/dev/null)"
  if [[ -n "$denied" && "$denied" != "null" && "$denied" != "" ]]; then
    log "PERMISSION DENIED: $denied"
    log "  -> add these to ALLOWED_TOOLS in $RALPH_DIR/config.sh, or the loop cannot progress"
  fi
}

# ------------------------------------------------------- plan integrity ------
# An iteration is allowed to tick a box and to split a task into new ones.
# It is NOT allowed to delete a task or reword an existing one: task IDs are
# permanent identifiers that progress.md, blockers.md and commit messages all
# point at. Renumbering silently rewrites that history, and an agent that can
# delete tasks can reach "plan complete" by emptying the plan — which would
# make the loop's own stop condition meaningless.
#
# Snapshot format: "<id>\t<description>", one per line.
plan_snapshot() {
  sed -nE 's/^[[:space:]]*-[[:space:]]\[[ xX]\][[:space:]]*(T[0-9]+[A-Za-z]*)[[:space:]]*(—|-|:)?[[:space:]]*(.*)$/\1\t\3/p' "$PLAN"
}

# Prints violations, one per line. Empty output means the plan is intact.
plan_violations() {
  local before="$1" after="$2"
  awk -F'\t' '
    NR==FNR { desc[$1] = $2; next }
    { now[$1] = $2 }
    END {
      for (id in desc) {
        if (!(id in now))            print "deleted: " id " — " desc[id]
        else if (now[id] != desc[id]) print "reworded: " id
      }
    }
  ' "$before" "$after" | sort
}

check_plan_integrity() {
  local before="$1" after="$2" v
  v="$(plan_violations "$before" "$after")"
  [[ -z "$v" ]] && return 0

  log "PLAN TAMPERING DETECTED — the iteration changed tasks it may only tick:"
  while IFS= read -r line; do [[ -n "$line" ]] && log "  $line"; done <<<"$v"

  if [[ "$PLAN_GUARD" == "strict" ]]; then
    log "Stopping (PLAN_GUARD=strict). Restore the plan, then rerun:"
    log "  git diff HEAD~1 -- $PLAN      # see what the iteration did"
    log "  git checkout HEAD~1 -- $PLAN  # or restore it wholesale, re-ticking done tasks"
    log "Set PLAN_GUARD=warn in $RALPH_DIR/config.sh to log this and keep going."
    return 1
  fi
  log "Continuing anyway (PLAN_GUARD=warn) — scope may have been lost silently."
  return 0
}

# Run once at startup. A duplicated task wastes an iteration and tempts the
# agent into "tidying" the plan, which is what PLAN_GUARD then halts on.
lint_plan() {
  local dup_ids dup_desc n
  n="$(plan_snapshot | wc -l)"
  dup_ids="$(plan_snapshot | cut -f1 | sort | uniq -d)"
  dup_desc="$(plan_snapshot | cut -f2 | sort | uniq -d)"
  log "plan: $n task(s)"
  if [[ -n "$dup_ids" ]]; then
    log "PLAN LINT: duplicate task ids — progress.md could not refer to them unambiguously:"
    while IFS= read -r x; do log "  $x"; done <<<"$dup_ids"
  fi
  if [[ -n "$dup_desc" ]]; then
    log "PLAN LINT: $(wc -l <<<"$dup_desc") duplicated task description(s), e.g.:"
    log "  $(head -1 <<<"$dup_desc" | cut -c1-80)..."
    log "  -> resolve by hand: delete the duplicate LINE and leave the id gap."
    log "     Do not renumber; ids are referenced by progress.md and commit messages."
  fi
}

# ------------------------------------------------------------- one iteration --
run_iteration() {
  local n="$1"
  local raw="$LOG_DIR/iter-$(printf '%03d' "$n").jsonl"
  local txt="$LOG_DIR/iter-$(printf '%03d' "$n").log"
  local err="$LOG_DIR/iter-$(printf '%03d' "$n").err"
  local prompt_text verify_text
  verify_text="${VERIFY_CMD:-(no verification command configured — set VERIFY_CMD in $RALPH_DIR/config.sh)}"
  prompt_text="$(subst "$(<"$PROMPT")" '{{TASKS_PER_ITERATION}}' "$TASKS_PER_ITERATION")"
  prompt_text="$(subst "$prompt_text" '{{VERIFY_CMD}}' "$verify_text")"

  local -a cmd=(claude -p "$prompt_text"
                --permission-mode "$PERMISSION_MODE"
                --max-turns "$MAX_TURNS"
                --output-format stream-json --verbose)
  [[ -n "$MODEL" ]] && cmd+=(--model "$MODEL")
  if [[ "$PERMISSION_MODE" != "bypassPermissions" && ${#ALLOWED_TOOLS[@]} -gt 0 ]]; then
    cmd+=(--allowedTools "${ALLOWED_TOOLS[@]}")
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    log "[dry-run] would run: ${cmd[0]} -p <prompt> ${cmd[*]:3}"
    return 0
  fi

  # stdin MUST be closed: claude -p otherwise waits on it and can hang the loop.
  # stderr goes to its own file so the JSONL stream stays parseable.
  "${cmd[@]}" < /dev/null 2>"$err" | tee "$raw" \
    | jq -r --unbuffered '
        if .type=="assistant" then (.message.content[]? | select(.type=="text") | .text)
        elif .type=="result" then "\n--- result: \(.subtype) (\(.num_turns) turns) ---"
        else empty end' 2>/dev/null | tee "$txt"

  local rc="${PIPESTATUS[0]}"
  [[ -s "$err" ]] && { echo "--- stderr ---" >> "$txt"; cat "$err" >> "$txt"; }
  return "$rc"
}

# ------------------------------------------------------------------ main -----
log "=============================================================="
log "ralph start — $(open_tasks) open tasks, HEAD $(head_sha)"
log "config: max_turns=$MAX_TURNS tasks/iter=$TASKS_PER_ITERATION verify='${VERIFY_CMD:-none}'"
lint_plan

stalls=0
limit_waits=0

for (( i=1; i<=MAX_ITERATIONS; i++ )); do
  remaining="$(open_tasks)"
  if [[ -f "$RALPH_DIR/DONE" ]]; then
    log "DONE marker present — plan complete"; break
  fi
  if [[ "${remaining:-0}" -eq 0 ]]; then
    log "no unchecked tasks left in $PLAN — plan complete"; break
  fi

  before_sha="$(head_sha)"
  before_open="$remaining"
  plan_before="$LOG_DIR/.plan-before"
  plan_after="$LOG_DIR/.plan-after"
  plan_snapshot > "$plan_before"
  log "--- iteration $i/$MAX_ITERATIONS — $remaining task(s) open, HEAD $before_sha"

  run_iteration "$i"
  rc=$?
  iter_log="$LOG_DIR/iter-$(printf '%03d' "$i").jsonl"

  iter_err="$LOG_DIR/iter-$(printf '%03d' "$i").err"
  report_denials "$iter_log"
  report_quota "$iter_log"
  read -r lim_verdict lim_epoch <<<"$(limit_status "$iter_log" "$iter_err")"
  if [[ "$lim_verdict" == "LIMITED" ]]; then
    if [[ "$limit_waits" -ge "$MAX_LIMIT_WAITS" ]]; then
      log "usage limit reached and waiting is disabled."
      log "Resume later with: ./ralph.sh   (state is in $RALPH_DIR + git)"
      exit 10
    fi
    limit_waits=$(( limit_waits + 1 ))
    wait_for_reset "${lim_epoch:-0}"
    continue   # a limited iteration is not a stall
  fi

  [[ "$rc" -ne 0 ]] && log "claude exited with code $rc (see $iter_log)"

  plan_snapshot > "$plan_after"
  check_plan_integrity "$plan_before" "$plan_after" || exit 12

  after_sha="$(head_sha)"
  after_open="$(open_tasks)"
  if [[ "$after_sha" == "$before_sha" && "${after_open:-0}" -ge "${before_open:-0}" ]]; then
    stalls=$(( stalls + 1 ))
    log "no progress this iteration (stall $stalls/$MAX_STALLS)"
    if [[ "$stalls" -ge "$MAX_STALLS" ]]; then
      log "stopping: $MAX_STALLS iterations without a commit or a completed task."
      log "Check $RALPH_DIR/blockers.md and the logs — the plan likely needs a human."
      exit 11
    fi
  else
    stalls=0
    log "progress: HEAD $before_sha -> $after_sha, open tasks $before_open -> $after_open"
  fi

  sleep "$COOLDOWN_SECONDS"
done

log "ralph stop — $(open_tasks) task(s) still open, HEAD $(head_sha)"
