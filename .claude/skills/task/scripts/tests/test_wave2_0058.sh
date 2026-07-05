#!/usr/bin/env bash
# test_wave2_0058.sh — волна 2: Ф1 doctor + Ф2 RECOVERY.md/якоря.
# Всё в эфемерных git-репо (mktemp); живой трекер agent_tasks/ не трогается.
#
# Vacuous-контроль: на до-фиксовом коде (нет команды `doctor`, нет RECOVERY.md)
# файл ОБЯЗАН падать — каждая проверка doctor-а бьётся о argparse-ошибку
# «invalid choice: 'doctor'», а тест якорей — о пустой список _recipe(...) и
# отсутствующий RECOVERY.md рядом с $TASK_PY. Прогон:
#   TASK_PY=$(mktemp); git show main:.claude/skills/task/scripts/task.py > $TASK_PY
#   TASK_PY=$TASK_PY bash .../tests/test_wave2_0058.sh   # -> красный
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

# --- локальные помощники ------------------------------------------------------

# doctor_line <dir> — весь вывод doctor (stderr+stdout) в одну строку окружения.
doc() { cli "$1" doctor 2>&1; }

# set_meta <dir> <id> <key> <val> — вставить/заменить строку frontmatter (для
# фабрикации испорченного трекера: risk вне диапазона, битый worktree и т.п.).
set_meta() {
  python3 - "$1" "$(printf '%04d' "$2")" "$3" "$4" <<'PY'
import sys, re, glob
d, tid, key, val = sys.argv[1:5]
fn = glob.glob(d + "/tasks/" + tid + "-*.md")[0]
s = open(fn).read()
if re.search(r'^' + re.escape(key) + r':', s, flags=re.M):
    s = re.sub(r'^' + re.escape(key) + r':.*$', key + ': ' + val, s, count=1, flags=re.M)
else:  # вставить сразу после строки status:
    s = re.sub(r'^(status:.*)$', r'\1\n' + key + ': ' + val, s, count=1, flags=re.M)
open(fn, "w").write(s)
PY
}

# newer_than_index <dir> <id> — выставить mtime task-файла позже _INDEX.md.
newer_than_index() {
  python3 - "$1" "$(printf '%04d' "$2")" <<'PY'
import sys, os, glob
d, tid = sys.argv[1], sys.argv[2]
f = glob.glob(d + "/tasks/" + tid + "-*.md")[0]
i = d + "/tasks/_INDEX.md"
t = os.path.getmtime(i) + 100
os.utime(f, (t, t))
PY
}

git_c() { git -C "$1" "${@:2}"; }

# =============================================================================
echo "== Ф1: doctor на чистом эталонном репо — 0 флагов, exit 0 =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "clean task" >/dev/null
out="$(doc "$d")"; rc=$?
assert_eq "$rc" "0" "doctor чистый репо -> rc 0"
assert_contains "$out" "— 0 проблем" "doctor чистый репо -> 0 проблем"
assert_not_contains "$out" "✗" "doctor чистый репо -> нет ✗"
assert_not_contains "$out" "⚠" "doctor чистый репо -> нет ⚠"
rm -rf "$d"

# =============================================================================
echo "== Ф1: каждая из 12 проверок ловится (испорченный эфемерный трекер) =="
# =============================================================================

# --- Проверка 1: _SCHEMA новее CLI ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null
echo 99 > "$d/tasks/_SCHEMA"
out="$(doc "$d")"; rc=$?
assert_eq "$rc" "0" "1 doctor не падает при _SCHEMA=99 (exit 0)"
assert_contains "$out" "новее CLI" "1 doctor ловит _SCHEMA новее CLI"
rm -rf "$d"

# --- Проверка 2: дубли id ---
d="$(mk_repo)"; cli "$d" new "alpha" >/dev/null
cp "$d"/tasks/0001-*.md "$d/tasks/0001-beta.md"
out="$(doc "$d")"
assert_contains "$out" "дубли id: 0001" "2 doctor ловит дубль id"
rm -rf "$d"

