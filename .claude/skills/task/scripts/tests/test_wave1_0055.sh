#!/usr/bin/env bash
# test_wave1_0055.sh — debt 0055: lifecycle-гейты block/unblock.
# block допустим только из open/in_progress; unblock — только из blocked;
# иначе exit 1 с ОТКАЗ; --force обходит с предупреждением и следом в ## Runs.
# Регресс ОБЯЗАН падать на коде до фикса (vacuous-контроль): до фикса block/unblock
# шли через _set_status без проверки исходного статуса — block done проходил (rc=0).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

echo "== 0055: block/unblock проверяют исходный статус =="

# --- Штатные переходы не сломаны ---
d="$(mk_repo)"
cli "$d" new "task A" >/dev/null
expect_rc 0 "block из open проходит" cli "$d" block 1 --reason "ждём деталь"
assert_eq "$(task_status "$d" 1)" "blocked" "block open -> blocked"
expect_rc 0 "unblock из blocked проходит" cli "$d" unblock 1
assert_eq "$(task_status "$d" 1)" "open" "unblock blocked -> open"
cli "$d" start 1 >/dev/null
expect_rc 0 "block из in_progress проходит" cli "$d" block 1 --reason "стоп"
assert_eq "$(task_status "$d" 1)" "blocked" "block in_progress -> blocked"
rm -rf "$d"

# --- Запреты (падали бы на до-фиксовом коде) ---
d="$(mk_repo)"
cli "$d" new "task B" >/dev/null
cli "$d" start 1 >/dev/null
cli "$d" close 1 >/dev/null   # -> done

out="$(cli "$d" block 1 --reason x 2>&1)"; rc=$?
assert_eq "$rc" "1" "block done -> exit 1"
assert_contains "$out" "ОТКАЗ" "block done печатает ОТКАЗ"
assert_contains "$out" "block только из open/in_progress" "block done: внятная причина"
assert_eq "$(task_status "$d" 1)" "done" "block done НЕ изменил статус"

out="$(cli "$d" unblock 1 2>&1)"; rc=$?
assert_eq "$rc" "1" "unblock done -> exit 1"
assert_contains "$out" "unblock только из blocked" "unblock не-blocked: внятная причина"
assert_eq "$(task_status "$d" 1)" "done" "unblock done НЕ изменил статус"
rm -rf "$d"

# unblock задачи в open (не blocked) → отказ
d="$(mk_repo)"
cli "$d" new "task C" >/dev/null
out="$(cli "$d" unblock 1 2>&1)"; rc=$?
assert_eq "$rc" "1" "unblock open -> exit 1"
assert_eq "$(task_status "$d" 1)" "open" "unblock open НЕ изменил статус"
rm -rf "$d"

# --- --force обходит гейт со следом в ## Runs ---
d="$(mk_repo)"
cli "$d" new "task D" >/dev/null
cli "$d" start 1 >/dev/null
cli "$d" close 1 >/dev/null   # -> done
out="$(cli "$d" block 1 --reason x --force 2>&1)"; rc=$?
assert_eq "$rc" "0" "block done --force -> проходит"
assert_contains "$out" "lifecycle обойдён" "block --force печатает предупреждение"
assert_eq "$(task_status "$d" 1)" "blocked" "block done --force -> blocked"
runs="$(sed -n '/## Runs/,/^## [^R]/p' "$d"/tasks/0001-*.md)"
assert_contains "$runs" "block --force из статуса done" "block --force оставил след в ## Runs"

# unblock --force из не-blocked статуса → тоже след
cli "$d" unblock 1 >/dev/null            # blocked -> open (штатно)
out="$(cli "$d" unblock 1 --force 2>&1)"; rc=$?   # open -> --force обход
assert_eq "$rc" "0" "unblock open --force -> проходит"
assert_contains "$out" "lifecycle обойдён" "unblock --force печатает предупреждение"
runs="$(sed -n '/## Runs/,/^## [^R]/p' "$d"/tasks/0001-*.md)"
assert_contains "$runs" "unblock --force из статуса open" "unblock --force оставил след в ## Runs"
rm -rf "$d"

echo "wave1_0055: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
