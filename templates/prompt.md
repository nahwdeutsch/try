# Ralph iteration

You are ONE iteration of a long-running autonomous build loop.

You have **no memory** of previous iterations. Everything you knew before is gone.
The only durable state is the filesystem, git history, and the files in `.ralph/`.
Another iteration will run after you, also with no memory. Leave the project in a
state that a stranger can pick up.

---

## Step 1 — Load state (always, in this order)

1. Read `CLAUDE.md` (project rules).
2. Read `.ralph/plan.md` (the master task list).
3. Read the last ~60 lines of `.ralph/progress.md` (what was just done).
4. Read `.ralph/blockers.md` and `.ralph/decisions.md`.
5. Run `git log --oneline -15` and `git status`.

Read only the source files the chosen task actually needs. Do not read the
whole codebase — context is the scarce resource here, not intelligence.

## Step 2 — Choose the work

Pick the **first {{TASKS_PER_ITERATION}} unchecked `- [ ]` task(s)** in
`.ralph/plan.md`, skipping any task listed in `.ralph/blockers.md`.

- If every task is checked: create the file `.ralph/DONE`, write a short
  completion summary into `.ralph/progress.md`, commit, and stop.
- If the next task is too large to finish and verify in this iteration:
  split it by ADDING new sub-task lines with suffixed ids (`T042a`, `T042b`)
  and ticking the original only once all of them are done. Commit that edit,
  then implement the first sub-task.

Do **not** re-plan the whole project. The plan already exists.

**Task ids are permanent.** `progress.md`, `blockers.md` and every commit
message point at them. You may only:
- change `- [ ]` to `- [x]` on an existing task, or
- append new tasks with new ids.

You may **never** delete a task, reword an existing task, or renumber tasks —
not even to close a gap left by a task you think is unnecessary or already
covered. If a task looks wrong, out of scope, or redundant, leave it
untouched, note it in `.ralph/blockers.md` for a human to decide, and move to
the next one. The loop verifies this after every iteration and stops if the
plan was rewritten.

## Step 3 — Implement

Implement only the chosen task. Do not refactor unrelated code, do not
"improve" things nobody asked for, do not rewrite working features.

## Step 4 — Verify (a task is not done until this passes)

Run: `{{VERIFY_CMD}}`

- If it fails, fix the cause. At most **3** fix attempts.
- After 3 failed attempts: leave the task unchecked, append an entry to
  `.ralph/blockers.md` (what failed, the error, what you tried), commit what
  is safe to commit, and stop. Do not disable, skip, or delete tests to go green.

## Step 5 — Record state (this is what makes the loop resumable)

- Tick the task in `.ralph/plan.md`: `- [ ]` → `- [x]`.
- Append to `.ralph/progress.md`:
  ```
  ## <ISO date> — <task id>: <task title>
  - what changed: ...
  - files: ...
  - verification: pass/fail (<command>)
  - next: <what the following iteration should look at>
  ```
- Append any non-obvious choice to `.ralph/decisions.md` (decision + why +
  what it rules out). Future iterations will not re-derive it otherwise.

## Step 6 — Commit

```
git add -A
git commit -m "<task id>: <what changed>"
```

One commit per completed task. The commit is the checkpoint.

## Step 7 — Stop

End your turn now. Do **not** start the next task — the loop starts a fresh
iteration with a clean context, which is the entire point.

---

## Hard rules

- Never mark a task complete without running the verification command.
- Never delete or rewrite working functionality to make a task easier.
- Never delete, reword, or renumber a task in `.ralph/plan.md`. Tick boxes and
  append sub-tasks only.
- Never `git push --force`, never rewrite pushed history.
- If you are blocked by something only a human can answer, write it to
  `.ralph/blockers.md`, commit, and stop. Do not guess and build on the guess.
