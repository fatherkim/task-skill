#!/usr/bin/env bash
# test_multi.sh — Ш9-порт утраченных scratchpad-стендов multitest.sh/multitest2.sh.
# Восстановлено по описанию Ш9 (docs/impl_spec_task_upgrade_2026-07-04.md строки
# 115-128: сценарии T1-T10) и фактическому поведению текущего кода task.py.
# Всё в эфемерных git-репо (mktemp); живой трекер agent_tasks/ не трогается.
#
# T-сценарии фиксируют ТЕКУЩЕЕ поведение (vacuous-контроль для них не требуется,
# но каждая проверка — реальный ассерт grep/rc, не безусловный echo PASS).
# Невоспроизводимый сценарий помечается SKIPPED с причиной (здесь таких нет).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

# runs_section <dir> <id> — секция ## Runs задачи (до следующего ## не-Runs).
runs_section() { sed -n '/## Runs/,/^## [^R]/p' "$1"/tasks/"$(printf '%04d' "$2")"-*.md; }

# set_depends <dir> <id> <val> — переписать depends: в frontmatter (для цикла T4,
# т.к. `new` не умеет back-reference на ещё не созданную задачу).
set_depends() {
  python3 - "$1" "$(printf '%04d' "$2")" "$3" <<'PY'
import sys, re, glob
d, tid, val = sys.argv[1], sys.argv[2], sys.argv[3]
fn = glob.glob(d + "/tasks/" + tid + "-*.md")[0]
s = open(fn).read()
open(fn, "w").write(re.sub(r'^depends:.*$', 'depends: ' + val, s, flags=re.M))
PY
}

# ===================================================================
echo "== Базовая multi-функциональность (порт multitest.sh) =="
# ===================================================================
A="$(mk_repo)"
out="$(cli "$A" multi on 2>&1)"; rc=$?
assert_eq "$rc" "0" "multi on -> rc 0"
assert_contains "$out" "Multi-режим ВКЛ" "multi on печатает 'Multi-режим ВКЛ'"
[ -f "$A/tasks/_MULTI" ] && _pass || _fail "multi on создаёт _MULTI"
( cd "$A" && git rev-parse --verify -q refs/heads/task-sync >/dev/null ) \
  && _pass || _fail "multi on создаёт ветку task-sync"

cli "$A" new "shared" >/dev/null      # 0001 -> коммитится в task-sync
# второй worktree принимает состояние ветки
B="$(mk_worktree "$A" B)"
assert_eq "$(task_status "$B" 1)" "open" "worktree B через sync --adopt видит задачу 0001"

# claim: start в multi требует --owner
out="$(cli "$B" start 1 2>&1)"; rc=$?
assert_eq "$rc" "1" "start без --owner в multi -> отказ"
assert_contains "$out" "требует --owner" "start без owner: внятная причина"
# B берёт задачу
expect_rc 0 "B: start 1 --owner B" cli "$B" start 1 --owner B
# A подтягивает через multi status и видит чужой in_progress (это же R5)
out="$(cli "$A" multi status 2>&1)"
assert_contains "$out" "in_progress: 0001" "A: multi status видит чужой claim без ручного sync"
assert_contains "$out" "owner=B" "A: multi status показывает owner=B"

# owner-guard: A не может закрыть задачу B без --force
out="$(cli "$A" close 1 --owner A 2>&1)"; rc=$?
assert_eq "$rc" "1" "A close чужой задачи B -> отказ"
assert_contains "$out" "принадлежит owner=B" "close чужой: owner-guard срабатывает"

# multi off при живом in_progress -> отказ; --force -> проходит
out="$(cli "$A" multi off 2>&1)"; rc=$?
assert_eq "$rc" "1" "multi off при in_progress -> отказ"
assert_contains "$out" "in_progress" "multi off: причина про in_progress"
expect_rc 0 "multi off --force при in_progress" cli "$A" multi off --force
[ -f "$A/tasks/_MULTI" ] && _fail "multi off --force снял _MULTI" || _pass
rm -rf "$A" "$B" "$(dirname "$B")"

