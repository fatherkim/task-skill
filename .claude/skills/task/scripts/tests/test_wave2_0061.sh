#!/usr/bin/env bash
# test_wave2_0061.sh — волна 2: Ф5 suggest-files + Ф6 verify --check-wiring.
# Всё в эфемерных git-репо (mktemp); живой трекер agent_tasks/ не трогается.
#
# Vacuous-контроль (протокол в отчёте задачи 0061):
# 1) до-фиксовый код (нет команды suggest-files, нет флагов --check-wiring/
#    --strict в verify) — файл ОБЯЗАН падать (argparse отвергает неизвестные
#    подкоманду/флаги ещё до бизнес-логики). Прогон:
#      TASK_PY=$(mktemp); git show main:.claude/skills/task/scripts/task.py > $TASK_PY
#      TASK_PY=$TASK_PY bash .../tests/test_wave2_0061.sh   # -> красный
# 2) содержательная красная часть: ассерты матчат КОНКРЕТНЫЙ текст предупреждений
#    ("не покрыты files: ...", "⚠ проводка не найдена в диффе: ...",
#    "проводка не заявлена", "проводка подтверждена диффом: ...") и exit-код
#    --strict — саботажная реализация (например, всегда "чисто") тоже красная.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

# insert_wiring <task_md_path> <items> — вставить строку "Проводка: <items>"
# в тело спеки перед "## Задача" (не трогая frontmatter).
insert_wiring() {
  python3 - "$1" "$2" <<'PY'
import sys
path, text = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    content = fh.read()
marker = "## Задача"
idx = content.index(marker)
content = content[:idx] + ("Проводка: %s\n\n" % text) + content[idx:]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(content)
PY
}

# =============================================================================
echo "== Ф5: правка вне files -> файл в выводе suggest-files =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null              # 0001
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo x > src/a.c && echo y > out.txt \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
out="$(cli "$d" suggest-files 1 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф5 вне files: rc 0 (read-only, не блокирует)"
line="$(echo "$out" | grep 'не покрыты files')"
assert_eq "$line" "  не покрыты files: out.txt" "Ф5 вне files: ровно out.txt не покрыт (src/a.c не флагуется)"
assert_contains "$out" "предложение для frontmatter: files: out.txt, src/a.c" "Ф5: готовая строка для frontmatter"
rm -rf "$d"

# =============================================================================
echo "== Ф5: правка внутри каталога из files (src/ покрывает src/a.c) -> не флагуется =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/ >/dev/null                  # 0001, files = каталог
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo x > src/a.c \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
out="$(cli "$d" suggest-files 1 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф5 dir-покрытие: rc 0"
assert_not_contains "$out" "не покрыты files" "Ф5 dir-покрытие: src/a.c покрыт каталогом src/, флага нет"
assert_contains "$out" "все изменения покрыты files" "Ф5 dir-покрытие: явное 'покрыто'"
rm -rf "$d"

# =============================================================================
echo "== Ф5: suggest-files read-only — снапшот трекера до/после идентичен =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null               # 0001
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo x > src/a.c && echo y > out.txt \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
assert_eq "$(git -C "$d" status --porcelain -- tasks)" "" "Ф5 мутация: tasks/ чист ДО suggest-files"
cli "$d" suggest-files 1 >/dev/null 2>&1
assert_eq "$(git -C "$d" status --porcelain -- tasks)" "" "Ф5 мутация: tasks/ чист ПОСЛЕ suggest-files (не пишет ничего)"
rm -rf "$d"

# =============================================================================
echo "== Ф6: Проводка: app_main + дифф без app_main -> warning; --strict -> exit 1 =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null               # 0001
insert_wiring "$(ls "$d"/tasks/0001-*.md)" "app_main"
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo "no_symbol_here" > src/a.c \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
out="$(cli "$d" verify 1 --check-wiring 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф6 warning без --strict: rc 0 (И7)"
assert_contains "$out" "⚠ проводка не найдена в диффе: app_main" "Ф6: предупреждение о непокрытой проводке"
out="$(cli "$d" verify 1 --check-wiring --strict 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф6 --strict: rc != 0"
assert_contains "$out" "⚠ проводка не найдена в диффе: app_main" "Ф6 --strict: то же предупреждение в выводе"
rm -rf "$d"

# =============================================================================
echo "== Ф6: Проводка: app_main + дифф трогает app_main -> чисто =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null               # 0001
insert_wiring "$(ls "$d"/tasks/0001-*.md)" "app_main"
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo "call app_main();" > src/a.c \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
out="$(cli "$d" verify 1 --check-wiring --strict 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф6 проводка найдена: rc 0 даже с --strict"
assert_contains "$out" "проводка подтверждена диффом: app_main" "Ф6: подтверждение проводки в выводе"
assert_not_contains "$out" "не найдена" "Ф6: чисто — предупреждения нет"
rm -rf "$d"

# =============================================================================
echo "== Ф6: спека без секции «Проводка:» -> «проводка не заявлена» (не ошибка) =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat" --files src/a.c >/dev/null               # 0001, без Проводка
( cd "$d" && git add -A && git commit -qm tasks )
( cd "$d" && git checkout -q -b task/0001 main \
    && mkdir -p src && echo x > src/a.c \
    && git add -A && git commit -qm feat \
    && git checkout -q main )
out="$(cli "$d" verify 1 --check-wiring 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф6 нет секции: rc 0"
assert_contains "$out" "проводка не заявлена" "Ф6 нет секции: явный неошибочный вердикт"
out="$(cli "$d" verify 1 --check-wiring --strict 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф6 нет секции + --strict: тоже rc 0 (нет пунктов -> нечего проваливать)"
rm -rf "$d"

# =============================================================================
echo "== Ф6 регрессия: без --check-wiring вывод verify не зависит от тела спеки =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "feat1" --files src/a.c >/dev/null              # 0001, без Проводка
cli "$d" new "feat2" --files src/a.c >/dev/null              # 0002
insert_wiring "$(ls "$d"/tasks/0002-*.md)" "app_main"         # тело отличается
( cd "$d" && git add -A && git commit -qm tasks )
for id in 0001 0002; do
  ( cd "$d" && git checkout -q -b task/$id main \
      && mkdir -p src && echo x > src/a.c \
      && git add -A && git commit -qm feat \
      && git checkout -q main )
done
out1="$(cli "$d" verify 1 2>&1)"; rc1=$?
out2="$(cli "$d" verify 2 2>&1)"; rc2=$?
assert_eq "$rc1" "0" "Ф6 регрессия: verify 1 без флага rc 0"
assert_eq "$rc2" "0" "Ф6 регрессия: verify 2 без флага rc 0"
assert_not_contains "$out1" "проводка" "Ф6 регрессия: verify без --check-wiring не упоминает проводку (0001)"
assert_not_contains "$out2" "проводка" "Ф6 регрессия: verify без --check-wiring не упоминает проводку (0002, хотя в теле она есть)"
norm1="${out1//0001/NNNN}"
norm2="${out2//0002/NNNN}"
assert_eq "$norm1" "$norm2" \
  "Ф6 регрессия: verify без --check-wiring байт-в-байт одинаков независимо от тела спеки (после нормализации id)"
rm -rf "$d"

echo "wave2_0061: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
