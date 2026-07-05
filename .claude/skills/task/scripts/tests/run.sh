#!/usr/bin/env bash
# run.sh — единая точка входа тестов task CLI (unit + integration).
# exit 1 при любом провале. Запуск из любого места:
#   bash .claude/skills/task/scripts/tests/run.sh
# Каркас волны 1: paths_conflict (Ш1) + R1/R2 + verify dir-prefix.
# Ш9-порт multi-сценариев T1-T10 + база multi — test_multi.sh (задача 0056);
# lifecycle-гейты block/unblock (0055) — test_wave1_0055.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export TASK_PY="${TASK_PY:-$(cd "$HERE/.." && pwd)/task.py}"

echo "TASK_PY=$TASK_PY"
[ -f "$TASK_PY" ] || { echo "task.py не найден: $TASK_PY"; exit 1; }

rc=0

echo "=== unit (test_unit.py) ==="
python3 "$HERE/test_unit.py" || rc=1

echo "=== integration (test_regressions.sh) ==="
bash "$HERE/test_regressions.sh" || rc=1

echo "=== integration (test_wave1_0051.sh) ==="
bash "$HERE/test_wave1_0051.sh" || rc=1

echo "=== integration (test_wave1_0053.sh) ==="
bash "$HERE/test_wave1_0053.sh" || rc=1

echo "=== integration (test_wave1_0054.sh) ==="
bash "$HERE/test_wave1_0054.sh" || rc=1

echo "=== integration (test_wave1_0055.sh) ==="
bash "$HERE/test_wave1_0055.sh" || rc=1

echo "=== integration (test_multi.sh) ==="
bash "$HERE/test_multi.sh" || rc=1

echo "=== integration (test_wave2_0058.sh) — Ф1 doctor + Ф2 recovery ==="
bash "$HERE/test_wave2_0058.sh" || rc=1

echo "=== integration (test_wave2_0059.sh) — Ф3 видимость кросс-оркестраторных deps ==="
bash "$HERE/test_wave2_0059.sh" || rc=1

echo "=== integration (test_wave2_0060.sh) — Ф4 merge-main --finalize-integration ==="
bash "$HERE/test_wave2_0060.sh" || rc=1

echo "=== integration (test_wave2_0061.sh) — Ф5 suggest-files + Ф6 verify --check-wiring ==="
bash "$HERE/test_wave2_0061.sh" || rc=1

echo "=== integration (test_wave2_0062.sh) — Ф7 дедуп return + Ф8 debt-cap + Ф10 start-warning ==="
bash "$HERE/test_wave2_0062.sh" || rc=1

echo "=== integration (test_wave2_0063.sh) — Ф13 нормализация depends-id ==="
bash "$HERE/test_wave2_0063.sh" || rc=1

echo "=== integration (test_wave2_0064.sh) — Ф9 версия скилла + Ф11 sync_rules multi-экспорт ==="
bash "$HERE/test_wave2_0064.sh" || rc=1

echo
if [ "$rc" = "0" ]; then echo "РЕЗУЛЬТАТ: ВСЕ ТЕСТЫ ЗЕЛЁНЫЕ"; else echo "РЕЗУЛЬТАТ: ЕСТЬ ПРОВАЛЫ"; fi
exit $rc
