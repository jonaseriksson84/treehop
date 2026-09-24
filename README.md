# treehop

One git worktree per task. `treehop new` puts a branch in its own directory and warms it up; `treehop rm` takes the directory away together with everything it left behind, including a Bazel output base that would otherwise sit on disk forever.

Built for running several coding agents in parallel on one repository, where a shared checkout means one session's `git pull` lands in another session's commit.

```
$ treehop new fix-login
Preparing worktree (new branch 'me/fix-login')
>> warmup
>> sharing Claude Code memory with /home/me/code/app
>> ready in 31s: /home/me/code/app.worktrees/me-fix-login (me/fix-login)

$ treehop ls
me/fix-login   dirty    -        /home/me/code/app.worktrees/me-fix-login
me/old-thing   -        merged   /home/me/code/app.worktrees/me-old-thing

$ treehop rm old-thing
>> removed /home/me/code/app.worktrees/me-old-thing (branch me/old-thing kept)
```

## Install

Bash and git only.

```sh
git clone https://github.com/jonaseriksson84/treehop ~/.local/share/treehop
ln -s ~/.local/share/treehop/bin/treehop ~/.local/bin/treehop
```

As a Claude Code plugin, which also installs the `worktree` skill so the agent reaches for `treehop new` instead of branching in your checkout:

```
claude plugin marketplace add jonaseriksson84/treehop
claude plugin install treehop@treehop
```

## What `new` does

1. `git fetch` the base, then `git worktree add --no-track -b <prefix><name>` from it. An existing branch is reused. No upstream is set, so the first `git push -u` decides it and the base branch never becomes one by accident.
2. Run the `warmup` command inside the new tree (dependency install, code generation, whatever makes the tree usable).
3. If `~/.claude/projects` has a memory directory for the main checkout, symlink the worktree's memory directory to it. Claude Code keys memory by working directory; without this every worktree starts from nothing.
4. Run the `after-create` hook.

## What `rm` does

1. Refuse if the tree has uncommitted changes, unless `--force`.
2. Run the `before-remove` hook.
3. `git worktree remove` and `git worktree prune`. The branch is kept.
4. If the tree was a Bazel workspace, delete its output base. Bazel gives each worktree its own, tens of gigabytes each, and nothing else ever cleans them up.

## Why this is fast

A worktree has to be built before it is useful, and a cold build of a large repo takes minutes. treehop assumes a build cache shared across worktrees, so the second worktree pays only for what changed since the first.

For Bazel that means one disk cache and a separate output base per worktree, not a shared `--output_base`, which is a global lock that would serialize your agents. In `~/.bazelrc`:

```
common --disk_cache=~/.cache/bazel-disk-cache
```

Measured on a monorepo with a `gen_all` code-generation step: 205s for a cold worktree, 27s with the cache seeded. The per-worktree output base is also why `rm` deletes it: nothing else ever does.

pnpm already shares its store across checkouts, so `pnpm install --frozen-lockfile` in a new worktree is a few seconds.

## Configuration

First match wins: `git config treehop.<key>` (local, then global), then a checked-in `.treehop` file at the repo root, then the default.

| key | default | meaning |
|---|---|---|
| `branch-prefix` | none | prepended to `<name>`; `/` becomes `-` in the directory name |
| `worktree-dir` | `<repo parent>/<repo name>.worktrees` | where worktrees live |
| `base` | `origin/HEAD`, else `origin/main` | start point for new branches |
| `warmup` | none | shell, run inside the new worktree |
| `after-create` | none | shell hook, run inside the new worktree |
| `before-remove` | none | shell hook, run in the main checkout |

Team settings belong in `.treehop`, personal ones in git config:

```sh
# .treehop, checked in
warmup = pnpm install --frozen-lockfile && bazel run //:gen_all
```

```sh
git config --global treehop.branch-prefix me/
git config treehop.worktree-dir ~/work/app-trees
git config treehop.after-create ~/dotfiles/hooks/open-in-tmux
```

Hooks and `warmup` receive `TREEHOP_REPO`, `TREEHOP_PATH`, `TREEHOP_BRANCH` and `TREEHOP_NAME`. They execute shell from the repo's `.treehop` file: trust it as you would the repo's build scripts.

`examples/` has the Bazel monorepo config and hooks this was extracted from, including ones that open and close a herdr workspace per worktree.

## Test

```sh
tests/smoke.sh
```

## License

MIT or Apache-2.0, at your option.
