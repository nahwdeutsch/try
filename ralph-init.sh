#!/usr/bin/env bash
#
# ralph-init.sh — scaffold the Ralph state layer into a project.
#
#   ./ralph-init.sh /path/to/project
#
# Idempotent: never overwrites an existing file.
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$PWD}"
TARGET="$(cd "$TARGET" && pwd)"

echo "scaffolding Ralph into: $TARGET"

copy_if_absent() {
  local from="$1" to="$2"
  if [[ -e "$to" ]]; then
    echo "  skip    ${to#$TARGET/} (exists)"
  else
    mkdir -p "$(dirname "$to")"
    cp "$from" "$to"
    echo "  create  ${to#$TARGET/}"
  fi
}

mkdir -p "$TARGET/.ralph/logs"
for f in plan.md progress.md decisions.md blockers.md prompt.md config.sh; do
  copy_if_absent "$SRC/templates/$f" "$TARGET/.ralph/$f"
done
copy_if_absent "$SRC/templates/CLAUDE.md" "$TARGET/CLAUDE.md"
copy_if_absent "$SRC/ralph.sh" "$TARGET/ralph.sh"
chmod +x "$TARGET/ralph.sh"

# logs are noise in history; state files are the point and must be committed
if ! grep -q '^\.ralph/logs/' "$TARGET/.gitignore" 2>/dev/null; then
  printf '\n# ralph iteration logs (state files stay tracked)\n.ralph/logs/\n' >> "$TARGET/.gitignore"
  echo "  update  .gitignore"
fi

if ! git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  echo
  echo "NOTE: $TARGET is not a git repository. Ralph needs git for checkpoints:"
  echo "      git -C '$TARGET' init && git -C '$TARGET' commit --allow-empty -m 'init'"
fi

cat <<'NEXT'

Next steps:
  1. Write the master plan ONCE:
       claude "Read .ralph/plan.md. Turn the goal below into 50-300 small tasks,
               each implementable and verifiable in a single sitting. Edit
               plan.md in place, keep the format, then stop. Goal: <your goal>"
  2. Set VERIFY_CMD in .ralph/config.sh to your real check command.
  3. Fill in CLAUDE.md (verification command + a short architecture note).
  4. Commit the scaffold, then run:  ./ralph.sh
NEXT
