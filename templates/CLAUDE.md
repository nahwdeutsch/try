# Project operating rules

This project is built by a long-running autonomous loop. Any session may be a
fresh context with no memory. Treat `.ralph/` and git as the source of truth.

## On every session start

1. Read `.ralph/plan.md` — the master plan.
2. Read `.ralph/progress.md` — what is already done.
3. Read `.ralph/blockers.md` — what is stuck and why.
4. Run `git log --oneline -15` and `git status`.

Then continue from the first unchecked task.

## Always

- One task at a time; verify before ticking it off.
- Commit after every completed task.
- Record non-obvious decisions in `.ralph/decisions.md`.
- Keep the working tree clean — no half-finished edits left behind.

## Never

- Mark a task complete without running the verification command.
- Delete, skip, or disable tests to make a build pass.
- Rewrite working features that nothing asked you to touch.
- Re-plan the project from scratch; the plan is already written.
- Build tooling, dashboards, or meta-process instead of the actual product.

## Verification command

```
<!-- e.g. npm run typecheck && npm run lint && npm test && npm run build -->
```

## Architecture notes

<!-- Keep this short and current. It is read on every single iteration. -->
