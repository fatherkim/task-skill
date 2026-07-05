#!/usr/bin/env bash
# test_wave2_0060.sh — волна 2: Ф4 merge-main --finalize-integration.
# Всё в эфемерных git-репо (mktemp); живой трекер и ref main живого репо не трогаются.
#
# Vacuous-контроль (протокол в отчёте задачи 0060):
# 1) до-фиксовый код (нет флага в argparse) — файл ОБЯЗАН падать:
#      TASK_PY=$(mktemp); git show main:.claude/skills/task/scripts/task.py > $TASK_PY
#      TASK_PY=$TASK_PY bash .../tests/test_wave2_0060.sh   # -> красный
# 2) содержательная красная часть — ассерты СОСТОЯНИЯ refs: саботажная копия
#    task.py (finalize печатает, но не двигает main / не удаляет ветку) тоже
#    красная — тесты сверяют хеши main/integration, а не только stdout.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

sha() { git -C "$1" rev-parse "$2" 2>/dev/null; }

# =============================================================================
echo "== Ф4: полный цикл — грязный main -> fallback в integration -> main очищен -> finalize =="
# =============================================================================
d="$(mk_repo)"
cli "$d" multi on >/dev/null 2>&1
cli "$d" new "feat" --files src/f.c >/dev/null            # 0001
( cd "$d" && echo base > base.txt && git add -A && git commit -qm base )
( cd "$d" && git checkout -q -b task/0001 main \
    && echo f > f.txt && git add f.txt && git commit -qm feat \
    && git checkout -q main )
cli "$d" start 1 --owner O >/dev/null 2>&1
cli "$d" close 1 --owner O >/dev/null 2>&1
( cd "$d" && echo dirty >> base.txt )                     # грязное main-дерево
out="$(cli "$d" merge-main 1 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф4 цикл: merge-main при грязном main -> rc 0 (fallback)"
assert_contains "$out" "влито в integration" "Ф4 цикл: fallback-сообщение"
git -C "$d" rev-parse --verify -q refs/heads/integration >/dev/null \
  && _pass || _fail "Ф4 цикл: ветка integration создана fallback'ом"
( cd "$d" && git merge-base --is-ancestor task/0001 integration ) \
  && _pass || _fail "Ф4 цикл: task/0001 влита в integration"
( cd "$d" && git merge-base --is-ancestor task/0001 main ) \
  && _fail "Ф4 цикл: main НЕ должен был двинуться при fallback" || _pass

# main очищен: сброс и base.txt, и tracked-мутаций трекера (канон живёт в task-sync)
( cd "$d" && git checkout -q -- . )
pre_int="$(sha "$d" integration)"
pre_main="$(sha "$d" main)"
behind="$(git -C "$d" rev-list --count main..integration)"
out="$(cli "$d" merge-main --finalize-integration 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф4 finalize: rc 0"
assert_eq "$(sha "$d" main)" "$pre_int" "Ф4 finalize: main == бывшая integration (хеш)"
git -C "$d" rev-parse --verify -q refs/heads/integration >/dev/null \
  && _fail "Ф4 finalize: ветка integration должна быть удалена" || _pass
assert_eq "$(git -C "$d" branch --show-current)" "main" \
  "Ф4 finalize: checkout не было — HEAD остался на main"
assert_eq "$(git -C "$d" status --porcelain -uno)" "" "Ф4 finalize: рабочее дерево чистое"
[ -f "$d/f.txt" ] && _pass || _fail "Ф4 finalize: ff довёл дерево main до integration (f.txt)"
assert_contains "$out" "$behind коммит(ов) из integration" "Ф4 finalize: rev-list --count в печати"
assert_not_contains "$out" "git push" "Ф4 finalize: без remote нет напоминания про push"
# идемпотентность отказа: повторный finalize — ветки уже нет
out="$(cli "$d" merge-main --finalize-integration 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф4 повторный finalize: rc != 0"
assert_contains "$out" "ветки integration нет" "Ф4 повторный finalize: внятный отказ"
rm -rf "$d"

# =============================================================================
echo "== Ф4: main нигде не checked out -> update-ref без checkout; --keep; remote-напоминание =="
# =============================================================================
d="$(mk_repo)"
cli "$d" multi on >/dev/null 2>&1
( cd "$d" && git remote add origin /nonexistent-remote.git )
( cd "$d" && git checkout -q -b intwork main \
    && echo z > z.txt && git add z.txt && git commit -qm z \
    && git branch integration intwork \
    && git checkout -q -b parking main )                  # main не checked out нигде
pre_int="$(sha "$d" integration)"
out="$(cli "$d" merge-main --finalize-integration --keep 2>&1)"; rc=$?
assert_eq "$rc" "0" "Ф4 --keep: rc 0"
assert_eq "$(sha "$d" main)" "$pre_int" "Ф4 --keep: main ff-нут update-ref'ом (хеш)"
assert_eq "$(sha "$d" integration)" "$pre_int" "Ф4 --keep: ветка integration осталась"
assert_contains "$out" "без checkout" "Ф4 --keep: путь update-ref (без checkout)"
assert_contains "$out" "оставлена (--keep)" "Ф4 --keep: печать про сохранение ветки"
assert_contains "$out" "git push" "Ф4 remote: напоминание про push"
[ -f "$d/z.txt" ] && _fail "Ф4 --keep: рабочее дерево (parking) нетронуто — z.txt не появился" || _pass
assert_eq "$(git -C "$d" status --porcelain -uno)" "" "Ф4 --keep: рабочее дерево чистое"
assert_eq "$(git -C "$d" branch --show-current)" "parking" "Ф4 --keep: HEAD остался на parking"
rm -rf "$d"

