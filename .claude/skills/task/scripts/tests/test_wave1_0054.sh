#!/usr/bin/env bash
# test_wave1_0054.sh — регрессии задачи 0054 (волна 1): Ш7 --resolve подсказка,
# Ш8 гигиена (_git полная команда, cmd_verify через _git), + debt 0052 (stats
# числитель/знаменатель среднего — одно множество closed_tracked).
# Каждый R-регресс и 0052-тест обязаны ПАДАТЬ на коде до фикса (vacuous-контроль).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

echo "== R7: merge-main --resolve — корректная подсказка (Ш7) =="

# R7a (branch-only, без tid): подсказка должна быть исполнимой — ровно один
# --branch, плюс --base <фактический base>. До фикса печатает два --branch.
d="$(mk_repo)"
( cd "$d"
  echo "main1" > f.txt && git add f.txt && git commit -qm "main f" -q
  git checkout -q -b feature
  echo "feature" > f.txt && git commit -aqm "feature f"
  git checkout -q main
  echo "main2" > f.txt && git commit -aqm "main f2"
)
out="$(cli "$d" merge-main --branch feature --resolve 2>&1)"
nbranch="$(printf '%s\n' "$out" | grep -o -- '--branch' | wc -l | tr -d ' ')"
assert_eq "$nbranch" "1" "R7a ровно один --branch в подсказке (branch-only)"
assert_contains "$out" "--base main" "R7a подсказка содержит --base main"
assert_contains "$out" "merge-main --branch _merge/feature --base main" "R7a подсказка исполнима как есть"
wt="$(printf '%s\n' "$out" | grep 'Площадка резолва' | sed -E 's/^Площадка резолва: ([^ ]+).*/\1/')"
rm -rf "$d" "$wt"

# R7b (с tid): прежняя корректная форма не сломана.
d="$(mk_repo)"
( cd "$d"
  echo "main1" > f.txt && git add f.txt && git commit -qm "main f" -q
  git checkout -q -b task/0001
  echo "task" > f.txt && git commit -aqm "task f"
  git checkout -q main
  echo "main2" > f.txt && git commit -aqm "main f2"
)
out="$(cli "$d" merge-main 1 --resolve 2>&1)"
nbranch="$(printf '%s\n' "$out" | grep -o -- '--branch' | wc -l | tr -d ' ')"
assert_eq "$nbranch" "1" "R7b ровно один --branch в подсказке (с tid)"
assert_contains "$out" "merge-main 1 --branch _merge/0001" "R7b прежняя форма подсказки с tid"
wt="$(printf '%s\n' "$out" | grep 'Площадка резолва' | sed -E 's/^Площадка резолва: ([^ ]+).*/\1/')"
rm -rf "$d" "$wt"

echo "== Ш8: cmd_verify через _git; _git при ошибке печатает полную команду + stderr =="

# cmd_verify больше не использует subprocess.check_output напрямую — ошибка идёт
# через _git, сообщение содержит полную команду ("git " + все аргументы) + stderr.
d="$(mk_repo)"
cli "$d" new "t" >/dev/null
( cd "$d" && git add -A && git commit -qm t \
    && git checkout -q -b task/0001 && echo x > ff.txt && git add -A && git commit -qm f \
    && git checkout -q main )
out="$(cli "$d" verify 1 --base no-such-ref-xyz 2>&1)"; rc=$?
if [ "$rc" != "0" ]; then _pass; else _fail "Ш8 verify с битым --base должен упасть, rc=$rc"; fi
assert_contains "$out" "git diff --name-only no-such-ref-xyz...task/0001" "Ш8 _git печатает полную команду"
rm -rf "$d"

echo "== R8: sync_rules.py — пустой core-блок -> exit 1 (Ш8) =="

