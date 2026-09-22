# Ralph configuration — sourced by ralph.sh

# Command that proves a task is really done. The single most important setting:
# without it the agent grades its own homework.
VERIFY_CMD="npm run typecheck && npm run lint && npm test"

# Agent turns allowed inside ONE iteration. Too low = tasks never finish;
# too high = one runaway iteration eats the whole quota.
MAX_TURNS=120

# Tasks per iteration. Keep at 1 unless tasks are tiny. Higher values grow the
# context and reduce the value of the fresh-context design.
TASKS_PER_ITERATION=1

# Consecutive iterations with no commit and no completed task before giving up.
MAX_STALLS=3

# What to do when an iteration deletes, rewords or renumbers a task:
#   strict = stop the loop (default — silent scope loss is worse than a halt)
#   warn   = log it loudly and keep going
PLAN_GUARD=strict

# "" = account default. "opus" for hard work, "sonnet" to stretch the quota.
MODEL=""

# acceptEdits = edit files freely, ask before shell commands.
# In headless mode there is nobody to ask, so an un-allowlisted command is
# simply refused — which is why ALLOWED_TOOLS below is not optional.
PERMISSION_MODE="acceptEdits"

# Tools the agent may use without a prompt. MUST cover git (for checkpoints)
# and whatever VERIFY_CMD runs, or the loop can never make progress.
# Set PERMISSION_MODE="bypassPermissions" to allow everything instead —
# only do that inside a container or VM you are willing to lose.
ALLOWED_TOOLS=(
  Read Write Edit Glob Grep TodoWrite
  "Bash(git add:*)" "Bash(git commit:*)" "Bash(git status:*)"
  "Bash(git log:*)" "Bash(git diff:*)" "Bash(git rev-parse:*)" "Bash(git show:*)"
  # Read-only navigation. The agent reaches for these constantly; without them
  # it burns a turn per refusal. They grant nothing it lacks — it already has
  # Write and Edit — and the plan is protected by PLAN_GUARD, not by this list.
  "Bash(grep:*)" "Bash(awk:*)" "Bash(head:*)" "Bash(tail:*)"
  "Bash(wc:*)" "Bash(find:*)" "Bash(ls:*)" "Bash(cat:*)"
  # --- add what your verification command needs, e.g.: ---
  "Bash(npm:*)" "Bash(npx:*)"
)

# Deliberately NOT listed: "Bash(sed -i:*)" and other in-place rewriters.
# Not because they are dangerous — Edit can change the same files — but because
# an iteration that edits the plan through Edit leaves a reviewable diff, and
# the refusal nudges it there.

# Seconds to wait when a usage limit is hit and no reset time was reported.
LIMIT_WAIT_SECONDS=1800

# 0 = exit cleanly on usage limit (recommended: restart by hand after reset).
# Use ./ralph.sh --wait-on-limit to sleep through the reset instead.
MAX_LIMIT_WAITS=0