# =============================================================================
echo "== Ф4 гейт 1: вне multi — отказ =="
# =============================================================================
d="$(mk_repo)"
( cd "$d" && git branch integration main )
pre_main="$(sha "$d" main)"
out="$(cli "$d" merge-main --finalize-integration 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф4 вне multi: rc != 0"
assert_contains "$out" "только в multi-режиме" "Ф4 вне multi: внятный отказ"
assert_eq "$(sha "$d" main)" "$pre_main" "Ф4 вне multi: main не тронут"
assert_eq "$(sha "$d" integration)" "$pre_main" "Ф4 вне multi: integration не тронута"
rm -rf "$d"

# =============================================================================
echo "== Ф4 гейт 2: нет ветки integration — отказ =="
# =============================================================================
d="$(mk_repo)"
cli "$d" multi on >/dev/null 2>&1
pre_main="$(sha "$d" main)"
out="$(cli "$d" merge-main --finalize-integration 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф4 нет ветки: rc != 0"
assert_contains "$out" "ветки integration нет" "Ф4 нет ветки: внятный отказ"
assert_eq "$(sha "$d" main)" "$pre_main" "Ф4 нет ветки: main не тронут"
rm -rf "$d"

# =============================================================================
echo "== Ф4 гейт 4: diverged main — отказ с рецептом, refs не изменены =="
# =============================================================================
d="$(mk_repo)"
cli "$d" multi on >/dev/null 2>&1
( cd "$d" && git checkout -q -b intwork main \
    && echo z > z.txt && git add z.txt && git commit -qm z \
    && git branch integration intwork \
    && git checkout -q main \
    && echo m > m.txt && git add m.txt && git commit -qm m )   # main разошёлся
pre_main="$(sha "$d" main)"
pre_int="$(sha "$d" integration)"
out="$(cli "$d" merge-main --finalize-integration 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф4 diverged: rc != 0"
assert_contains "$out" "main НЕ ancestor integration" "Ф4 diverged: причина в отказе"
assert_contains "$out" "integration отстала от main: merge-main любой задачи подтянет, либо разбор руками." \
  "Ф4 diverged: рецепт по спеке"
assert_contains "$out" "Рецепт: RECOVERY.md#integration" "Ф4 diverged: хвост-якорь RECOVERY"
assert_eq "$(sha "$d" main)" "$pre_main" "Ф4 diverged: main не изменён (хеш до/после)"
assert_eq "$(sha "$d" integration)" "$pre_int" "Ф4 diverged: integration не изменена (хеш до/после)"
git -C "$d" rev-parse --verify -q refs/heads/integration >/dev/null \
  && _pass || _fail "Ф4 diverged: ветка integration не удалена"
rm -rf "$d"

# =============================================================================
echo "== Ф4 гейт 4 (вариант): integration строго отстала (ancestor main) — тот же отказ =="
# =============================================================================
d="$(mk_repo)"
cli "$d" multi on >/dev/null 2>&1
( cd "$d" && git branch integration main \
    && echo m > m.txt && git add m.txt && git commit -qm m )   # main ушёл вперёд
pre_main="$(sha "$d" main)"
pre_int="$(sha "$d" integration)"
out="$(cli "$d" merge-main --finalize-integration 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф4 stale: rc != 0"
assert_contains "$out" "Рецепт: RECOVERY.md#integration" "Ф4 stale: якорь RECOVERY"
assert_eq "$(sha "$d" main)" "$pre_main" "Ф4 stale: main не изменён"
assert_eq "$(sha "$d" integration)" "$pre_int" "Ф4 stale: integration не изменена"
rm -rf "$d"

# =============================================================================
echo "== Ф4 гейт 3: main checked out и дерево грязное — отказ, refs не изменены =="
# =============================================================================
d="$(mk_repo)"
cli "$d" multi on >/dev/null 2>&1
( cd "$d" && echo base > base.txt && git add -A && git commit -qm base )
( cd "$d" && git checkout -q -b intwork main \
    && echo z > z.txt && git add z.txt && git commit -qm z \
    && git checkout -q main && git branch integration intwork )
( cd "$d" && echo dirty >> base.txt )                     # tracked-файл грязный
pre_main="$(sha "$d" main)"
pre_int="$(sha "$d" integration)"
out="$(cli "$d" merge-main --finalize-integration 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф4 грязный main: rc != 0"
assert_contains "$out" "ГРЯЗНОЕ" "Ф4 грязный main: причина в отказе"
assert_contains "$out" "Рецепт: RECOVERY.md#dirty-main" "Ф4 грязный main: якорь dirty-main"
assert_eq "$(sha "$d" main)" "$pre_main" "Ф4 грязный main: main не изменён"
assert_eq "$(sha "$d" integration)" "$pre_int" "Ф4 грязный main: integration не изменена"
rm -rf "$d"

# =============================================================================
echo "== Ф4: несовместимые комбинации флагов =="
# =============================================================================
d="$(mk_repo)"
cli "$d" multi on >/dev/null 2>&1
out="$(cli "$d" merge-main 1 --finalize-integration 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф4 finalize+id: rc != 0"
assert_contains "$out" "не совмещается" "Ф4 finalize+id: внятный отказ"
out="$(cli "$d" merge-main --branch foo --finalize-integration 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф4 finalize+--branch: rc != 0"
out="$(cli "$d" merge-main 1 --keep 2>&1)"; rc=$?
[ "$rc" != "0" ] && _pass || _fail "Ф4 --keep без finalize: rc != 0"
assert_contains "$out" "только вместе с --finalize-integration" "Ф4 --keep без finalize: внятный отказ"
rm -rf "$d"

echo "wave2_0060: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