# ===================================================================
echo "== T1: _SCHEMA-гейт (init/multi on пишут; 99 -> отказ; missing -> работает) =="
# ===================================================================
d="$(mk_repo)"
assert_eq "$(cat "$d/tasks/_SCHEMA" 2>/dev/null)" "2" "T1 init пишет _SCHEMA=2"
cli "$d" multi on >/dev/null 2>&1
assert_eq "$(cat "$d/tasks/_SCHEMA")" "2" "T1 multi on держит _SCHEMA=2"
cli "$d" multi off >/dev/null 2>&1
echo 99 > "$d/tasks/_SCHEMA"
out="$(cli "$d" new "x" 2>&1)"; rc=$?
assert_eq "$rc" "1" "T1 _SCHEMA=99 -> мутирующая команда отказывает"
assert_contains "$out" "схемы v99" "T1 отказ по версии схемы внятен"
rm -f "$d/tasks/_SCHEMA"
expect_rc 0 "T1 без _SCHEMA (legacy v1) команды работают" cli "$d" new "y"
rm -rf "$d"

# ===================================================================
echo "== T2: return --owner (returns++, ## Возврат, строка Runs, чужой отказ, 3->ЦИКЛ) =="
# ===================================================================
A="$(mk_repo)"
cli "$A" multi on >/dev/null 2>&1
cli "$A" new "job" >/dev/null
B="$(mk_worktree "$A" B)"
cli "$B" start 1 --owner B >/dev/null 2>&1
# чужой return из A (owner A) -> отказ
out="$(cli "$A" return 1 --reason "nope" --owner A 2>&1)"; rc=$?
assert_eq "$rc" "1" "T2 чужой return из A -> отказ"
assert_contains "$out" "принадлежит owner=B" "T2 return owner-guard"
# свой return из B
out="$(cli "$B" return 1 --reason "почини X" --owner B 2>&1)"; rc=$?
assert_eq "$rc" "0" "T2 return владельцем B проходит"
assert_contains "$out" "возврат #1" "T2 печатает возврат #1"
assert_eq "$(grep -c '## Возврат' "$B"/tasks/0001-*.md)" "1" "T2 секция ## Возврат создана"
assert_eq "$(grep -m1 '^returns:' "$B"/tasks/0001-*.md | awk '{print $2}')" "1" "T2 returns=1"
assert_contains "$(runs_section "$B" 1)" "returned" "T2 строка returned в ## Runs"
# 2-й и 3-й возврат -> предупреждение о цикле
cli "$B" return 1 --reason "again" --owner B >/dev/null 2>&1
out="$(cli "$B" return 1 --reason "again2" --owner B 2>&1)"
assert_contains "$out" "ЦИКЛ" "T2 3-й возврат -> ⚠ ЦИКЛ (circuit breaker)"
rm -rf "$A" "$B" "$(dirname "$B")"

# ===================================================================
echo "== T3: close/block пишут строки в ## Runs =="
# ===================================================================
d="$(mk_repo)"
cli "$d" new "a" >/dev/null
cli "$d" start 1 >/dev/null
cli "$d" block 1 --reason "деталь" >/dev/null
assert_contains "$(runs_section "$d" 1)" "blocked" "T3 block пишет строку 'blocked' в ## Runs"
cli "$d" unblock 1 >/dev/null
cli "$d" start 1 >/dev/null
cli "$d" close 1 --note "ок" >/dev/null
assert_contains "$(runs_section "$d" 1)" "closed" "T3 close пишет строку 'closed' в ## Runs"
rm -rf "$d"

