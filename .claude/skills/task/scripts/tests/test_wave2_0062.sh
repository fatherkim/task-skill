#!/usr/bin/env bash
# test_wave2_0062.sh — волна 2: Ф7 дедуп-предупреждение в return + Ф8 debt-cap
# (debt_from + cap ≥3) + Ф10 start предупреждает о грязном tasks/.
# Всё в эфемерных git-репо (mktemp); живой трекер agent_tasks/ не трогается.
#
# Vacuous-контроль (протокол в отчёте задачи 0062):
# 1) Ф8 использует новый флаг `--debt-from` — на до-фиксовом коде argparse
#    отвергает неизвестный флаг ещё до бизнес-логики (жёсткий крэш).
# 2) Ф7/Ф10 не добавляют новых флагов/подкоманд (return/start уже существуют) —
#    до-фиксовый код НЕ падает, а просто не печатает новый текст; красная часть
#    там — assert_contains по КОНКРЕТНОМУ тексту предупреждений
#    ("ДУБЛЬ ФИДБЕКА", "незакоммиченные изменения в трекере") и по frontmatter
#    (debt_from:, last_return_sig:) — сфабрикованная "всегда чисто"/"никогда не
#    предупреждать" реализация тоже красная.
# 3) Долг 0066: Ф10 мерил git status ПОСЛЕ _set_status, и собственная мутация
#    start (перезапись файла задачи + _INDEX.md) всегда выглядела как "грязь" —
#    первый реальный start на чистом трекере ложно предупреждал. Красная часть
#    для этого долга — assert_not_contains "незакоммиченные изменения в
#    трекере" в сценарии "чистый закоммиченный трекер -> первый start"; на
#    до-фиксовом коде (git show main:...) этот assert ПАДАЕТ (предупреждение
#    печатается, хотя перед start трекер был чист).
# Прогон на до-фиксовом коде:
#   TASK_PY=$(mktemp); git show main:.claude/skills/task/scripts/task.py > $TASK_PY
#   TASK_PY=$TASK_PY bash .../tests/test_wave2_0062.sh   # -> красный
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

# =============================================================================
echo "== Ф7: два return с одинаковым reason, дифф ветки не менялся -> 2-й с ДУБЛЬ =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null                # 0001
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo x > src/a.c \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
cli "$d" start 1 >/dev/null 2>&1
out1="$(cli "$d" return 1 --reason "почини валидацию" 2>&1)"; rc1=$?
assert_eq "$rc1" "0" "Ф7 первый return: rc 0"
assert_not_contains "$out1" "ДУБЛЬ ФИДБЕКА" "Ф7 первый return: нет предыдущей сигнатуры -> без предупреждения"
assert_contains "$(cat "$d"/tasks/0001-*.md)" "last_return_sig:" "Ф7: last_return_sig записан во frontmatter"
out2="$(cli "$d" return 1 --reason "почини валидацию" 2>&1)"; rc2=$?
assert_eq "$rc2" "0" "Ф7 2-й return с тем же reason: возврат ВСЕ РАВНО выполняется (И7, не блок)"
assert_contains "$out2" "⚠ ДУБЛЬ ФИДБЕКА: возврат повторяет предыдущий (reason и дифф не изменились)" \
  "Ф7 2-й return: точный текст предупреждения о дубле"
assert_eq "$(grep -m1 '^returns:' "$d"/tasks/0001-*.md | awk '{print $2}')" "2" "Ф7: returns инкрементится даже при дубле"
rm -rf "$d"

# =============================================================================
echo "== Ф7: смена reason -> без предупреждения =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null                # 0001
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo x > src/a.c \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
cli "$d" start 1 >/dev/null 2>&1
cli "$d" return 1 --reason "причина A" >/dev/null 2>&1
out="$(cli "$d" return 1 --reason "причина Б, другая формулировка" 2>&1)"
assert_not_contains "$out" "ДУБЛЬ ФИДБЕКА" "Ф7 смена reason: без предупреждения"
rm -rf "$d"