# --- Проверка 3a: depends на несуществующий id ---
d="$(mk_repo)"; cli "$d" new "a" --depends 0099 >/dev/null 2>&1
out="$(doc "$d")"
assert_contains "$out" "несуществующие depends" "3a doctor ловит битую depends-ссылку"
rm -rf "$d"

# --- Проверка 3b: цикл зависимостей ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null; cli "$d" new "b" --depends 0001 >/dev/null
set_meta "$d" 1 depends 0002        # 0001<->0002 (padded id, ловится _find_cycle)
out="$(doc "$d")"
assert_contains "$out" "цикл:" "3b doctor ловит цикл зависимостей"
rm -rf "$d"

# --- Проверка 4: пересечение files у двух in_progress ---
d="$(mk_repo)"
cli "$d" new "a" --files src/x.c >/dev/null
cli "$d" new "b" --files src/x.c >/dev/null
cli "$d" start 1 >/dev/null; cli "$d" start 2 >/dev/null
out="$(doc "$d")"
assert_contains "$out" "пересечение files у in_progress" "4 doctor ловит file-конфликт in_progress"
rm -rf "$d"

# --- Проверка 5: протухший _LOCK (>24ч) ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null
printf 'owner: ghost\nstarted: 2000-01-01T00:00:00\n' > "$d/tasks/_LOCK"
out="$(doc "$d")"
assert_contains "$out" "возможно протух" "5 doctor ловит протухший _LOCK"
rm -rf "$d"

# --- Проверка 6: multi в репо, worktree не принят (забыт sync --adopt) ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null
cli "$d" multi on >/dev/null 2>&1
rm -f "$d/tasks/_MULTI"          # локально режим «не принят», но task-sync несёт _MULTI
out="$(doc "$d")"; rc=$?
assert_eq "$rc" "0" "6 doctor не падает на непринятом worktree (exit 0)"
assert_contains "$out" "не принят — sync --adopt" "6 doctor ловит несинхронный worktree"
rm -rf "$d"

# --- Проверка 7: in_progress с несуществующим worktree ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null; cli "$d" start 1 >/dev/null
set_meta "$d" 1 worktree /nonexistent/xyz
out="$(doc "$d")"
assert_contains "$out" "worktree /nonexistent/xyz отсутствует" "7 doctor ловит битый worktree in_progress"
rm -rf "$d"

# --- Проверка 8: done с несмерженной веткой task/NNNN ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null; cli "$d" start 1 >/dev/null; cli "$d" close 1 >/dev/null
git_c "$d" add -A; git_c "$d" commit -qm "task 0001 done"
git_c "$d" checkout -q -b task/0001
( cd "$d" && echo x > extra.txt && git add extra.txt && git commit -qm x )
git_c "$d" checkout -q main
out="$(doc "$d")"
assert_contains "$out" "невлитой веткой: task/0001" "8 doctor ловит done с невлитой веткой"
rm -rf "$d"

# --- Проверка 9: stale integration (main ушёл вперёд) ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null
git_c "$d" branch integration main
( cd "$d" && echo y > f.txt && git add f.txt && git commit -qm adv )
out="$(doc "$d")"
assert_contains "$out" "main не влит (stale" "9 doctor ловит stale integration"
rm -rf "$d"

# --- Проверка 10: orphan _merge/* ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null
git_c "$d" branch _merge/9999 main
out="$(doc "$d")"
assert_contains "$out" "orphan _merge/* (остатки" "10 doctor ловит orphan _merge/*"
rm -rf "$d"

# --- Проверка 11: устаревший _INDEX.md ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null
newer_than_index "$d" 1
out="$(doc "$d")"
assert_contains "$out" "_INDEX.md устарел" "11 doctor ловит устаревший _INDEX.md"
rm -rf "$d"