# ===================================================================
echo "== T4: ready --waves (топосорт + разведение файлов + детект цикла) =="
# ===================================================================
d="$(mk_repo)"
cli "$d" new "one"   --files src/a.c >/dev/null              # 0001
cli "$d" new "two"   --files src/b.c --depends 0001 >/dev/null  # 0002 dep 0001
cli "$d" new "three" --files src/c.c >/dev/null              # 0003 независима
cli "$d" new "four"  --files src/c.c >/dev/null              # 0004 files конфликт с 0003
out="$(cli "$d" ready --waves 2>&1)"
w1="$(printf '%s\n' "$out" | grep '^Волна 1:')"
w2="$(printf '%s\n' "$out" | grep '^Волна 2:')"
assert_contains "$w1" "0001" "T4 Волна 1 содержит 0001"
assert_contains "$w1" "0003" "T4 Волна 1 содержит 0003"
assert_not_contains "$w1" "0004" "T4 Волна 1 НЕ содержит 0004 (файловый конфликт с 0003)"
assert_contains "$w2" "0002" "T4 Волна 2 содержит 0002 (после depends 0001)"
assert_contains "$w2" "0004" "T4 Волна 2 содержит 0004"
assert_contains "$w2" "отложена из-за файлов" "T4 0004 помечена 'отложена из-за файлов'"
rm -rf "$d"
# Ф13 (задача 0063): тот же топосорт, но СЫРОЙ --depends 1 (без zero-pad). Раньше
# T4 проходил только с padded id — обход дефекта Ф13; здесь обход снят (padded
# вариант выше сохранён). Красный до фикса 0063: cmd_new писал "1", планировщик
# матчил против "0001" -> 0002 застревало в «Ждут» вместо волны 2.
d="$(mk_repo)"
cli "$d" new "one" --files src/a.c >/dev/null                 # 0001
cli "$d" new "two" --files src/b.c --depends 1 >/dev/null     # 0002 dep СЫРОЙ 1
out="$(cli "$d" ready --waves 2>&1)"
w1="$(printf '%s\n' "$out" | grep '^Волна 1:')"
w2="$(printf '%s\n' "$out" | grep '^Волна 2:')"
assert_contains "$w1" "0001" "T4-raw Волна 1 содержит 0001"
assert_contains "$w2" "0002" "T4-raw Волна 2 содержит 0002 (сырой depends 1 нормализован)"
assert_contains "$w2" "после 0001" "T4-raw 0002 помечена '(после 0001)'"
assert_not_contains "$out" "Ждут" "T4-raw 0002 не застряла"
rm -rf "$d"
# цикл A->B->A -> exit 1 с перечислением
d="$(mk_repo)"
cli "$d" new "A" >/dev/null
cli "$d" new "B" >/dev/null
set_depends "$d" 1 "0002"
set_depends "$d" 2 "0001"
cli "$d" index >/dev/null
out="$(cli "$d" ready --waves 2>&1)"; rc=$?
assert_eq "$rc" "1" "T4 цикл зависимостей -> exit 1"
assert_contains "$out" "ЦИКЛ зависимостей" "T4 печатает 'ЦИКЛ зависимостей'"
assert_contains "$out" "0001 -> 0002 -> 0001" "T4 цикл перечисляет участников"
rm -rf "$d"

# ===================================================================
echo "== T5: new --risk 3 -> frontmatter risk; ready показывает [r3] =="
# ===================================================================
d="$(mk_repo)"
cli "$d" new "danger" --risk 3 >/dev/null
assert_eq "$(grep -m1 '^risk:' "$d"/tasks/0001-*.md | awk '{print $2}')" "3" "T5 risk:3 в frontmatter"
assert_contains "$(cli "$d" ready 2>&1)" "[r3]" "T5 ready показывает [r3]"
# risk 0/1 не показываются как [rN] (порог >=2)
cli "$d" new "trivial" --risk 0 >/dev/null
out="$(cli "$d" ready 2>&1)"
assert_not_contains "$out" "0002 [r" "T5 risk 0 не помечается [rN] (порог r>=2)"
rm -rf "$d"

