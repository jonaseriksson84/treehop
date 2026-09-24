---
name: worktree
description: One git worktree per task via treehop. Use before any branch work in a shared checkout, when a task is finished and its worktree should go, or when a commit landed on the wrong branch.
---

# Worktree

Every task gets its own worktree, created with `treehop new` (it warms the tree up and runs the repo's hooks; a plain `git worktree add` skips both). The main checkout stays on its default branch: other sessions and tools share it, so branch work there races them. `treehop help` is the source of truth for arguments, configuration keys and what each step does.

The binary is `treehop` on PATH, or `${CLAUDE_PLUGIN_ROOT}/bin/treehop` when only the plugin is installed.

## Start

1. `treehop new <name>` from anywhere inside the repo. Name it after the branch you want, minus the configured prefix: an existing branch is reused. Done when it prints `>> ready in <N>s` with the path and branch.
2. Work in the printed path. Bash cwd resets to the session's start dir between calls, so every command starts with `cd` into the worktree or uses `git -C`.

## Work

- Guard every commit against the wrong branch: `test "$(git branch --show-current)" = <branch> && git commit ...`.
- Each worktree has its own build outputs; a shared build cache (Bazel disk cache, pnpm store) is what keeps warm-up cheap.

## Finish

`treehop rm <name>` once the work is merged or dropped. Refuses a dirty tree; `--force` discards it. The branch stays. `treehop ls` shows which worktrees are dirty and which branches are already merged.

## Recovery: a commit landed on the main checkout's branch

In the main checkout, local only. Stays on the branch, keeps uncommitted files:

```sh
git branch -f <feature> HEAD && git reset --keep origin/<default-branch>
```

`branch -f` refuses a branch checked out in a worktree; use a fresh name then and merge it there. Never push the default branch.