# --- Проверка 12: risk вне 0–3 + пустое тело критериев ---
d="$(mk_repo)"; cli "$d" new "a" >/dev/null
set_meta "$d" 1 risk 5
out="$(doc "$d")"
assert_contains "$out" "risk=5 вне 0–3" "12 doctor ловит risk вне диапазона"
rm -rf "$d"

d="$(mk_repo)"; cli "$d" new "a" >/dev/null
# вычистить тело секции критериев (эмуляция незаполненной спеки)
python3 - "$d" <<'PY'
import sys, glob, re
f = glob.glob(sys.argv[1] + "/tasks/0001-*.md")[0]
s = open(f).read()
s = re.sub(r'(## Критерии приёмки\n).*?(\n## Вне скоупа)', r'\1\2', s, flags=re.S)
open(f, "w").write(s)
PY
out="$(doc "$d")"
assert_contains "$out" "пустое тело критериев" "12 doctor ловит пустые критерии"
rm -rf "$d"

# =============================================================================
echo "== Ф1: doctor ничего не мутирует (снапшот трекера до/после идентичен) =="
# =============================================================================
d="$(mk_repo)"
cli "$d" new "a" >/dev/null
cli "$d" new "b" --depends 0001 >/dev/null
cli "$d" start 1 >/dev/null
cli "$d" close 1 >/dev/null
newer_than_index "$d" 2           # заставить проверку 11 сработать (соблазн переписать index)
snap_before="$( ( cd "$d/tasks" && find . -type f -print0 | sort -z | xargs -0 shasum ) )"
idx_mtime_before="$(stat -f %m "$d/tasks/_INDEX.md")"
doc "$d" >/dev/null
snap_after="$( ( cd "$d/tasks" && find . -type f -print0 | sort -z | xargs -0 shasum ) )"
idx_mtime_after="$(stat -f %m "$d/tasks/_INDEX.md")"
assert_eq "$snap_before" "$snap_after" "doctor не изменил содержимое каталога трекера"
assert_eq "$idx_mtime_before" "$idx_mtime_after" "doctor не перегенерировал _INDEX.md"
rm -rf "$d"

# =============================================================================
echo "== Ф2: RECOVERY.md существует и покрывает все якоря из сообщений task.py =="
# =============================================================================
RECOVERY_MD="$(cd "$(dirname "$TASK_PY")/.." 2>/dev/null && pwd)/RECOVERY.md"
[ -f "$RECOVERY_MD" ] && _pass || _fail "RECOVERY.md существует ($RECOVERY_MD)"

# якоря, на которые ссылается код (аргументы _recipe("..."))
anchors="$(grep -oE '_recipe\("[a-z0-9-]+"\)' "$TASK_PY" | sed -E 's/_recipe\("([a-z0-9-]+)"\)/\1/' | sort -u)"
acount="$(printf '%s\n' "$anchors" | grep -c . )"
[ "$acount" -ge 1 ] && _pass || _fail "task.py ссылается хотя бы на один якорь RECOVERY (нашёл $acount)"
for a in $anchors; do
  grep -q "id=\"$a\"" "$RECOVERY_MD" 2>/dev/null && _pass || _fail "якорь #$a из task.py есть в RECOVERY.md"
done

# все кейсы списка Ф2.1 присутствуют секциями (покрытие, даже если код не ссылается)
for a in lock sync-conflict dup-id dirty-main integration worktree-remove schema serena-worktree; do
  grep -q "id=\"$a\"" "$RECOVERY_MD" 2>/dev/null && _pass || _fail "RECOVERY.md покрывает кейс #$a (Ф2.1)"
done

# сводка doctor ссылается на recovery-пакет
d="$(mk_repo)"; cli "$d" new "a" >/dev/null
assert_contains "$(doc "$d")" "рецепты: RECOVERY.md" "doctor-сводка ссылается на RECOVERY.md (Ф2)"
rm -rf "$d"

echo "wave2_0058: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