# ===================================================================
echo "== T6: merge-main грязный main -> авто-fallback в integration; --no-fallback -> отказ =="
# ===================================================================
d="$(mk_repo)"
( cd "$d"; echo base > tracked.txt; git add tracked.txt; git commit -qm tracked
  git checkout -q -b task/0001; echo feat > feat.txt; git add feat.txt; git commit -qm feat
  git checkout -q main; echo modified >> tracked.txt )   # main грязный (tracked)
out="$(cli "$d" merge-main --branch task/0001 2>&1)"; rc=$?
assert_eq "$rc" "0" "T6 грязный main -> merge проходит (fallback)"
assert_contains "$out" "влито в integration" "T6 сообщение про fallback в integration"
( cd "$d"; git rev-parse --verify -q integration >/dev/null ) && _pass || _fail "T6 ветка integration создана"
( cd "$d"; git merge-base --is-ancestor task/0001 integration ) && _pass || _fail "T6 task/0001 влита в integration"
( cd "$d"; git merge-base --is-ancestor task/0001 main 2>/dev/null ) && _fail "T6 main НЕ должен быть тронут" || _pass
rm -rf "$d"
# --no-fallback -> старый отказ
d="$(mk_repo)"
( cd "$d"; echo base > tr.txt; git add tr.txt; git commit -qm tr
  git checkout -q -b task/0001; echo f > f.txt; git add f.txt; git commit -qm f
  git checkout -q main; echo mod >> tr.txt )
out="$(cli "$d" merge-main --branch task/0001 --no-fallback 2>&1)"; rc=$?
assert_eq "$rc" "1" "T6 --no-fallback при грязном main -> отказ"
assert_contains "$out" "ГРЯЗНОЕ" "T6 --no-fallback: причина про грязное дерево"
rm -rf "$d"

# ===================================================================
echo "== T7: merge-main конфликт + --resolve -> worktree _merge/NNNN; после резолва merge проходит =="
# ===================================================================
d="$(mk_repo)"
( cd "$d"; echo main1 > f.txt; git add f.txt; git commit -qm mainf
  git checkout -q -b task/0001; echo taskv > f.txt; git commit -aqm taskf
  git checkout -q main; echo main2 > f.txt; git commit -aqm mainf2 )
out="$(cli "$d" merge-main 1 --resolve 2>&1)"
wt="$(printf '%s\n' "$out" | grep 'Площадка резолва' | sed -E 's/^Площадка резолва: ([^ ]+).*/\1/')"
assert_contains "$out" "_merge/0001" "T7 подсказка называет ветку _merge/0001"
[ -n "$wt" ] && [ -d "$wt" ] && _pass || _fail "T7 создан worktree резолва"
assert_eq "$(cd "$wt" && git rev-parse --abbrev-ref HEAD)" "_merge/0001" "T7 worktree на ветке _merge/0001"
[ "$(grep -c '<<<<<<<' "$wt/f.txt")" -ge 1 ] && _pass || _fail "T7 в worktree есть конфликтные маркеры"
# ручной резолв: берём версию ветки задачи + commit, затем merge-main --branch _merge/0001
( cd "$wt"; git checkout --theirs f.txt 2>/dev/null; git add f.txt; git commit -qm resolved )
out2="$(cli "$d" merge-main 1 --branch _merge/0001 2>&1)"; rc=$?
assert_eq "$rc" "0" "T7 после резолва merge-main --branch _merge/0001 проходит"
( cd "$d"; git merge-base --is-ancestor _merge/0001 main ) && _pass || _fail "T7 резолв-ветка влита в main"
rm -rf "$d" "$wt"

