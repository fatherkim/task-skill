#!/usr/bin/env bash
# test_regressions.sh — регрессии на подтверждённые баги волны 1.
# R1 (Ш1): планировщик видит каталоги как verify. R2 (Ш2): enforced lock.
# Плюс регрессия verify dir-prefix (0021/0028). Каждый R обязан ПАДАТЬ до фикса.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

echo "== R1: единый paths_conflict в планировщике (Ш1) =="

# R1a: src/ и src/foo.c не параллелятся — попадают в разные волны.
d="$(mk_repo)"
cli "$d" new "dir task" --files "src/" >/dev/null
cli "$d" new "file task" --files "src/foo.c" >/dev/null
out="$(cli "$d" ready --waves)"
assert_contains "$out" "Волна 2" "R1a src/ vs src/foo.c → разные волны"
rm -rf "$d"

# R1b: src/foo.c и src/foobar.c параллелятся (одна волна) — не переужесточили границу.
d="$(mk_repo)"
cli "$d" new "foo" --files "src/foo.c" >/dev/null
cli "$d" new "foobar" --files "src/foobar.c" >/dev/null
out="$(cli "$d" ready --waves)"
assert_not_contains "$out" "Волна 2" "R1b src/foo.c vs src/foobar.c → одна волна"
rm -rf "$d"

# R1c: ready(busy) — src/ в работе глушит открытую src/foo.c.
d="$(mk_repo)"
cli "$d" new "dir" --files "src/" >/dev/null
cli "$d" start 1 >/dev/null
cli "$d" new "file" --files "src/foo.c" >/dev/null
out="$(cli "$d" ready)"
assert_not_contains "$out" "0002" "R1c src/ занят → src/foo.c не готова"
rm -rf "$d"

echo "== R2: enforced lock — мутации под чужим _LOCK (Ш2) =="

# R2a: чужой lock без owner → close отказ (файл цел); свой owner (env) → проходит.
d="$(mk_repo)"
cli "$d" new "t" >/dev/null
cli "$d" start 1 >/dev/null
cli "$d" lock --owner A >/dev/null
expect_rc 1 "R2a close без owner под чужим _LOCK → exit 1" cli "$d" close 1
assert_eq "$(task_status "$d" 1)" "in_progress" "R2a файл задачи не изменён"
( cd "$d" && TASK_OWNER=A python3 tasks/_cli.py close 1 ) >/dev/null 2>&1
assert_eq "$(task_status "$d" 1)" "done" "R2a TASK_OWNER=A close → done"
rm -rf "$d"

# R2b: TASK_OWNER=B (чужой) → отказ, файл цел.
d="$(mk_repo)"
cli "$d" new "t" >/dev/null; cli "$d" start 1 >/dev/null; cli "$d" lock --owner A >/dev/null
( cd "$d" && TASK_OWNER=B python3 tasks/_cli.py close 1 ) >/dev/null 2>&1
assert_eq "$?" "1" "R2b TASK_OWNER=B close → exit 1"
assert_eq "$(task_status "$d" 1)" "in_progress" "R2b файл задачи не изменён"
rm -rf "$d"

# R2c: --force → осознанный обход с предупреждением.
d="$(mk_repo)"
cli "$d" new "t" >/dev/null; cli "$d" start 1 >/dev/null; cli "$d" lock --owner A >/dev/null
out="$(cli "$d" close 1 --force 2>&1)"
assert_contains "$out" "force" "R2c close --force → предупреждение об обходе"
assert_eq "$(task_status "$d" 1)" "done" "R2c close --force → done"
rm -rf "$d"

# R2d: без _LOCK всё работает как раньше (И5).
d="$(mk_repo)"
cli "$d" new "t" >/dev/null; cli "$d" start 1 >/dev/null
expect_rc 0 "R2d close без _LOCK → ok" cli "$d" close 1
rm -rf "$d"

# R2e: read-команда (ready) под чужим _LOCK не блокируется.
d="$(mk_repo)"
cli "$d" new "t" >/dev/null; cli "$d" lock --owner A >/dev/null
expect_rc 0 "R2e ready под чужим _LOCK → работает" cli "$d" ready
rm -rf "$d"

echo "== verify: dir-prefix покрытие (регрессия 0021/0028) =="

# Заявлен каталог docs/wiki/ — покрывает docs/wiki/x.md → OK.
d="$(mk_repo)"
cli "$d" new "wiki" --files "docs/wiki/" >/dev/null
(
  cd "$d"
  git add -A && git commit -qm "add task"
  git checkout -q -b task/0001
  mkdir -p docs/wiki && echo x > docs/wiki/x.md
  git add -A && git commit -qm "wiki change"
  git checkout -q main
)
expect_rc 0 "verify: docs/wiki/ покрывает docs/wiki/x.md" cli "$d" verify 1 --base main --branch task/0001
rm -rf "$d"

# Файл вне заявленного (src/foobar.c при files=src/foo.c) → ПРОВАЛ.
d="$(mk_repo)"
cli "$d" new "src" --files "src/foo.c" >/dev/null
(
  cd "$d"
  git add -A && git commit -qm "add task"
  git checkout -q -b task/0001
  mkdir -p src && echo x > src/foobar.c
  git add -A && git commit -qm "wrong file"
  git checkout -q main
)
expect_rc 1 "verify: src/foobar.c вне files → ПРОВАЛ" cli "$d" verify 1 --base main --branch task/0001
rm -rf "$d"

# M1: скрытый корневой файл .env НЕ покрывается каталогом env/ (ведущая точка
# != ./-префикс) — как на main. Регресс _norm_path lstrip("./") даёт ложное OK.
d="$(mk_repo)"
cli "$d" new "env" --files "env/" >/dev/null
(
  cd "$d"
  git add -A && git commit -qm "add task"
  git checkout -q -b task/0001
  echo x > .env
  git add -A && git commit -qm "root .env"
  git checkout -q main
)
expect_rc 1 "verify: .env вне env/ (скрытый файл) → ПРОВАЛ" cli "$d" verify 1 --base main --branch task/0001
rm -rf "$d"

echo "regressions: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
