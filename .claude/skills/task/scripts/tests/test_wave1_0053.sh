#!/usr/bin/env bash
# test_wave1_0053.sh — регрессии задачи 0053 (волна 1): Ш4 close lifecycle + Ш5 multi status sync.
# R4: close вне in_progress -> exit 1 (lifecycle); --force обходит с Runs-следом.
# R5: multi status синхронизируется перед выводом (чужой in_progress виден без ручного sync).
# Каждый R-регресс обязан ПАДАТЬ на коде до фикса (vacuous-контроль).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

echo "== R4: close только из in_progress (Ш4) =="

# R4a: close open-задачи (без start) -> exit 1, файл не тронут.
d="$(mk_repo)"
cli "$d" new "t" >/dev/null
expect_rc 1 "R4a close open (без start) -> exit 1" cli "$d" close 1
assert_eq "$(task_status "$d" 1)" "open" "R4a файл задачи не изменён (остался open)"
rm -rf "$d"

# R4b: close blocked-задачи -> exit 1.
d="$(mk_repo)"
cli "$d" new "t" >/dev/null
cli "$d" block 1 --reason "test" >/dev/null
expect_rc 1 "R4b close blocked -> exit 1" cli "$d" close 1
assert_eq "$(task_status "$d" 1)" "blocked" "R4b файл задачи не изменён (остался blocked)"
rm -rf "$d"

# R4c: после start -> close проходит.
d="$(mk_repo)"
cli "$d" new "t" >/dev/null
cli "$d" start 1 >/dev/null
expect_rc 0 "R4c close после start -> ok" cli "$d" close 1
assert_eq "$(task_status "$d" 1)" "done" "R4c статус done"
rm -rf "$d"

# R4d: close --force из open -> проходит, в Runs есть след «close --force из статуса open».
d="$(mk_repo)"
cli "$d" new "t" >/dev/null
out="$(cli "$d" close 1 --force 2>&1)"
assert_eq "$(task_status "$d" 1)" "done" "R4d close --force из open -> done"
body="$(cat "$d"/tasks/0001-*.md 2>/dev/null || cat "$d"/tasks/archive/0001-*.md 2>/dev/null)"
assert_contains "$body" "close --force из статуса open" "R4d Runs-след про force из статуса open"
rm -rf "$d"

echo "== R5: multi status синхронизируется перед выводом (Ш5) =="

# R5: B берёт задачу -> multi status в A сразу видит in_progress без ручного sync.
d="$(mk_repo)"
cli "$d" multi on >/dev/null
cli "$d" new "a" >/dev/null                      # задача 1, open
B="$(mk_worktree "$d" B)"
cli "$B" start 1 --owner B >/dev/null            # B взял задачу — в task-sync
# A: multi status БЕЗ ручного sync — должен увидеть in_progress
out="$(cli "$d" multi status 2>&1)"
assert_contains "$out" "in_progress: 0001" "R5 multi status видит чужой start без ручного sync"
rm -rf "$d" "$(dirname "$B")"

# R5-hint-a: multi включён (клон B), локально _MULTI нет, вершина task-sync ЕЩЁ несёт
# _MULTI -> подсказка sync --adopt (честная, не по факту существования ветки).
d="$(mk_repo)"
cli "$d" multi on >/dev/null                     # создаёт ветку task-sync с _MULTI
rm -f "$d"/tasks/_MULTI                          # локально «отвалились» от multi
out="$(cli "$d" multi status 2>&1)"
assert_contains "$out" "sync --adopt" "R5-hint-a _MULTI нет + task-sync несёт _MULTI -> подсказка"
rm -rf "$d"

# R5-hint-b (M1 fix): multi on -> multi off -> multi status -> подсказки НЕТ.
# multi off не удаляет ветку task-sync (она остаётся навсегда), но снимает _MULTI
# с её вершины — грубая проверка «ветка существует» даёт ложную подсказку НАВСЕГДА
# после штатного цикла on->off; честная проверка смотрит содержимое вершины ветки.
d="$(mk_repo)"
cli "$d" multi on >/dev/null
cli "$d" multi off >/dev/null
out="$(cli "$d" multi status 2>&1)"
assert_not_contains "$out" "sync --adopt" "R5-hint-b после multi off -> подсказки НЕТ"
rm -rf "$d"

# R5-single: single-режим — multi status НЕ создаёт ветку task-sync.
d="$(mk_repo)"
cli "$d" new "solo" >/dev/null
cli "$d" multi status >/dev/null 2>&1
branches="$( cd "$d" && git branch --list task-sync )"
assert_eq "$branches" "" "R5-single multi status не создал ветку task-sync"
rm -rf "$d"

echo "wave1_0053: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