# ===================================================================
echo "== T8: depends-гейт (dep не done -> отказ; закрыли и влили -> проходит) =="
# ===================================================================
d="$(mk_repo)"
cli "$d" new "dep"   >/dev/null                    # 0001
cli "$d" new "child" --depends 0001 >/dev/null     # 0002 depends 0001
( cd "$d"; git add -A; git commit -qm tasks
  git checkout -q -b task/0001; echo a > a.txt; git add a.txt; git commit -qm a
  git checkout -q main
  git checkout -q -b task/0002; echo b > b.txt; git add b.txt; git commit -qm b
  git checkout -q main )
out="$(cli "$d" merge-main 2 2>&1)"; rc=$?
assert_eq "$rc" "1" "T8 dep 0001 не done -> merge 0002 отказ"
assert_contains "$out" "зависимость 0001 не закрыта" "T8 причина: зависимость не закрыта"
# закрываем и вливаем 0001
cli "$d" start 1 >/dev/null; cli "$d" close 1 >/dev/null
cli "$d" merge-main 1 >/dev/null 2>&1
out="$(cli "$d" merge-main 2 2>&1)"; rc=$?
assert_eq "$rc" "0" "T8 после закрытия+влития 0001 merge 0002 проходит"
rm -rf "$d"

# ===================================================================
echo "== T9: дубль id -> в выводе sync блок «Задание на разбор дубля» с реальными id =="
# ===================================================================
A="$(mk_repo)"
cli "$A" multi on >/dev/null 2>&1
cli "$A" new "alpha" >/dev/null            # 0001-alpha в task-sync
B="$(mk_worktree "$A" B)"
# симуляция независимой нумерации (crash-window/ручной mis-number): второй 0001 в B
cat > "$B/tasks/0001-beta.md" <<'EOF'
---
id: 0001
status: open
title: beta
files:
depends:
created: 2026-07-05
---
## Задача
beta
EOF
out="$(cli "$B" sync 2>&1)"
assert_contains "$out" "ДУБЛЬ id 0001" "T9 sync детектит дубль id 0001"
assert_contains "$out" "Задание на разбор дубля" "T9 печатает блок задания на разбор"
assert_contains "$out" "0001-alpha.md, 0001-beta.md" "T9 перечисляет реальные файлы-дубли"
rm -rf "$A" "$B" "$(dirname "$B")"

# ===================================================================
echo "== T10: single-mode регрессия (return без owner, ready --waves, lifecycle) =="
# ===================================================================
d="$(mk_repo)"
# single lifecycle без owner-требований
cli "$d" new "s" >/dev/null
expect_rc 0 "T10 single start без owner" cli "$d" start 1
# return в single без --owner работает, инкрементит returns
out="$(cli "$d" return 1 --reason "доработка" 2>&1)"; rc=$?
assert_eq "$rc" "0" "T10 single return без owner проходит"
assert_eq "$(grep -m1 '^returns:' "$d"/tasks/0001-*.md | awk '{print $2}')" "1" "T10 single return инкрементит returns"
expect_rc 0 "T10 single close" cli "$d" close 1
# ready --waves в single-режиме
cli "$d" new "p" >/dev/null
cli "$d" new "q" --depends 0002 >/dev/null
out="$(cli "$d" ready --waves 2>&1)"; rc=$?
assert_eq "$rc" "0" "T10 single ready --waves -> rc 0"
assert_contains "$out" "Волна 1: 0002" "T10 single ready --waves строит волны"
# ни _MULTI, ни task-sync в single-режиме не появились
[ -f "$d/tasks/_MULTI" ] && _fail "T10 single НЕ должен иметь _MULTI" || _pass
( cd "$d"; git rev-parse --verify -q refs/heads/task-sync >/dev/null ) \
  && _fail "T10 single НЕ должен создавать task-sync" || _pass
rm -rf "$d"
# T10: run.sh держит существующие single-стенды зелёными (подключены как раньше)
for t in test_regressions.sh test_wave1_0051.sh test_wave1_0053.sh test_wave1_0054.sh test_unit.py; do
  grep -q "$t" "$HERE/run.sh" && _pass || _fail "T10 run.sh подключает $t"
done

echo "test_multi: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