# Ephemeral: копия sync_rules.py + фейковые SKILL.md рядом (НЕ живой репозиторий).
# Начиная с Ф11 (задача 0064) sync_rules.py читает ДВА источника (task/SKILL.md
# + сосед task-multi/SKILL.md на два уровня выше scripts/) — фикстура повторяет
# реальную раскладку .claude/skills/{task,task-multi}/.
base="$(mktemp -d)"
work="$base/task"
mkdir -p "$work/scripts" "$base/task-multi"
cp "$HERE/../sync_rules.py" "$work/scripts/sync_rules.py"
cat > "$work/SKILL.md" <<'EOF'
# fake skill
<!-- core:start -->
<!-- core:end -->
EOF
cat > "$base/task-multi/SKILL.md" <<'EOF'
# fake multi skill
<!-- core:start -->
Пример правила ядра multi.
<!-- core:end -->
EOF
target="$(mktemp -d)"
out="$(python3 "$work/scripts/sync_rules.py" --repo "$target" 2>&1)"; rc=$?
if [ "$rc" != "0" ]; then _pass; else _fail "R8 пустой core-блок должен упасть, rc=$rc"; fi
assert_contains "$out" "core-блок пуст" "R8 внятное сообщение про пустой core-блок"
[ -f "$target/AGENTS.md" ] && _fail "R8 AGENTS.md не должен создаваться при пустом core" || _pass
rm -rf "$base" "$target"

# R8-ok: нормальный core-блок в обоих ephemeral SKILL.md — работает как раньше.
base2="$(mktemp -d)"
work2="$base2/task"
mkdir -p "$work2/scripts" "$base2/task-multi"
cp "$HERE/../sync_rules.py" "$work2/scripts/sync_rules.py"
cat > "$work2/SKILL.md" <<'EOF'
# fake skill
<!-- core:start -->
Пример правила ядра.
<!-- core:end -->
EOF
cat > "$base2/task-multi/SKILL.md" <<'EOF'
# fake multi skill
<!-- core:start -->
Пример правила ядра multi.
<!-- core:end -->
EOF
target2="$(mktemp -d)"
out2="$(python3 "$work2/scripts/sync_rules.py" --repo "$target2" 2>&1)"; rc2=$?
if [ "$rc2" = "0" ]; then _pass; else _fail "R8-ok нормальный core -> rc=$rc2"; fi
assert_contains "$out2" "Обновлено:" "R8-ok печатает Обновлено"
[ -f "$target2/AGENTS.md" ] && _pass || _fail "R8-ok AGENTS.md создан в ephemeral --repo"
rm -rf "$base2" "$target2"

echo "== 0052: stats — числитель среднего по closed_tracked, не по всем spent =="

d="$(mk_repo)"
cli "$d" new "a" >/dev/null; cli "$d" start 1 >/dev/null
cli "$d" close 1 --spent "sonnet:10k" >/dev/null
cli "$d" new "b" >/dev/null; cli "$d" start 2 >/dev/null
cli "$d" close 2 --spent "sonnet:10k" >/dev/null
out="$(cli "$d" stats)"
total_line="$(printf '%s\n' "$out" | grep 'итого')"
avg="$(printf '%s\n' "$out" | grep 'Среднее')"
assert_contains "$total_line" "20,000" "0052 baseline: Расход по моделям итого 20,000"
assert_contains "$avg" "10,000" "0052 baseline: 2 done по 10k -> среднее 10,000"

# Переоткрытие: done+spent -> start (spent НЕ очищается, вне скоупа lifecycle-правки).
cli "$d" start 1 >/dev/null
out="$(cli "$d" stats)"
total_line="$(printf '%s\n' "$out" | grep 'итого')"
avg="$(printf '%s\n' "$out" | grep 'Среднее')"
vne="$(printf '%s\n' "$out" | grep 'вне закрытых')"
assert_contains "$total_line" "20,000" "0052 после переоткрытия: Расход по моделям НЕ изменился (20,000)"
assert_contains "$avg" "10,000" "0052 после переоткрытия: среднее осталось 10,000 (по закрытым)"
assert_not_contains "$avg" "20,000" "0052 после переоткрытия: среднее НЕ завышено до 20,000/1"
assert_contains "$vne" "10,000" "0052 строка «учтено вне закрытых» показывает spent неучтённой задачи"
rm -rf "$d"

echo "wave1_0054: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
