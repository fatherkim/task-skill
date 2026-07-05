#!/usr/bin/env bash
# test_wave2_0059.sh — волна 2: Ф3 видимость кросс-оркестраторных deps в ready.
# Всё в эфемерных git-репо (mktemp); живой трекер agent_tasks/ не трогается.
#
# Vacuous-контроль: на до-фиксовом коде (нет секции «⚠ код зависимостей
# недоступен…» и счётчика HEAD..main в ready) файл ОБЯЗАН падать — все
# assert_contains по предупреждениям бьются об их отсутствие. Прогон:
#   TASK_PY=$(mktemp); git show main:.claude/skills/task/scripts/task.py > $TASK_PY
#   TASK_PY=$TASK_PY bash .../tests/test_wave2_0059.sh   # -> красный
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

# mk_f3_bench — эталонный двух-worktree стенд Ф3. Печатает "R A B":
#   R (main): 0001 dep(src/a.c), 0002 child(src/b.c, depends 0001); трекер закоммичен в main.
#   A, B — worktree-оркестраторы (orch/A, orch/B) от этого main.
#   B: ветка task/0001 (код feature.txt) + start/close 0001 + merge-main → main ушёл вперёд.
#   A ничего не мержил: HEAD (orch/A) отстал от main, task/0001 не ancestor HEAD.
mk_f3_bench() {
  local R A B
  R="$(mk_repo)"
  cli "$R" multi on >/dev/null 2>&1
  cli "$R" new "dep"   --files src/a.c >/dev/null                 # 0001
  cli "$R" new "child" --files src/b.c --depends 0001 >/dev/null  # 0002
  ( cd "$R" && git add -A && git commit -qm tasks )               # main чистый для merge-main
  A="$(mk_worktree "$R" A)"
  B="$(mk_worktree "$R" B)"
  ( cd "$B" && git checkout -q -b task/0001 main \
      && echo x > feature.txt && git add feature.txt && git commit -qm feat \
      && git checkout -q orch/B )
  cli "$B" start 1 --owner B >/dev/null 2>&1
  cli "$B" close 1 --owner B >/dev/null 2>&1
  cli "$B" merge-main 1 >/dev/null 2>&1
  echo "$R $A $B"
}

# =============================================================================
echo "== Ф3: двух-worktree — A видит предупреждение, после merge main оно исчезает =="
# =============================================================================
read -r R A B <<EOF
$(mk_f3_bench)
EOF
# санити стенда: merge-main прошёл в main (не в integration), A отстал
( cd "$R" && git merge-base --is-ancestor task/0001 main ) \
  && _pass || _fail "стенд: task/0001 влита в main"
( cd "$A" && git merge-base --is-ancestor task/0001 HEAD ) \
  && _fail "стенд: orch/A НЕ должен содержать task/0001" || _pass

# A без merge main: ready предупреждает, но диспатч не блокируется
out="$(cli "$A" ready 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф3 ready с предупреждением -> rc 0 (И7, не блокирует)"
assert_contains "$out" "Готовы к диспатчу" "Ф3 ready: список ready-задач на месте"
assert_contains "$out" "0002" "Ф3 ready: 0002 остаётся в ready-списке"
assert_contains "$out" "⚠ код зависимостей недоступен в этом worktree: 0001 (task/0001 не влита; сделай merge main)" \
  "Ф3 ready: предупреждение с id и рецептом merge main"
assert_contains "$out" "HEAD отстал от main" "Ф3 ready: общий счётчик отставания печатается"

# то же в ready --waves
out="$(cli "$A" ready --waves 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф3 ready --waves с предупреждением -> rc 0"
assert_contains "$out" "Волна 1: 0002" "Ф3 --waves: 0002 в волне 1"
assert_contains "$out" "⚠ код зависимостей недоступен в этом worktree: 0001 (task/0001 не влита; сделай merge main)" \
  "Ф3 --waves: то же предупреждение"

# A подтягивает main -> предупреждения исчезают
( cd "$A" && git merge -q main >/dev/null 2>&1 )
out="$(cli "$A" ready 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф3 после merge main: ready -> rc 0"
assert_contains "$out" "0002" "Ф3 после merge main: 0002 в ready"
assert_not_contains "$out" "код зависимостей недоступен" "Ф3 после merge main: предупреждение исчезло"
assert_not_contains "$out" "HEAD отстал от main" "Ф3 после merge main: счётчик отставания исчез"
rm -rf "$R" "$(dirname "$A")" "$(dirname "$B")"

# =============================================================================
echo "== Ф3: ветка dep удалена — предупреждения о ветке нет, но HEAD..main печатается =="
# =============================================================================
read -r R A B <<EOF
$(mk_f3_bench)
EOF
( cd "$R" && git branch -qD task/0001 )
behind="$(cd "$A" && git rev-list --count HEAD..main)"   # merge-commit + feat = 2
out="$(cli "$A" ready 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф3 удалённая ветка: rc 0"
assert_contains "$out" "0002" "Ф3 удалённая ветка: 0002 в ready"
assert_not_contains "$out" "код зависимостей недоступен" \
  "Ф3 удалённая ветка: предупреждения о ветке нет (код считается в main)"
assert_contains "$out" "⚠ HEAD отстал от main на $behind коммит" \
  "Ф3 удалённая ветка: печатается счётчик rev-list HEAD..main ($behind)"
rm -rf "$R" "$(dirname "$A")" "$(dirname "$B")"

# =============================================================================
echo "== Ф3: single-режим — вывод ready байт-в-байт как раньше (golden) =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "one" --files src/a.c >/dev/null   # 0001
cli "$d" new "two" --files src/a.c >/dev/null   # 0002 — конфликт файлов с 0001
# done-зависимость с живой веткой task/0001, не влитой в HEAD, — в single всё равно молчим
out="$(cli "$d" ready 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф3 single ready -> rc 0"
expected="Готовы к диспатчу:
  0001  one
  0002  two
  ! 0001 и 0002 пересекаются по файлам (src/a.c) — параллелить нельзя, выбери одну."
assert_eq "$out" "$expected" "Ф3 single: вывод ready байт-в-байт (golden)"
rm -rf "$d"

echo "wave2_0059: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
