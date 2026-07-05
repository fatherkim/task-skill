#!/usr/bin/env bash
# test_wave2_0063.sh — волна 2: Ф13 нормализация depends-id.
# Всё в эфемерных git-репо (mktemp); живой трекер agent_tasks/ не трогается.
#
# Дефект (волна 1): cmd_new писал depends СЫРЬЁМ ("1"), а все потребители матчат
# против каноничных id ("0001") — задача вечно «не ready»/застревает в волнах;
# нечисловой dep крэшил merge-main ValueError. Фикс: единый norm_dep/dep_ids на
# записи И на чтении + мягкая обработка нечислового dep в гейте.
#
# Vacuous-контроль (протокол в отчёте задачи 0063). Красные до фикса: (a)(b)(c)(e).
#   (a) --depends 1: до фикса cmd_new пишет "1" -> после close депа задача НЕ ready.
#   (b) ready --waves с --depends 1: до фикса задача застревает («Ждут»), не в волне 2.
#   (c) ЛЕГАСИ-файл (depends: 1 вписан руками): до фикса read-path не нормализует ->
#       та же поломка даже без участия записи.
#   (e) нечисловой depends -> merge-main до фикса падает Traceback/ValueError, а не ⚠.
#   (d) КОНСИСТЕНТНОСТЬ (гейт↔планировщик): green на обоих кодах by design — гейт
#       нормализовал dep и до фикса (через _try_find), тест лишь фиксирует, что обе
#       стороны согласованы; НЕ входит в красный набор (см. Ф13 шаг 6).
# Прогон на до-фиксовом коде:
#   TASK_PY=$(mktemp); git show main:.claude/skills/task/scripts/task.py > $TASK_PY
#   TASK_PY=$TASK_PY bash .../tests/test_wave2_0063.sh   # -> красный (a)(b)(c)(e)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

# raw_depends <dir> <id> <val> — вписать СЫРОЙ depends в frontmatter (эмуляция
# старого файла до фикса записи; ту же роль играет set_depends в test_multi.sh).
raw_depends() {
  python3 - "$1" "$(printf '%04d' "$2")" "$3" <<'PY'
import sys, re, glob
d, tid, val = sys.argv[1], sys.argv[2], sys.argv[3]
fn = glob.glob(d + "/tasks/" + tid + "-*.md")[0]
s = open(fn).read()
open(fn, "w").write(re.sub(r'^depends:.*$', 'depends: ' + val, s, flags=re.M))
PY
}

dep_line() { grep -m1 '^depends:' "$1"/tasks/"$(printf '%04d' "$2")"-*.md; }

# set_field <dir> <id> <field> <val> — переписать <field>: во frontmatter.
set_field() {
  python3 - "$1" "$(printf '%04d' "$2")" "$3" "$4" <<'PY'
import sys, re, glob
d, tid, field, val = sys.argv[1:5]
fn = glob.glob(d + "/tasks/" + tid + "-*.md")[0]
s = open(fn).read()
open(fn, "w").write(re.sub(r'^' + field + r':.*$', field + ': ' + val, s, flags=re.M))
PY
}

# =============================================================================
echo "== (a) new --depends 1 (сырой): запись канонизирована; после close 0001 -> ready =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "dep first" --files src/a.c >/dev/null            # 0001
cli "$d" new "child raw" --files src/b.c --depends 1 >/dev/null  # 0002 dep СЫРОЙ 1
# шаг 2 (запись): frontmatter несёт уже "0001", формат трекера не изменился
assert_contains "$(dep_line "$d" 2)" "depends: 0001" "(a) cmd_new канонизирует depends: 1 -> 0001"
# до закрытия 0001 — 0002 не ready (dep не done)
out="$(cli "$d" ready 2>&1)"
assert_not_contains "$out" "0002" "(a) до закрытия 0001 задача 0002 не готова"
# закрываем 0001 -> 0002 становится ready (до фикса: НИКОГДА)
cli "$d" start 1 >/dev/null; cli "$d" close 1 >/dev/null
out="$(cli "$d" ready 2>&1)"
assert_contains "$out" "0002" "(a) после close 0001 задача 0002 готова [RED до фикса]"
rm -rf "$d"

# =============================================================================
echo "== (b) ready --waves с сырым --depends 1: задача в волне 2, не в «Ждут» =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "a" --files src/a.c >/dev/null                    # 0001
cli "$d" new "b" --files src/b.c --depends 1 >/dev/null        # 0002 dep СЫРОЙ 1
out="$(cli "$d" ready --waves 2>&1)"
w1="$(printf '%s\n' "$out" | grep '^Волна 1:')"
w2="$(printf '%s\n' "$out" | grep '^Волна 2:')"
assert_contains "$w1" "0001" "(b) Волна 1 содержит 0001"
assert_contains "$w2" "0002" "(b) Волна 2 содержит 0002 [RED до фикса: застревало]"
assert_contains "$w2" "после 0001" "(b) 0002 помечена '(после 0001)'"
assert_not_contains "$out" "Ждут" "(b) 0002 не в застрявших"
rm -rf "$d"

