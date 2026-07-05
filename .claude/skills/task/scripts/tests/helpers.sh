#!/usr/bin/env bash
# helpers.sh — эфемерный git-репо + ассерты для тестов task CLI.
# Каждый тест работает в собственном репо из mktemp -d: живой трекер не трогается.
# Каркас волны 1; при доп. сценариях (test_multi.sh) переиспользовать эти функции.
set -u

: "${TASK_PY:?TASK_PY must point at .../scripts/task.py}"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# mk_repo — создать эфемерный git-репо с инициализированным трекером; печатает путь.
mk_repo() {
  local dir
  dir="$(mktemp -d)"
  (
    cd "$dir"
    git init -q
    git config user.email t@t
    git config user.name test
    git config commit.gpgsign false
    python3 "$TASK_PY" init >/dev/null
    git add -A
    git commit -qm init
    git branch -M main
  )
  echo "$dir"
}

# cli <dir> <args...> — запустить трекер внутри репо.
cli() { local dir="$1"; shift; ( cd "$dir" && python3 tasks/_cli.py "$@" ); }

# mk_worktree <repo> <name> — добавить второй worktree того же репо (общий .git,
# общая ветка task-sync) и принять состояние трекера. Печатает путь worktree.
# Используется multi-сценариями (R3/R6): два оркестратора над одним репозиторием.
mk_worktree() {
  local d="$1" name="$2" parent wt
  parent="$(mktemp -d)"
  wt="$parent/$name"
  git -C "$d" worktree add -q "$wt" -b "orch/$name" main >/dev/null 2>&1
  ( cd "$wt" && python3 tasks/_cli.py sync --adopt >/dev/null 2>&1 )
  echo "$wt"
}

# expect_rc <want> <label> <cmd...> — ассерт кода возврата команды.
expect_rc() {
  local want="$1" label="$2"; shift 2
  "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" = "$want" ]; then _pass; else _fail "$label: rc=$rc want $want"; fi
}

assert_contains()     { case "$1" in *"$2"*) _pass;; *) _fail "$3: '$2' not in output";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3: unexpected '$2'";; *) _pass;; esac; }
assert_eq()           { if [ "$1" = "$2" ]; then _pass; else _fail "$3: '$1' != '$2'"; fi; }

# task_status <dir> <id> — статус задачи из frontmatter.
task_status() {
  grep -m1 '^status:' "$1"/tasks/"$(printf '%04d' "$2")"-*.md | awk '{print $2}'
}
