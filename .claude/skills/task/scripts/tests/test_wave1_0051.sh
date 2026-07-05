#!/usr/bin/env bash
# test_wave1_0051.sh — регрессии задачи 0051 (волна 1): Ш3 merge-main sync + Ш6 stats.
# R3: merge-main синхронизирует трекер до depends-гейта (двух-клоновый сценарий).
# R6: stats синхронизируется в multi + честное среднее (числитель/знаменатель — одно множество).
# Каждый R-регресс обязан ПАДАТЬ на коде до фикса (vacuous-контроль).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

echo "== R3: merge-main берёт свежий task-sync до depends-гейта (Ш3) =="

# R3a (forward): B закрыл зависимость в task-sync; A с устаревшим локальным open
# вызывает merge-main — гейт видит done, блокировки «не закрыта» нет.
d="$(mk_repo)"
cli "$d" multi on >/dev/null
cli "$d" new "dep" >/dev/null                    # задача 1 (зависимость)
cli "$d" new "dependent" --depends 1 >/dev/null  # задача 2 (depends: 1)
# ветка исполнителя task/0002 с кодовой правкой (uncommitted трекер не стейджим)
( cd "$d" && git checkout -q -b task/0002 && echo x > feature.txt \
    && git add feature.txt && git commit -qm feat && git checkout -q main )
B="$(mk_worktree "$d" B)"
cli "$B" start 1 --owner B >/dev/null
cli "$B" close 1 --owner B >/dev/null            # task1 -> done, ушла в task-sync
# A НЕ синхронизируется вручную: локально task1 всё ещё open
out="$(cli "$d" merge-main 2 --base main 2>&1)"
assert_not_contains "$out" "не закрыта" "R3a merge-main видит done из task-sync (гейт не блокирует)"
assert_eq "$(task_status "$d" 1)" "done" "R3a после merge-main локальный task1 подтянут в done"
rm -rf "$d" "$(dirname "$B")"

# R3b (reverse): локально done (устарело), в task-sync зависимость возвращена в open
# → merge-main отказывает («не закрыта»).
d="$(mk_repo)"
cli "$d" multi on >/dev/null
cli "$d" new "dep" >/dev/null
cli "$d" new "dependent" --depends 1 >/dev/null
( cd "$d" && git checkout -q -b task/0002 && echo x > feature.txt \
    && git add feature.txt && git commit -qm feat && git checkout -q main )
cli "$d" start 1 --owner A >/dev/null
cli "$d" close 1 --owner A >/dev/null             # A: локально done, task-sync done (база=done)
B="$(mk_worktree "$d" B)"
cli "$B" unblock 1 --owner B --force >/dev/null    # B: вернул в open → task-sync = open
# A НЕ синхронизируется: локально всё ещё done (устарело)
out="$(cli "$d" merge-main 2 --base main 2>&1)"
assert_contains "$out" "не закрыта" "R3b merge-main видит open из task-sync → отказ"
rm -rf "$d" "$(dirname "$B")"

# R3c: single-режим — merge-main НЕ создаёт ветку task-sync.
d="$(mk_repo)"
cli "$d" new "solo" >/dev/null
( cd "$d" && git add -A && git commit -qm "task" \
    && git checkout -q -b task/0001 && echo x > f.txt && git add -A && git commit -qm feat \
    && git checkout -q main )
cli "$d" merge-main 1 --base main >/dev/null 2>&1
branches="$( cd "$d" && git branch --list task-sync )"
assert_eq "$branches" "" "R3c single merge-main не создал ветку task-sync"
rm -rf "$d"

echo "== R6: stats sync в multi + честное среднее (Ш6) =="

# R6-avg (single): 2 done по 10k → среднее 10k; archive --done; третья done 10k →
# среднее остаётся 10k (до фикса стало бы 30k/1). Плюс строка «включая архив».
d="$(mk_repo)"
cli "$d" new "a" >/dev/null; cli "$d" start 1 >/dev/null
cli "$d" close 1 --spent "sonnet:10k" >/dev/null
cli "$d" new "b" >/dev/null; cli "$d" start 2 >/dev/null
cli "$d" close 2 --spent "sonnet:10k" >/dev/null
out="$(cli "$d" stats)"
avg="$(printf '%s\n' "$out" | grep 'Среднее')"
assert_contains "$avg" "10,000" "R6-avg до архива: среднее 10,000"
cli "$d" archive --done >/dev/null
cli "$d" new "c" >/dev/null; cli "$d" start 3 >/dev/null
cli "$d" close 3 --spent "sonnet:10k" >/dev/null
out="$(cli "$d" stats)"
avg="$(printf '%s\n' "$out" | grep 'Среднее')"
assert_contains "$avg" "10,000" "R6-avg после archive: среднее осталось 10,000"
assert_not_contains "$avg" "30,000" "R6-avg после archive: среднее НЕ завышено до 30,000"
assert_contains "$avg" "включая архив" "R6-avg строка печати — «включая архив»"
rm -rf "$d"

# R6-multi: close в другом worktree виден в stats без ручного sync.
d="$(mk_repo)"
cli "$d" multi on >/dev/null
cli "$d" new "a" >/dev/null                       # задача 1, open
B="$(mk_worktree "$d" B)"
cli "$B" start 1 --owner B >/dev/null
cli "$B" close 1 --owner B --spent "sonnet:10k" >/dev/null  # done+spent в task-sync
# A: stats БЕЗ ручного sync — должен увидеть чужой close
out="$(cli "$d" stats)"
assert_contains "$out" "10,000" "R6-multi stats видит чужой close+spent без ручного sync"
rm -rf "$d" "$(dirname "$B")"

echo "wave1_0051: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
