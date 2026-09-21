# Ralph — a long-running autonomous Claude Code loop

Turn Claude Code from "an assistant I chat with" into "a worker I point at a
big project and come back to find milestones done".

The one idea everything else follows from:

> **The conversation is not the state. The filesystem and git are.**

Each iteration is a *fresh* `claude -p` call with a small, clean context. It
rebuilds its understanding from `.ralph/plan.md`, `.ralph/progress.md` and
`git log`, does exactly one task, verifies it, commits, and exits. The loop
can therefore be killed at any moment — usage limit, crash, closed laptop —
and lose nothing but the current task.

```
MASTER PLAN (written once)
        │
        ▼
   ┌─ iteration ────────────────────────────┐
   │  read plan + progress + git  (small)   │
   │  pick ONE unchecked task               │
   │  implement                             │
   │  run VERIFY_CMD  ── fails ──► blockers │
   │  tick box, append progress             │
   │  git commit         ← the checkpoint   │
   └────────────┬───────────────────────────┘
                │  fresh context, no memory carried over
                ▼
          next iteration
                │
          [usage limit]
                │
          stop cleanly ──► wait for reset ──► ./ralph.sh again
```

## Quick start

```bash
git clone <this repo> ralph && cd ralph
./ralph-init.sh /path/to/your/project
cd /path/to/your/project
```

Then, in order:

1. **Write the plan once.** This is the step people skip, and it is the one
   that decides whether the loop works. Spend real quota here:

   ```bash
   claude "Read .ralph/plan.md. Turn this goal into 50-300 tasks, each small
           enough to implement AND verify in one sitting, ordered so every
           task builds on finished ones. Edit plan.md in place, keep the
           format, then stop. Goal: <describe your project>"
   ```

2. **Set `VERIFY_CMD`** in `.ralph/config.sh` to a command that genuinely
   fails when the code is wrong. Without it the agent grades its own homework
   and the plan fills with ticked boxes over broken code.

3. **Fill in `CLAUDE.md`** — the verification command and a short
   architecture note. It is read on *every* iteration, so keep it short.

4. **Run it.**

   ```bash
   ./ralph.sh                 # until the plan is done or the quota runs out
   ./ralph.sh --iterations 5  # a few turns, to see how it behaves
   ./ralph.sh --dry-run       # print what would run, call nothing
   ```

## What lives where

| Path | Role |
|---|---|
| `.ralph/plan.md` | The master task list. Iterations tick boxes; they never re-plan. |
| `.ralph/progress.md` | Append-only log. What was done, verified, and what is next. |
| `.ralph/decisions.md` | Non-obvious choices + why, so nothing gets re-litigated. |
| `.ralph/blockers.md` | Tasks that need a human. Iterations skip these. |
| `.ralph/prompt.md` | The iteration prompt. The heart of the system — read it. |
| `.ralph/config.sh` | `VERIFY_CMD`, `MAX_TURNS`, model, limit behaviour. |
| `.ralph/logs/` | Raw + readable transcript per iteration (git-ignored). |
| `CLAUDE.md` | Rules the agent reloads every single session. |

Everything except `logs/` is committed. That is the whole resume mechanism.

## Permissions (the thing that silently breaks headless loops)

In headless mode there is nobody to answer a permission prompt, so a tool that
is not pre-approved is simply **refused** — and `acceptEdits` alone allows file
edits but *not* Bash. An agent that cannot run Bash cannot commit and cannot
run your verification command, so the loop stalls while looking like it is
working. This was the first thing that broke when building this.

`ALLOWED_TOOLS` in `.ralph/config.sh` is therefore not optional. It must cover
git plus whatever `VERIFY_CMD` runs:

```bash
ALLOWED_TOOLS=(
  Read Write Edit Glob Grep TodoWrite
  "Bash(git add:*)" "Bash(git commit:*)" "Bash(git status:*)"
  "Bash(git log:*)" "Bash(git diff:*)" "Bash(git rev-parse:*)"
  "Bash(npm:*)" "Bash(npx:*)"        # whatever VERIFY_CMD needs
)
```

Ralph reads `permission_denials` out of each transcript and logs
`PERMISSION DENIED: ...` with the exact tool to add, so you find this in
seconds instead of staring at a stalled run.

The alternative is `PERMISSION_MODE="bypassPermissions"`, which approves
everything and skips the allowlist entirely. It is the smoother experience and
the riskier one: an unattended agent with unrestricted shell access will
eventually run something you did not want. Use it only inside a container or
VM you are willing to throw away.

## When the usage limit hits

Nothing special happens, which is the point. The loop detects the limit,
logs it, and exits with code `10`. The finished tasks are committed, the
plan shows exactly where it stopped, and `progress.md` says what is next.

After the quota resets:

```bash
./ralph.sh          # picks up from the first unchecked task
```

There is no `--continue`, no session to resume, nothing to remember. A
brand-new context reads the plan and carries on. Use `./ralph.sh
--wait-on-limit` if you would rather it sleep through the reset unattended.

Practical note: the quota is a rolling window, not a fixed daily budget, and
there is a separate longer-period cap on top of it. So do not design around
"I get N hours". Design around "any iteration may be the last one" — which
is what this loop already does.

## Stop conditions

The loop exits on:

- **plan complete** — no unchecked tasks, or `.ralph/DONE` exists (code `0`)
- **usage limit** — quota exhausted (code `10`)
- **stall** — `MAX_STALLS` iterations with no commit and no completed task
  (code `11`). Almost always means the next task is underspecified or the
  verification command is broken. Read `.ralph/blockers.md`.

Stall detection matters more than it looks. Without it, a loop that cannot
make progress will happily burn an entire quota rediscovering the same wall.

## Why one task per iteration

Raising `TASKS_PER_ITERATION` is tempting and usually wrong. Each extra task
grows the context the next decision is made in, which is exactly what the
fresh-context design exists to prevent. A larger context also makes the agent
more likely to drift into unrequested refactors. Start at `1`; raise it only
if your tasks are genuinely tiny.

## Things that go wrong

- **No verification command.** The single biggest failure mode. The plan
  fills with green checkmarks over code that does not run.
- **A vague plan.** "Build the backend" is not a task. If an iteration cannot
  finish and verify it, it will either flail or split it badly. Tasks should
  be one sitting each.
- **Letting it build process instead of product.** Long autonomous runs drift
  toward meta-work: tooling, scripts, elaborate self-management. `CLAUDE.md`
  forbids this explicitly, and the narrow per-iteration prompt is the defence.
- **Dirty working tree at the start.** Ralph runs `git add -A`. Commit or
  stash your own work first.

## Requirements

`claude` CLI, `git`, `jq`, `bash` 4+.