# =============================================================================
echo "== Ф7: тот же reason, но новый коммит в ветке между возвратами -> без предупреждения =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null                # 0001
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo x > src/a.c \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
cli "$d" start 1 >/dev/null 2>&1
cli "$d" return 1 --reason "та же причина" >/dev/null 2>&1
( cd "$d" && git checkout -q task/0001 \
    && echo y >> src/a.c && git add -A && git commit -qm "правка" \
    && git checkout -q main )
out="$(cli "$d" return 1 --reason "та же причина" 2>&1)"
assert_not_contains "$out" "ДУБЛЬ ФИДБЕКА" "Ф7 новый коммит в ветке: дифф изменился -> без предупреждения"
rm -rf "$d"

# =============================================================================
echo "== Ф7: return без существующей ветки task/NNNN -> не крэшится =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" >/dev/null                                 # 0001, ветки task/0001 нет
cli "$d" start 1 >/dev/null 2>&1
out1="$(cli "$d" return 1 --reason "x" 2>&1)"; rc1=$?
assert_eq "$rc1" "0" "Ф7 без ветки: rc 0, не крэш"
out2="$(cli "$d" return 1 --reason "x" 2>&1)"; rc2=$?
assert_eq "$rc2" "0" "Ф7 без ветки, 2-й return тем же reason: rc 0"
assert_contains "$out2" "ДУБЛЬ ФИДБЕКА" "Ф7 без ветки: сигнатура стабильна (пустой diff-компонент) -> дубль ловится"
rm -rf "$d"

# =============================================================================
echo "== Ф8: 4-я debt-задача с одним debt_from -> предупреждение; частот. debt_from во frontmatter =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "исходная задача" >/dev/null                      # 0001 — родитель
out1="$(cli "$d" new "debt 1" --debt-from 1 2>&1)"             # 0002
out2="$(cli "$d" new "debt 2" --debt-from 1 2>&1)"             # 0003
out3="$(cli "$d" new "debt 3" --debt-from 1 2>&1)"             # 0004
out4="$(cli "$d" new "debt 4" --debt-from 1 2>&1)"             # 0005 — 4-я
assert_not_contains "$out1" "признак системной проблемы" "Ф8 1-я debt-задача: без предупреждения"
assert_not_contains "$out2" "признак системной проблемы" "Ф8 2-я debt-задача: без предупреждения"
assert_not_contains "$out3" "признак системной проблемы" "Ф8 3-я debt-задача: без предупреждения"
assert_contains "$out4" "⚠ 4-я debt-задача от 0001 — признак системной проблемы" "Ф8 4-я debt-задача: точный текст предупреждения"
assert_eq "$(grep -m1 '^debt_from:' "$d"/tasks/0002-*.md | awk '{print $2}')" "0001" "Ф8: debt_from нормализован в 0001 (был передан '1')"
rm -rf "$d"

# =============================================================================
echo "== Ф8: doctor показывает счётчик debt по родителям =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "исходная задача" >/dev/null                      # 0001
cli "$d" new "debt 1" --debt-from 1 >/dev/null                 # 0002
cli "$d" new "debt 2" --debt-from 0001 >/dev/null              # 0003 (уже padded)
out="$(cli "$d" doctor 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф8 doctor: rc 0"
assert_contains "$out" "Debt по родителям: 0001: 2" "Ф8 doctor: счётчик debt по родителю 0001"
rm -rf "$d"