# =============================================================================
echo "== (c) ЛЕГАСИ: depends: 1 вписан руками (read-path нормализует) =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "a" --files src/a.c >/dev/null                    # 0001
cli "$d" new "b" --files src/b.c --depends 0001 >/dev/null     # 0002 (создана padded)
raw_depends "$d" 2 "1"          # эмуляция СТАРОГО файла: depends сырьём
cli "$d" index >/dev/null
assert_contains "$(dep_line "$d" 2)" "depends: 1" "(c) во frontmatter лежит сырой '1' (легаси)"
out="$(cli "$d" ready --waves 2>&1)"
w2="$(printf '%s\n' "$out" | grep '^Волна 2:')"
assert_contains "$w2" "0002" "(c) легаси-сырьё нормализовано на чтении -> волна 2 [RED до фикса]"
assert_not_contains "$out" "Ждут" "(c) 0002 не застряла на легаси-depends"
# и после close 0001 — ready
cli "$d" start 1 >/dev/null; cli "$d" close 1 >/dev/null
out="$(cli "$d" ready 2>&1)"
assert_contains "$out" "0002" "(c) после close 0001 легаси-0002 готова [RED до фикса]"
rm -rf "$d"

# =============================================================================
echo "== (d) КОНСИСТЕНТНОСТЬ: сырой depends:1 + не-done 0001 -> и не ready, И гейт отказ =="
# =============================================================================
# green на обоих кодах (гейт нормализовал dep и до фикса) — фиксирует, что
# асимметрия планировщик↔гейт закрыта с обеих сторон.
d="$(mk_repo)"
cli "$d" new "dep"   --files src/a.c >/dev/null                # 0001 (останется open)
cli "$d" new "child" --files src/b.c >/dev/null                # 0002
raw_depends "$d" 2 "1"          # сырой depends: 1, 0001 НЕ done
cli "$d" index >/dev/null
# планировщик: 0002 не готова (dep 0001 не done)
out="$(cli "$d" ready 2>&1)"
assert_not_contains "$out" "0002" "(d) планировщик: 0002 не ready при не-done 0001"
# гейт: merge-main 0002 отказывает (dep не закрыт)
( cd "$d"; git add -A; git commit -qm tasks
  git checkout -q -b task/0002; echo b > b.txt; git add b.txt; git commit -qm b
  git checkout -q main )
out="$(cli "$d" merge-main 2 2>&1)"; rc=$?
assert_eq "$rc" "1" "(d) гейт: merge-main 0002 отказ при не-done 0001"
# «не закрыта» присутствует на обоих кодах (гейт нормализовал dep и до фикса) —
# (d) специально green на pre/post, красный набор — (a)(b)(c)(e).
assert_contains "$out" "не закрыта" "(d) причина отказа: зависимость не закрыта"
rm -rf "$d"

# =============================================================================
echo "== (e) нечисловой depends -> merge-main не крэшится ValueError, печатает ⚠ =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "child ext" --files src/b.c --depends extref >/dev/null  # 0001 dep нечисловой
assert_contains "$(dep_line "$d" 1)" "depends: extref" "(e) нечисловой depends сохранён как есть"
( cd "$d"; git add -A; git commit -qm tasks
  git checkout -q -b task/0001; echo x > x.txt; git add x.txt; git commit -qm x
  git checkout -q main )
out="$(cli "$d" merge-main 1 2>&1)"; rc=$?
assert_eq "$rc" "0" "(e) merge-main не падает на нечисловом depends [RED до фикса: rc=1]"
assert_contains "$out" "нечисловой depends extref" "(e) печатает ⚠ о нечисловом dep [RED до фикса]"
assert_not_contains "$out" "Traceback" "(e) без Python-трейсбэка [RED до фикса]"
rm -rf "$d"

# =============================================================================
echo "== (f) multi: легаси depends:1 + dep 0001 done + task/0001 не влита -> ⚠ видимости =="
# =============================================================================
# Ф3-путь (_deps_visibility_report): планировщик (dep_ids) кладёт 0002 в ready,
# а отчёт видимости на СЫРОМ depends молча гас -> исполнитель строит на
# отсутствующем в HEAD коде зависимости. Красный до фикса :1332 (csv->dep_ids).
R="$(mk_repo)"
cli "$R" multi on >/dev/null 2>&1
cli "$R" new "dep"   --files src/a.c >/dev/null                # 0001
cli "$R" new "child" --files src/b.c --depends 0001 >/dev/null # 0002 (создана padded)
set_field "$R" 1 status done                                  # 0001 -> done
( cd "$R"; git add -A; git commit -qm tracker
  git checkout -q -b task/0001; mkdir -p src; echo code > src/a.c
  git add -A; git commit -qm impl
  git checkout -q main )                                       # task/0001 НЕ влита в main(HEAD)
raw_depends "$R" 2 "1"                                         # ЛЕГАСИ: depends сырьём "1"
out="$(cli "$R" ready 2>&1)"
assert_contains "$out" "0002" "(f) 0002 диспатчится (планировщик нормализует сырой dep)"
assert_contains "$out" "код зависимостей недоступен" "(f) ⚠ видимости печатается [RED до фикса :1332]"
assert_contains "$out" "task/0001 не влита" "(f) ⚠ называет невлитую ветку 0001 [RED до фикса]"
rm -rf "$R"

echo "wave2_0063: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
