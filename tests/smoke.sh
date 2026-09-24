#!/usr/bin/env bash
# Smoke test in a throwaway HOME with a local "origin". Run: tests/smoke.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME=$tmp GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PATH=$here/bin:$PATH
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass+1)); echo "ok  $*"; }

# origin with a main branch, then a clone to work in
git init -q -b main "$tmp/origin"; (cd "$tmp/origin" && echo a >a && git add a && git commit -qm init)
git clone -q "$tmp/origin" "$tmp/repo"
repo=$tmp/repo
cd "$repo"

treehop --help >/dev/null || fail "--help exit code"; ok "--help exits 0"
treehop 2>/dev/null && fail "no-arg should exit 1"; ok "no args exits 1"
treehop version | grep -q '^treehop ' || fail version; ok version

# config: file gives team defaults, git config overrides
printf 'warmup = echo warm:$TREEHOP_NAME > warmed\nbranch-prefix = team/\n' > .treehop
git config treehop.branch-prefix me/
git config treehop.after-create 'echo "$TREEHOP_BRANCH" > "$TREEHOP_REPO/hook-after"'
git config treehop.before-remove 'echo "$TREEHOP_PATH" > "$TREEHOP_REPO/hook-before"'
mkdir -p "$HOME/.claude/projects/$(printf '%s' "$repo" | sed 's#[^A-Za-z0-9-]#-#g')/memory"

# subcommand --help never creates anything; option-looking names are rejected
treehop new --help >/dev/null || fail "new --help exit"
treehop rm -h >/dev/null || fail "rm -h exit"
treehop new -x 2>/dev/null && fail "new -x should fail"
[[ -z $(git worktree list | sed 1d) ]] && ! git show-ref -q --verify 'refs/heads/me/--help' || fail "--help created a worktree"; ok "subcommand --help is side-effect free"

# new: precedence, path mangling, no upstream, warmup, hook, memory symlink
treehop new foo >/dev/null
wt=$tmp/repo.worktrees/me-foo
[[ -d $wt ]] || fail "worktree dir $wt"; ok "worktree at <parent>/<repo>.worktrees/<prefix->name"
[[ $(git -C "$wt" branch --show-current) == me/foo ]] || fail "branch prefix from git config"; ok "git config beats .treehop"
git -C "$wt" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null && fail "upstream should be unset"; ok "no upstream"
[[ $(cat "$wt/warmed") == warm:foo ]] || fail "warmup ran with TREEHOP_NAME"; ok "warmup in worktree, env set"
[[ $(cat hook-after) == me/foo ]] || fail "after-create hook"; ok "after-create hook"
[[ -L $HOME/.claude/projects/$(printf '%s' "$wt" | sed 's#[^A-Za-z0-9-]#-#g')/memory ]] || fail "memory symlink"; ok "Claude memory shared"
treehop new foo 2>/dev/null && fail "duplicate path should fail"; ok "refuses existing path"

# reuse an existing branch
git branch me/bar main
treehop new bar >/dev/null
[[ $(git -C "$tmp/repo.worktrees/me-bar" branch --show-current) == me/bar ]] || fail reuse; ok "reuses existing branch"

# ls from inside a linked worktree still sees the main checkout's list
out=$(cd "$wt" && treehop ls)
grep -q 'me/bar.*merged' <<<"$out" || fail "ls merged: $out"
grep -q 'me/foo.*dirty' <<<"$out" || fail "ls dirty: $out"; ok "ls shows merged (from a linked worktree)"

# rm: dirty refusal, --force, hook, branch kept, resolve by name/prefixed/path
echo x > "$wt/dirty"
treehop rm foo 2>/dev/null && fail "dirty should refuse"; ok "refuses dirty tree"
(cd "$tmp/repo.worktrees/me-bar" && treehop rm --force foo) >/dev/null
[[ ! -d $wt ]] || fail "rm --force"; ok "rm --force from another worktree"
[[ $(cat hook-before) == "$wt" ]] || fail "before-remove hook"; ok "before-remove hook"
git show-ref --verify -q refs/heads/me/foo || fail "branch deleted"; ok "branch kept"
treehop rm "$tmp/repo.worktrees/me-bar" --force >/dev/null; ok "rm by path, --force in any position"
treehop rm "$repo" 2>/dev/null && fail "main checkout"; ok "refuses main checkout"
treehop rm nope 2>/dev/null && fail "missing"; ok "missing worktree errors"