# =============================================================================
echo "== Легаси: frontmatter без debt_from/last_return_sig парсится как раньше =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "старая задача" --files src/a.c >/dev/null        # 0001
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo x > src/a.c \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
# frontmatter 0001 сейчас уже без debt_from/last_return_sig (поля опциональны,
# как и было бы у файла, созданного до-фиксовым CLI) — используем как есть.
assert_not_contains "$(cat "$d"/tasks/0001-*.md)" "debt_from:" "Легаси: debt_from отсутствует, если не задавался"
assert_not_contains "$(cat "$d"/tasks/0001-*.md)" "last_return_sig:" "Легаси: last_return_sig отсутствует до первого return"
out_view="$(cli "$d" view 1 2>&1)"; rc_view=$?
assert_eq "$rc_view" "0" "Легаси: view легаси-задачи не крэшится"
out_doctor="$(cli "$d" doctor 2>&1)"; rc_doctor=$?
assert_eq "$rc_doctor" "0" "Легаси: doctor не крэшится без debt_from ни у одной задачи"
assert_not_contains "$out_doctor" "Debt по родителям" "Легаси: без debt_from нигде -> нет строки счётчика"
# первый return на легаси-задаче (last_return_sig отсутствует) не крэшится и не дублирует
cli "$d" start 1 >/dev/null 2>&1
out_ret="$(cli "$d" return 1 --reason "легаси-реплей" 2>&1)"; rc_ret=$?
assert_eq "$rc_ret" "0" "Легаси: первый return на файле без last_return_sig — rc 0, не крэш"
assert_not_contains "$out_ret" "ДУБЛЬ ФИДБЕКА" "Легаси: первый return без предыдущей сигнатуры — без предупреждения"
rm -rf "$d"

# =============================================================================
echo "== Ф10: start при незакоммиченном tasks/ (single) -> предупреждение =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null                 # 0001 — не закоммичено
out="$(cli "$d" start 1 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф10 start: rc 0 (warning-only, И7)"
assert_contains "$out" "⚠ незакоммиченные изменения в трекере: worktree исполнителя их НЕ увидит. Закоммить tasks/ до диспатча." \
  "Ф10: точный текст предупреждения о грязном tasks/"
rm -rf "$d"

# =============================================================================
echo "== Ф10 (0066): чистый закоммиченный трекер -> первый реальный start БЕЗ предупреждения =="
# =============================================================================
# vacuous-pass контроль (0066): на до-фиксовом коде Ф10 меряет git status ПОСЛЕ
# _set_status, а сам start переписывает файл задачи + _INDEX.md -> этот assert
# обязан быть КРАСНЫМ на до-фиксовом task.py (см. протокол прогона в шапке файла).
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null                 # 0001
( cd "$d" && git add -A && git commit -qm tasks )
assert_eq "$(git -C "$d" status --porcelain -- tasks)" "" "Ф10 (0066): tasks/ чист до start (sanity)"
out="$(cli "$d" start 1 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф10 (0066) первый start на чистом трекере: rc 0"
assert_not_contains "$out" "незакоммиченные изменения в трекере" \
  "Ф10 (0066): первый реальный start на чистом закоммиченном трекере молчит (собственная мутация start не в счёт)"
rm -rf "$d"

# =============================================================================
echo "== Ф10 (0066): грязь в трекере ДО start (чужая незакоммиченная спека) -> предупреждение =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null                 # 0001
( cd "$d" && git add -A && git commit -qm tasks )
cli "$d" new "other" --files src/b.c >/dev/null                 # 0002 — чужая незакоммиченная спека
out="$(cli "$d" start 1 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф10 (0066) start при чужой грязи ДО start: rc 0 (warning-only, И7)"
assert_contains "$out" "⚠ незакоммиченные изменения в трекере: worktree исполнителя их НЕ увидит. Закоммить tasks/ до диспатча." \
  "Ф10 (0066): грязь, существовавшая ДО start (чужая незакоммиченная спека), ловится"
rm -rf "$d"

# =============================================================================
echo "== Ф10: в multi предупреждение НЕ печатается, даже если tasks/ грязный =="
# =============================================================================
R="$(mk_repo)"
cli "$R" multi on >/dev/null 2>&1
cli "$R" new "job" >/dev/null                                  # 0001
( cd "$R" && git add -A && git commit -qm tasks )
B="$(mk_worktree "$R" B)"
out="$(cli "$B" start 1 --owner B 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф10 multi start: rc 0"
assert_not_contains "$out" "незакоммиченные изменения в трекере" "Ф10 multi: предупреждение не печатается (мутации коммитятся в task-sync)"
rm -rf "$R" "$B" "$(dirname "$B")"

echo "wave2_0062: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
