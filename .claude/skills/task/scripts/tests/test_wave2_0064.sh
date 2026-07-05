#!/usr/bin/env bash
# test_wave2_0064.sh — волна 2: Ф9 версия скилла + Ф11 sync_rules multi-экспорт.
# Всё в эфемерных git-репо/директориях (mktemp); живой трекер agent_tasks/ и
# живой AGENTS.md/.cursor/rules НЕ трогаются — тесты пишут в --repo <ephemeral>.
#
# Vacuous-контроль (протокол в отчёте задачи 0064):
#   Ф9: до фикса doctor не печатал "CLI версия" и не ловил рассинхрон копии с
#   каноником — секция 12 (lint) не содержала записи про версию. Прогон
#   регресса на до-фиксовом $TASK_PY (см. RUN_PREFIX в отчёте) красный на T1/T2.
#   Ф11: до фикса sync_rules.py читал только один источник (task/SKILL.md) —
#   не писал блок task-multi:start/end в AGENTS.md и не создавал task-multi.mdc;
#   T3/T4/T5/T6 красные на до-фиксовом sync_rules.py.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

echo "== Ф9: doctor печатает версию CLI =="

# T1: версия печатается всегда (даже без каноника рядом).
d="$(mk_repo)"
out="$(cli "$d" doctor 2>&1)"
assert_contains "$out" "CLI версия: 1.2.0" "T1 doctor печатает версию CLI"
rm -rf "$d"

echo "== Ф9: doctor ловит рассинхрон копии tasks/_cli.py с каноником =="

# T2a: каноник рядом (.claude/skills/task/scripts/task.py) и совпадает с копией
# -> проблем 0 (копия tasks/_cli.py — байт-в-байт копия task.py, init её и делает).
d="$(mk_repo)"
mkdir -p "$d/.claude/skills/task/scripts"
cp "$TASK_PY" "$d/.claude/skills/task/scripts/task.py"
( cd "$d" && git add -A && git commit -qm "add canon" )
out="$(cli "$d" doctor 2>&1)"
assert_not_contains "$out" "разошлась с каноником" "T2a копия=каноник -> без рассинхрона"
assert_contains "$out" "0 проблем" "T2a 0 проблем при совпадающем канонике"
rm -rf "$d"

# T2b: искусственно меняем установленную копию (tasks/_cli.py) -> doctor обязан
# поймать рассинхрон и подсказать "обнови tasks/_cli.py из каноника".
d="$(mk_repo)"
mkdir -p "$d/.claude/skills/task/scripts"
cp "$TASK_PY" "$d/.claude/skills/task/scripts/task.py"
( cd "$d" && git add -A && git commit -qm "add canon" )
echo "# искусственный дрейф копии" >> "$d/tasks/_cli.py"
out="$(cli "$d" doctor 2>&1)"
assert_contains "$out" "разошлась с каноником" "T2b рассинхрон копии/каноника пойман"
assert_contains "$out" "обнови tasks/_cli.py из каноника" "T2b подсказка про обновление"
assert_not_contains "$out" "0 проблем" "T2b проблема учтена в счётчике"
rm -rf "$d"

# T2c: каноника рядом нет (чужой репо после init) -> сверка молча пропускается,
# НЕ ошибка (mk_repo по умолчанию не кладёт .claude/skills/task рядом).
d="$(mk_repo)"
out="$(cli "$d" doctor 2>&1)"
assert_not_contains "$out" "разошлась с каноником" "T2c нет каноника -> без ложного рассинхрона"
assert_contains "$out" "0 проблем" "T2c нет каноника -> 0 проблем"
rm -rf "$d"

echo "== Ф9: version: во frontmatter обоих SKILL.md; _SCHEMA не тронута =="

assert_contains "$(cat "$HERE/../../SKILL.md")" $'\nversion: 1.2.0\n' "T5 task/SKILL.md несёт version: 1.2.0"
assert_contains "$(cat "$HERE/../../../task-multi/SKILL.md")" $'\nversion: 1.2.0\n' "T5 task-multi/SKILL.md несёт version: 1.2.0"
# grep-ассерт: SCHEMA_VERSION не менялся этой задачей (значение 2, как в волне 1/2 до 0064).
schema_line="$(grep -m1 '^SCHEMA_VERSION = ' "$TASK_PY")"
assert_eq "$schema_line" "SCHEMA_VERSION = 2" "T5 _SCHEMA-константа (SCHEMA_VERSION) не изменена Ф9"

echo "== Ф11: sync_rules.py — оба блока в AGENTS.md, task-multi.mdc создан =="