# relative worktree-dir resolves against the main checkout, even from a subdirectory
git config treehop.worktree-dir ../rel-trees
printf 'warmup = touch warmed\n' > .treehop
mkdir -p sub && (cd sub && treehop new rel >/dev/null 2>&1)
[[ -f $tmp/rel-trees/me-rel/warmed ]] || fail "relative worktree-dir from subdir"; ok "relative worktree-dir resolves against the repo"
phys=$(cd "$tmp/rel-trees/me-rel" && pwd -P)
[[ -L $HOME/.claude/projects/$(printf '%s' "$phys" | sed 's#[^A-Za-z0-9-]#-#g')/memory ]] || fail "memory link keyed by physical path"; ok "memory link keyed by the physical worktree path"
treehop rm --force rel >/dev/null; rmdir sub; git config --unset treehop.worktree-dir

# a stale memory symlink from an earlier worktree is replaced
stale=$HOME/.claude/projects/$(printf '%s' "$tmp/repo.worktrees/me-again" | sed 's#[^A-Za-z0-9-]#-#g')
mkdir -p "$stale" && ln -s /nonexistent "$stale/memory"
treehop new again >/dev/null 2>&1 || fail "new with stale memory link"
[[ -d $stale/memory ]] || fail "stale memory link not replaced"; ok "stale Claude memory link replaced"
treehop rm --force again >/dev/null

# a before-remove hook that removes the worktree itself (as herdr does) doesn't stop cleanup
treehop new hookrm >/dev/null 2>&1
git config treehop.before-remove 'git -C "$TREEHOP_REPO" worktree remove --force "$TREEHOP_PATH"'
treehop rm --force hookrm >/dev/null 2>&1 || fail "rm after hook removed the worktree"
[[ ! -d $tmp/repo.worktrees/me-hookrm ]] || fail "hookrm still there"; ok "rm survives a hook that removed the worktree"
git config --unset treehop.before-remove

# bazel output base: deleted when owned by the worktree, left alone otherwise
mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/bazel" <<'FB'
#!/usr/bin/env bash
case $1 in info) cat "$FAKE_OB_FILE";; shutdown) :;; esac
FB
chmod +x "$tmp/fakebin/bazel"; PATH=$tmp/fakebin:$PATH
export FAKE_OB_FILE=$tmp/fake-ob
(cd "$tmp/origin" && touch MODULE.bazel && git add MODULE.bazel && git commit -qm bazel); git pull -q
rm -f .treehop
treehop new bz >/dev/null 2>&1; wt=$tmp/repo.worktrees/me-bz
owned=$tmp/outbase-owned; mkdir -p "$owned/execroot"; printf '%s' "$wt" > "$owned/DO_NOT_BUILD_HERE"; chmod a-w "$owned/execroot"
echo "$owned" > "$FAKE_OB_FILE"
git config treehop.before-remove 'git -C "$TREEHOP_REPO" worktree remove --force "$TREEHOP_PATH"'
treehop rm bz >/dev/null 2>&1
git config --unset treehop.before-remove
[[ ! -e $owned ]] || fail "owned output base not deleted"; ok "owned bazel output base deleted (read-only dirs too)"
treehop new bz2 >/dev/null 2>&1; wt=$tmp/repo.worktrees/me-bz2
shared=$tmp/outbase-shared; mkdir -p "$shared"; printf '%s' "$repo" > "$shared/DO_NOT_BUILD_HERE"
echo "$shared" > "$FAKE_OB_FILE"
treehop rm bz2 2>"$tmp/err" >/dev/null
[[ -d $shared ]] || fail "shared output base was deleted"
grep -q "not owned" "$tmp/err" || fail "no warning for shared output base"; ok "unowned bazel output base left alone, with a warning"
# marker scan finds it without asking bazel
treehop new bz3 >/dev/null 2>&1; wt=$tmp/repo.worktrees/me-bz3
scan=$HOME/.cache/bazel/_bazel_$USER/abc123; mkdir -p "$scan"; printf '%s' "$wt" > "$scan/DO_NOT_BUILD_HERE"
echo /nonexistent > "$FAKE_OB_FILE"
treehop rm bz3 >/dev/null 2>&1
[[ ! -e $scan ]] || fail "scanned output base not deleted"; ok "marker-file scan finds the output base"

echo "all $pass passed"