# T3: прогон реального sync_rules.py + реальных SKILL.md (после правок этой
# задачи) в ephemeral --repo — живой AGENTS.md/.cursor репозитория не трогаем.
target="$(mktemp -d)"
out3="$(python3 "$HERE/../sync_rules.py" --repo "$target" 2>&1)"; rc3=$?
assert_eq "$rc3" "0" "T3 sync_rules.py на реальных SKILL.md -> rc=0"
assert_contains "$out3" "Создано:   $target/.cursor/rules/task-multi.mdc" "T3 создаёт task-multi.mdc"
[ -f "$target/.cursor/rules/task-multi.mdc" ] && _pass || _fail "T3 файл task-multi.mdc существует"
agents_txt="$(cat "$target/AGENTS.md" 2>/dev/null || true)"
assert_contains "$agents_txt" "<!-- task:start -->" "T3 AGENTS.md содержит task:start"
assert_contains "$agents_txt" "<!-- task:end -->" "T3 AGENTS.md содержит task:end"
assert_contains "$agents_txt" "<!-- task-multi:start -->" "T3 AGENTS.md содержит task-multi:start"
assert_contains "$agents_txt" "<!-- task-multi:end -->" "T3 AGENTS.md содержит task-multi:end"
assert_contains "$agents_txt" "multi-режим требует git worktree + POSIX flock" "T3 преамбула Ф11.2 дословно в AGENTS.md"
multi_mdc="$(cat "$target/.cursor/rules/task-multi.mdc")"
assert_contains "$multi_mdc" "## Модель" "T3 task-multi.mdc несёт core-контент (## Модель)"
assert_not_contains "$multi_mdc" "Serena" "T3 task-multi.mdc НЕ несёт Claude-специфику (Serena)"
assert_not_contains "$multi_mdc" "спавна субагентов" "T3 task-multi.mdc НЕ несёт Claude-специфику (спавн субагентов)"

echo "== Ф11: повторный прогон sync_rules.py — идемпотентен байт-в-байт =="

# T4: второй прогон в тот же --repo не меняет ни один из выходных файлов.
cp "$target/AGENTS.md" "$target/AGENTS.md.snap"
cp "$target/.cursor/rules/task.mdc" "$target/task.mdc.snap"
cp "$target/.cursor/rules/task-multi.mdc" "$target/task-multi.mdc.snap"
python3 "$HERE/../sync_rules.py" --repo "$target" >/dev/null 2>&1
if diff -q "$target/AGENTS.md.snap" "$target/AGENTS.md" >/dev/null; then _pass; else _fail "T4 AGENTS.md идемпотентен байт-в-байт"; fi
if diff -q "$target/task.mdc.snap" "$target/.cursor/rules/task.mdc" >/dev/null; then _pass; else _fail "T4 task.mdc идемпотентен байт-в-байт"; fi
if diff -q "$target/task-multi.mdc.snap" "$target/.cursor/rules/task-multi.mdc" >/dev/null; then _pass; else _fail "T4 task-multi.mdc идемпотентен байт-в-байт"; fi
rm -rf "$target"

echo "== Ф11.3: guard пустого core — общий (Ш8.3), проверен и для ВТОРОГО источника =="

# T6: task/SKILL.md — нормальный core, task-multi/SKILL.md — пустой core ->
# отказ ДО записи чего-либо (тот же guard, что и в волне 1, second source).
base="$(mktemp -d)"
work="$base/task"
mkdir -p "$work/scripts" "$base/task-multi"
cp "$HERE/../sync_rules.py" "$work/scripts/sync_rules.py"
cat > "$work/SKILL.md" <<'EOF'
# fake skill
<!-- core:start -->
Пример правила ядра (основной источник, непустой).
<!-- core:end -->
EOF
cat > "$base/task-multi/SKILL.md" <<'EOF'
# fake multi skill
<!-- core:start -->
<!-- core:end -->
EOF
target6="$(mktemp -d)"
out6="$(python3 "$work/scripts/sync_rules.py" --repo "$target6" 2>&1)"; rc6=$?
if [ "$rc6" != "0" ]; then _pass; else _fail "T6 пустой core во ВТОРОМ источнике должен упасть, rc=$rc6"; fi
assert_contains "$out6" "core-блок пуст" "T6 внятное сообщение про пустой core (task-multi/SKILL.md)"
[ -f "$target6/AGENTS.md" ] && _fail "T6 AGENTS.md не должен создаваться при пустом core второго источника" || _pass
rm -rf "$base" "$target6"

echo "wave2_0064: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
