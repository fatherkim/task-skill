#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Мини-трекер задач для конвейера «руки-агенты».

Задачи — markdown-файлы tasks/NNNN-slug.md с frontmatter (id, status, title,
files, depends, created). Тело файла — спека, единственный источник требований.
tasks/_INDEX.md генерируется автоматически при каждой мутации.
Зависимостей нет — только стандартная библиотека Python 3.

После `init` CLI копирует себя в <repo>/tasks/_cli.py, дальше все инструменты
(Claude Code / Codex / Cursor / что угодно) зовут: python3 tasks/_cli.py <cmd>
"""
import argparse
import datetime
import os
import re
import shutil
import sys

STATUSES = ("open", "in_progress", "blocked", "done")
STATUS_ORDER = {"in_progress": 0, "blocked": 1, "open": 2, "done": 3}
ARCHIVE_HINT = 50  # порог живых done, при котором подсказываем `archive --done`

# Версия схемы трекера. v1 = формат до owner/worktree; v2 = текущий (+owner, +Runs).
SCHEMA_VERSION = 2
SCHEMA_NAME = "_SCHEMA"

TEMPLATE = """## Задача
<что сделать и зачем — 2–5 предложений>

## Контекст
<затрагиваемые файлы и модули (см. `files` в frontmatter), важные ограничения, ссылки>

## Критерии приёмки
- [ ] <проверяемый пункт>

## Вне скоупа
- <чего в этой задаче делать НЕ нужно>
"""

TRANSLIT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "zh", "з": "z", "и": "i", "й": "j", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}


def slugify(title):
    s = title.lower()
    s = "".join(TRANSLIT.get(ch, ch) for ch in s)
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s[:40].rstrip("-") or "task"


def tasks_dir(create=False):
    """Каталог задач: рядом с _cli.py либо ./tasks относительно cwd."""
    me = os.path.abspath(__file__)
    if os.path.basename(me) == "_cli.py":
        return os.path.dirname(me)
    d = os.path.join(os.getcwd(), "tasks")
    if not os.path.isdir(d) and not create:
        sys.exit("Каталог tasks/ не найден. Запусти `python3 .../task.py init` в корне репозитория.")
    return d


# ---------- чтение/запись задач ----------

def parse_task(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", text, re.S)
    meta, body = {}, text
    if m:
        for line in m.group(1).splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip()
        body = m.group(2)
    meta["_path"] = path
    return meta, body


def render_task(meta, body):
    lines = ["---"]
    for k in ("id", "status", "title", "risk", "owner", "worktree", "returns", "files", "depends", "created", "spent", "spawns"):
        if k in meta:
            lines.append("%s: %s" % (k, meta[k]))
    lines.append("---")
    return "\n".join(lines) + "\n\n" + body.lstrip("\n")


def write_task(path, meta, body):
    with open(path, "w", encoding="utf-8") as f:
        f.write(render_task(meta, body))


# ---------- schema-version gate ----------

def _schema_path(d):
    return os.path.join(d, SCHEMA_NAME)


def _schema_check(d):
    """Файла нет → legacy v1, OK. Число > SCHEMA_VERSION или мусор → отказ."""
    p = _schema_path(d)
    if not os.path.exists(p):
        return
    raw = open(p, encoding="utf-8").read().strip()
    try:
        v = int(raw)
    except ValueError:
        sys.exit("ОТКАЗ: битый _SCHEMA (%r), CLI понимает только v%d — "
                 "обнови tasks/_cli.py из каноника." % (raw, SCHEMA_VERSION))
    if v > SCHEMA_VERSION:
        sys.exit("ОТКАЗ: трекер схемы v%d, CLI понимает только v%d — "
                 "обнови tasks/_cli.py из каноника" % (v, SCHEMA_VERSION))


def _schema_write(d, only_if_lower=False):
    p = _schema_path(d)
    if only_if_lower and os.path.exists(p):
        try:
            if int(open(p, encoding="utf-8").read().strip()) >= SCHEMA_VERSION:
                return
        except ValueError:
            pass
    with open(p, "w", encoding="utf-8") as f:
        f.write("%d\n" % SCHEMA_VERSION)


# ---------- run-лог попыток ----------

def _append_run(body, outcome, note="", spent="", owner=""):
    """Дописать строку в секцию `## Runs` тела задачи (создаёт секцию при отсутствии)."""
    ts = datetime.datetime.now().isoformat(timespec="seconds")
    line = "- %s — %s" % (ts, outcome)
    if owner:
        line += ", owner=%s" % owner
    if spent:
        line += ", spent=%s" % spent
    if note:
        line += " — %s" % note
    m = re.search(r"^## Runs[^\n]*$", body, re.M)
    if not m:
        return body.rstrip("\n") + "\n\n## Runs\n" + line + "\n"
    idx = m.end()
    return body[:idx] + "\n" + line + body[idx:]


# ---------- session-lock оркестратора ----------

LOCK_NAME = "_LOCK"
LOCK_STALE_HOURS = 24


def lock_path(d):
    return os.path.join(d, LOCK_NAME)


def read_lock(d):
    p = lock_path(d)
    if not os.path.exists(p):
        return None
    info = {}
    with open(p, encoding="utf-8") as f:
        for line in f:
            if ":" in line:
                k, v = line.split(":", 1)
                info[k.strip()] = v.strip()
    return info


def lock_age_str(info):
    try:
        t = datetime.datetime.fromisoformat(info.get("started", ""))
    except ValueError:
        return "возраст неизвестен"
    mins = int((datetime.datetime.now() - t).total_seconds() // 60)
    h, m = divmod(mins, 60)
    s = ("%dч %02dм" % (h, m)) if h else ("%dм" % m)
    if h >= LOCK_STALE_HOURS:
        s += " — возможно, протухший (>%dч)" % LOCK_STALE_HOURS
    return s


def write_lock(d, owner, exclusive):
    """exclusive=True — атомарное создание (O_EXCL), иначе перезапись."""
    content = "owner: %s\nstarted: %s\n" % (
        owner, datetime.datetime.now().isoformat(timespec="seconds"))
    mode = "x" if exclusive else "w"
    with open(lock_path(d), mode, encoding="utf-8") as f:
        f.write(content)


def lock_notice(d):
    """Напоминание при мутациях/ready: трекер залочен — чужая сессия должна остановиться."""
    info = read_lock(d)
    if info:
        print("⚠ трекер залочен: owner=%s, %s. Если это не твоя сессия — "
              "СТОП, работает другой оркестратор." % (
                  info.get("owner", "?"), lock_age_str(info)))


# ---------- мультиоркестраторный режим (task-multi, вариант B: worktree/оркестратор) ----------
#
# Каждый оркестратор живёт в своём git worktree; общий источник правды трекера —
# служебная ветка task-sync. Любая мутация в multi-режиме идёт транзакцией:
# глобальный mutex (flock в общем .git) -> sync(pull) -> операция -> sync(push).
# Конфликтов по task-файлам не бывает при дисциплине владения (start --owner):
# один файл задачи мутирует ровно один оркестратор.

MULTI_NAME = "_MULTI"
SYNC_BRANCH = "task-sync"
SYNC_BASE_NAME = ".sync-base"
SYNC_EXCLUDE = ("_INDEX.md", "_LOCK", SYNC_BASE_NAME, "_cli.py", ".DS_Store", "__pycache__")
MUTEX_TIMEOUT = 120  # сек ожидания глобального mutex


def multi_on(d):
    return os.path.exists(os.path.join(d, MULTI_NAME))


def _git(args, cwd, env_extra=None, input_=None, check=True):
    import subprocess
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    r = subprocess.run(["git"] + args, cwd=cwd, env=env, text=True,
                       input=input_, capture_output=True)
    if check and r.returncode != 0:
        sys.exit("git %s: %s" % (" ".join(args[:2]), (r.stderr or r.stdout).strip()))
    return r


def _git_dirs(d):
    gd = _git(["rev-parse", "--absolute-git-dir"], d).stdout.strip()
    common = _git(["rev-parse", "--git-common-dir"], d).stdout.strip()
    if not os.path.isabs(common):
        common = os.path.abspath(os.path.join(d, common))
    return gd, common


class _Mutex:
    """Глобальный mutex всех worktree одного репозитория (flock в общем .git)."""

    def __init__(self, d):
        _, common = _git_dirs(d)
        self.path = os.path.join(common, "task-multi.mutex")
        self.f = None

    def __enter__(self):
        import fcntl
        import time
        self.f = open(self.path, "a+")
        deadline = time.time() + MUTEX_TIMEOUT
        while True:
            try:
                fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError:
                if time.time() > deadline:
                    self.f.close()
                    sys.exit("Не дождался mutex %s за %dс — другой оркестратор завис в операции?" % (
                        self.path, MUTEX_TIMEOUT))
                time.sleep(0.5)

    def __exit__(self, *exc):
        import fcntl
        try:
            fcntl.flock(self.f, fcntl.LOCK_UN)
        finally:
            self.f.close()


def _tree_map(tree, cwd):
    """tree-ish -> {path: (mode, sha)}"""
    # --full-tree: иначе ls-tree фильтрует по префиксу cwd (каталога трекера) и карта пуста
    out = _git(["ls-tree", "-r", "--full-tree", tree], cwd).stdout
    m = {}
    for line in out.splitlines():
        head, path = line.split("\t", 1)
        mode, _typ, sha = head.split()
        m[path] = (mode, sha)
    return m


def _tmp_index():
    import tempfile
    fd, idx = tempfile.mkstemp(prefix="task-sync-idx-")
    os.close(fd)
    os.remove(idx)
    return idx


def _snapshot_tree(d):
    """Дерево текущего состояния каталога трекера (без служебных файлов)."""
    gd, _ = _git_dirs(d)
    idx = _tmp_index()
    env = {"GIT_DIR": gd, "GIT_WORK_TREE": os.path.abspath(d), "GIT_INDEX_FILE": idx}
    try:
        _git(["add", "-A", "-f", "--", "."], d, env)
        _git(["rm", "--cached", "-q", "-r", "--ignore-unmatch", "--"] + list(SYNC_EXCLUDE), d, env)
        return _git(["write-tree"], d, env).stdout.strip()
    finally:
        if os.path.exists(idx):
            os.remove(idx)


def _mktree(map_, d):
    gd, _ = _git_dirs(d)
    idx = _tmp_index()
    env = {"GIT_DIR": gd, "GIT_INDEX_FILE": idx}
    lines = "".join("%s %s\t%s\n" % (mode, sha, p) for p, (mode, sha) in sorted(map_.items()))
    try:
        _git(["update-index", "--index-info"], d, env, input_=lines)
        return _git(["write-tree"], d, env).stdout.strip()
    finally:
        if os.path.exists(idx):
            os.remove(idx)


def _materialize(d, tree, ours_map):
    """Выложить tree в каталог трекера; удалить локальные файлы, исчезнувшие после merge."""
    gd, _ = _git_dirs(d)
    idx = _tmp_index()
    env = {"GIT_DIR": gd, "GIT_WORK_TREE": os.path.abspath(d), "GIT_INDEX_FILE": idx}
    try:
        _git(["read-tree", tree], d, env)
        _git(["checkout-index", "-a", "-f"], d, env)
    finally:
        if os.path.exists(idx):
            os.remove(idx)
    merged_map = _tree_map(tree, d)
    for p in set(ours_map) - set(merged_map):
        fp = os.path.join(d, p)
        if os.path.exists(fp):
            os.remove(fp)


def _sync_base_path(d):
    return os.path.join(d, SYNC_BASE_NAME)


def _sync(d, adopt=False, prefer=None, quiet=False):
    """3-way синхронизация трекера с веткой task-sync (вызывать под mutex)."""
    _schema_check(d)
    tipr = _git(["rev-parse", "--verify", "-q", "refs/heads/%s" % SYNC_BRANCH], d, check=False)
    tip = tipr.stdout.strip() if tipr.returncode == 0 else None
    bp = _sync_base_path(d)
    base = open(bp).read().strip() if os.path.exists(bp) else None
    ours = _snapshot_tree(d)

    if tip is None:  # первая синхронизация в репозитории
        c = _git(["commit-tree", ours, "-m", "task-sync: init"], d).stdout.strip()
        _git(["update-ref", "refs/heads/%s" % SYNC_BRANCH, c], d)
        with open(bp, "w") as f:
            f.write(c + "\n")
        if not quiet:
            print("sync: создана ветка %s (%s)" % (SYNC_BRANCH, c[:8]))
        return

    if base is None:  # свежий worktree: локальная копия трекера — от точки ветвления, не от task-sync
        if not adopt:
            sys.exit("sync: нет %s (свежий worktree?). Прими состояние ветки: sync --adopt "
                     "(локальная копия трекера будет ЗАМЕНЕНА состоянием %s)." % (SYNC_BASE_NAME, SYNC_BRANCH))
        _materialize(d, tip + "^{tree}", _tree_map(ours, d))
        _schema_check(d)  # подтянули чужую (возможно, более новую) схему
        with open(bp, "w") as f:
            f.write(tip + "\n")
        regen_index(d)
        _warn_dup_ids(d)
        if not quiet:
            print("sync: принято состояние %s (%s)" % (SYNC_BRANCH, tip[:8]))
        return

    tip_tree = _git(["rev-parse", tip + "^{tree}"], d).stdout.strip()
    om = _tree_map(ours, d)
    tm = _tree_map(tip_tree, d)
    if om == tm:
        with open(bp, "w") as f:
            f.write(tip + "\n")
        if not quiet:
            print("sync: актуально (%s)" % tip[:8])
        return
    basr = _git(["rev-parse", "--verify", "-q", base + "^{tree}"], d, check=False)
    if basr.returncode != 0:
        sys.exit("sync: base-коммит %s из %s не найден в репо — восстанови: sync --adopt." % (base[:8], SYNC_BASE_NAME))
    bm = _tree_map(basr.stdout.strip(), d)

    merged, conflicts = {}, []
    for p in sorted(set(bm) | set(om) | set(tm)):
        b, o, t = bm.get(p), om.get(p), tm.get(p)
        if o == t:
            pick = o
        elif b == o:
            pick = t  # менялись только они (включая их удаление/добавление)
        elif b == t:
            pick = o  # менялись только мы
        else:  # обе стороны меняли по-разному
            if prefer == "ours":
                pick = o
            elif prefer == "theirs":
                pick = t
            else:
                conflicts.append(p)
                continue
        if pick is not None:
            merged[p] = pick
    if conflicts:
        sys.exit("sync: конфликт — обе стороны меняли: %s\n"
                 "При дисциплине start --owner такого быть не должно. Разбор: "
                 "сверь файл(ы) с git show %s:<путь> и повтори sync --prefer ours|theirs." % (
                     ", ".join(conflicts), SYNC_BRANCH))

    mt = _mktree(merged, d)
    pulled = sum(1 for p in merged if om.get(p) != merged[p]) + len(set(om) - set(merged))
    pushed = sum(1 for p in merged if tm.get(p) != merged[p]) + len(set(tm) - set(merged))
    new = tip
    if mt != tip_tree:
        msg = "task-sync: %s" % datetime.datetime.now().isoformat(timespec="seconds")
        new = _git(["commit-tree", mt, "-p", tip, "-m", msg], d).stdout.strip()
        _git(["update-ref", "refs/heads/%s" % SYNC_BRANCH, new, tip], d)
    if mt != ours:
        _materialize(d, mt, om)
        _schema_check(d)  # подтянули чужую (возможно, более новую) схему
    with open(bp, "w") as f:
        f.write(new + "\n")
    regen_index(d)
    _warn_dup_ids(d)
    if not quiet:
        print("sync: принято файлов %d, отправлено %d (%s)" % (pulled, pushed, new[:8]))


def _cur_worktree(d):
    return _git(["rev-parse", "--show-toplevel"], d).stdout.strip()


def _warn_dup_ids(d):
    seen = {}
    for t in all_tasks(d):
        seen.setdefault(t.get("id"), []).append(os.path.basename(t.get("_path", "?")))
    dname = os.path.basename(os.path.abspath(d).rstrip("/"))
    for i, fs in sorted(seen.items()):
        if len(fs) > 1:
            print("⚠ ДУБЛЬ id %s: %s — переномеруй одну из задач (mv + правка id + index)." % (
                i, ", ".join(fs)))
            print("Задание на разбор дубля (отдай свободному оркестратору/исполнителю):")
            print("  1. Определи, какой файл настоящий %s (git log ветки %s: кто первый)." % (i, SYNC_BRANCH))
            print("  2. Второму файлу выдай следующий свободный id: mv + правь id: в frontmatter.")
            print("  3. grep по '%s' в %s/*.md — поправь depends, ссылающиеся на перенумерованный." % (i, dname))
            print("  4. python3 %s/_cli.py index && python3 %s/_cli.py sync" % (dname, dname))


def _owner_guard(d, meta, owner, force, verb):
    """close/block/unblock в multi-режиме — только владельцем задачи."""
    if not multi_on(d) or force:
        return
    cur = meta.get("owner")
    if not cur:
        return
    if not owner:
        sys.exit("Multi-режим: %s требует --owner (задача %s принадлежит owner=%s)." % (
            verb, meta.get("id"), cur))
    if owner != cur:
        sys.exit("ОТКАЗ: %s — задача %s принадлежит owner=%s, а не %s. "
                 "--force только с подтверждения пользователя." % (verb, meta.get("id"), cur, owner))
    rec = meta.get("worktree")
    if rec and rec != _cur_worktree(d):
        sys.exit("ОТКАЗ: %s — owner совпал (%s), но задача взята из другого worktree (%s). "
                 "Две сессии с одной меткой? Смени метку (добавь случайный хвост)." % (
                     verb, cur, rec))


def _multi_begin(d):
    """В multi-режиме: захватить mutex + подтянуть трекер. Вернуть mutex (или None)."""
    if not multi_on(d):
        # детект несинхронизированного worktree: режим включён глобально, а локально не принят
        r = _git(["cat-file", "-e", "%s:%s" % (SYNC_BRANCH, MULTI_NAME)], d, check=False)
        if r.returncode == 0:
            sys.exit("ОТКАЗ: в репозитории включён multi-режим (ветка %s несёт %s), а этот worktree "
                     "не синхронизирован. Выполни: python3 %s/_cli.py sync --adopt" % (
                         SYNC_BRANCH, MULTI_NAME, os.path.basename(os.path.abspath(d).rstrip("/"))))
        return None
    mx = _Mutex(d).__enter__()
    try:
        _sync(d, quiet=True)
    except SystemExit:
        mx.__exit__()
        raise
    return mx

def _multi_end(d, mx):
    """Оттолкнуть изменения и отпустить mutex."""
    if mx is None:
        return
    try:
        _sync(d, quiet=True)
    finally:
        mx.__exit__()


def all_tasks(d):
    items = []
    for name in sorted(os.listdir(d)):
        if re.match(r"^\d{4}-.*\.md$", name):
            meta, _ = parse_task(os.path.join(d, name))
            items.append(meta)
    return items


def archived_tasks(d):
    """Задачи, уже перенесённые в <tracker>/archive/ (read-only)."""
    adir = os.path.join(d, "archive")
    items = []
    if not os.path.isdir(adir):
        return items
    for name in sorted(os.listdir(adir)):
        if re.match(r"^\d{4}-.*\.md$", name):
            meta, _ = parse_task(os.path.join(adir, name))
            items.append(meta)
    return items


def csv(meta, key):
    return [x.strip() for x in meta.get(key, "").split(",") if x.strip()]


def find(d, tid):
    tid = "%04d" % int(tid)
    for name in sorted(os.listdir(d)):
        if name.startswith(tid + "-") and name.endswith(".md"):
            return os.path.join(d, name)
    sys.exit("Задача %s не найдена (возможно, в archive/ — см. _ARCHIVE.md)." % tid)


def find_any(d, tid):
    """Сначала живой каталог, затем archive/. Возвращает (path, is_archived)."""
    tid = "%04d" % int(tid)
    for name in sorted(os.listdir(d)):
        if name.startswith(tid + "-") and name.endswith(".md"):
            return os.path.join(d, name), False
    adir = os.path.join(d, "archive")
    if os.path.isdir(adir):
        for name in sorted(os.listdir(adir)):
            if name.startswith(tid + "-") and name.endswith(".md"):
                return os.path.join(adir, name), True
    sys.exit("Задача %s не найдена (возможно, в archive/ — см. _ARCHIVE.md)." % tid)


# ---------- индекс ----------

def table(tasks):
    lines = [
        "| ID | Статус | Задача | Файлы | Зависит |",
        "|----|--------|--------|-------|---------|",
    ]
    for t in tasks:
        lines.append("| %s | %s | %s | %s | %s |" % (
            t.get("id", "?"), t.get("status", "?"), t.get("title", ""),
            ", ".join(csv(t, "files")) or "—",
            ", ".join(csv(t, "depends")) or "—",
        ))
    if not tasks:
        lines.append("| — | — | нет задач | — | — |")
    return lines


def regen_index(d):
    dname = os.path.basename(os.path.abspath(d).rstrip("/"))
    tasks = sorted(all_tasks(d),
                   key=lambda t: (STATUS_ORDER.get(t.get("status"), 9), t.get("id", "")))
    active = [t for t in tasks if t.get("status") != "done"]
    done = [t for t in tasks if t.get("status") == "done"]
    lines = [
        "# Индекс задач",
        "",
        "> Генерируется автоматически (`python3 %s/_cli.py index`). Руками НЕ редактировать." % dname,
        "",
    ]
    lines += table(active)
    lines += ["", "**Done (%d):** %s" % (len(done), ", ".join(t.get("id", "?") for t in done) or "—"), ""]
    archived = archived_tasks(d)
    if archived:
        atotal = 0
        for t in archived:
            if t.get("spent"):
                tt, _ = _parse_spent(t["spent"])
                atotal += sum(tt.values())
        if atotal:
            lines.append("**Архив (%d):** ~%s токенов — см. _ARCHIVE.md" % (len(archived), "{:,}".format(atotal)))
        else:
            lines.append("**Архив (%d):** — см. _ARCHIVE.md" % len(archived))
        lines.append("")
    with open(os.path.join(d, "_INDEX.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


# ---------- команды ----------

def cmd_init(args):
    d = os.path.join(os.getcwd(), "tasks")
    os.makedirs(d, exist_ok=True)
    src = os.path.abspath(__file__)
    dst = os.path.join(d, "_cli.py")
    if src != os.path.abspath(dst):
        shutil.copy(src, dst)
    _schema_write(d)
    regen_index(d)
    print("Готово: %s" % d)
    print('Дальше: python3 tasks/_cli.py new "Название задачи" --files src/a.py,src/b.py')


def cmd_new(args):
    d = tasks_dir()
    _schema_check(d)
    lock_notice(d)
    mx = _multi_begin(d)
    ids = [int(t["id"]) for t in all_tasks(d) + archived_tasks(d) if t.get("id", "").isdigit()]
    nid = "%04d" % (max(ids) + 1 if ids else 1)
    title = " ".join(args.title).strip()
    path = os.path.join(d, "%s-%s.md" % (nid, slugify(title)))
    meta = {
        "id": nid, "status": "open", "title": title,
        "files": args.files or "", "depends": args.depends or "",
        "created": datetime.date.today().isoformat(),
    }
    if getattr(args, "risk", None) is not None:
        meta["risk"] = str(args.risk)
    if mx is not None:
        # multi: рождение задачи = коммит в task-sync; локальный файл — следствие.
        # Порядок против crash-окна: (1) коммит в ветку, (2) локальный файл,
        # (3) .sync-base. Обрыв между шагами не теряет задачу и не дублирует id.
        blob = _git(["hash-object", "-w", "--stdin"], d,
                    input_=render_task(meta, TEMPLATE)).stdout.strip()
        tip = _git(["rev-parse", "refs/heads/%s" % SYNC_BRANCH], d).stdout.strip()
        tm = _tree_map(tip + "^{tree}", d)
        tm[os.path.basename(path)] = ("100644", blob)
        c = _git(["commit-tree", _mktree(tm, d), "-p", tip,
                  "-m", "task-sync: new %s" % nid], d).stdout.strip()
        _git(["update-ref", "refs/heads/%s" % SYNC_BRANCH, c, tip], d)
        write_task(path, meta, TEMPLATE)
        with open(_sync_base_path(d), "w") as f:
            f.write(c + "\n")
        regen_index(d)
        _multi_end(d, mx)
    else:
        write_task(path, meta, TEMPLATE)
        regen_index(d)
    if args.depends:
        known = set(t.get("id") for t in all_tasks(d) + archived_tasks(d))
        for dep in [x.strip() for x in args.depends.split(",") if x.strip()]:
            dep4 = ("%04d" % int(dep)) if dep.isdigit() else dep
            if dep4 not in known:
                print("⚠ depends %s: задачи с таким id пока нет (создашь следом?)." % dep4)
    print("Создана задача %s: %s" % (nid, os.path.relpath(path)))
    print("Заполни спеку в теле файла (секции Задача / Контекст / Критерии приёмки / Вне скоупа).")


def cmd_list(args):
    d = tasks_dir()
    _multi_end(d, _multi_begin(d))  # multi: показать свежую картину, не локальный кэш
    tasks = sorted(all_tasks(d),
                   key=lambda t: (STATUS_ORDER.get(t.get("status"), 9), t.get("id", "")))
    if args.status != "all":
        tasks = [t for t in tasks if t.get("status") == args.status]
    print("\n".join(table(tasks)))


def cmd_view(args):
    d = tasks_dir()
    _multi_end(d, _multi_begin(d))  # multi: свежая спека, не локальный кэш
    path, is_archived = find_any(d, args.id)
    if is_archived:
        print("[архив]")
    with open(path, encoding="utf-8") as f:
        print(f.read())


def _set_status(tid, status, append=None, owner=None, claim=False, force=False,
                guard_verb=None, run=None):
    d = tasks_dir()
    _schema_check(d)
    lock_notice(d)
    mx = _multi_begin(d)
    path = find(d, tid)
    meta, body = parse_task(path)
    meta.pop("_path", None)
    if claim:
        if multi_on(d) and not owner:
            _multi_end(d, mx)
            sys.exit("Multi-режим: start требует --owner <метка оркестратора>.")
        if meta.get("status") == "in_progress":
            if meta.get("owner") != owner:
                _multi_end(d, mx)
                sys.exit("ОТКАЗ: задача %s уже in_progress у owner=%s — claim невозможен." % (
                    meta.get("id"), meta.get("owner", "?")))
            if multi_on(d) and meta.get("worktree") and meta["worktree"] != _cur_worktree(d):
                _multi_end(d, mx)
                sys.exit("ОТКАЗ: задача %s уже in_progress с той же меткой owner=%s, но из другого "
                         "worktree (%s). Две сессии с одинаковой меткой — смени метку "
                         "(добавь случайный хвост)." % (meta.get("id"), owner, meta["worktree"]))
        if multi_on(d):
            meta["worktree"] = _cur_worktree(d)
    if guard_verb:
        _owner_guard(d, meta, owner, force, guard_verb)
    if owner:
        meta["owner"] = owner
    meta["status"] = status
    if run:
        body = _append_run(body, run[0], note=run[1],
                           owner=owner or meta.get("owner", ""))
    if append:
        body = body.rstrip() + "\n\n" + append + "\n"
    write_task(path, meta, body)
    regen_index(d)
    _multi_end(d, mx)
    print("%s -> %s%s" % (meta.get("id"), status,
                          (" (owner=%s)" % owner) if owner else ""))


def cmd_start(args):
    _set_status(args.id, "in_progress", owner=args.owner, claim=True)


def cmd_block(args):
    note = "## Блокировка (%s)\n%s" % (datetime.date.today().isoformat(),
                                       args.reason or "<причина не указана>")
    _set_status(args.id, "blocked", append=note,
                owner=args.owner, force=args.force, guard_verb="block",
                run=("blocked", args.reason or ""))


def cmd_unblock(args):
    _set_status(args.id, "open",
                owner=args.owner, force=args.force, guard_verb="unblock")


def cmd_close(args):
    note = "## Приёмка (%s)\n%s" % (datetime.date.today().isoformat(),
                                    args.note or "Критерии приёмки выполнены.")
    d = tasks_dir()
    _schema_check(d)
    lock_notice(d)
    mx = _multi_begin(d)
    path = find(d, args.id)
    meta, body = parse_task(path)
    meta.pop("_path", None)
    _owner_guard(d, meta, args.owner, args.force, "close")
    meta["status"] = "done"
    if args.spent:
        meta["spent"] = args.spent
    body = _append_run(body, "closed", note=(args.note or "")[:80],
                       spent=args.spent or "", owner=args.owner or meta.get("owner", ""))
    write_task(path, meta, body.rstrip() + "\n\n" + note + "\n")
    regen_index(d)
    _multi_end(d, mx)
    print("%s -> done" % meta.get("id"))
    live_done = sum(1 for t in all_tasks(d) if t.get("status") == "done")
    if live_done >= ARCHIVE_HINT:
        print("Подсказка: done-задач %d — сожми историю: python3 %s/_cli.py archive --done" % (
            live_done, os.path.basename(os.path.abspath(d).rstrip("/"))))


def cmd_return(args):
    d = tasks_dir()
    _schema_check(d)
    lock_notice(d)
    mx = _multi_begin(d)
    path = find(d, args.id)
    meta, body = parse_task(path)
    meta.pop("_path", None)
    if meta.get("status") != "in_progress":
        _multi_end(d, mx)
        sys.exit("ОТКАЗ: return применим только к in_progress (задача %s: %s)." % (
            meta.get("id"), meta.get("status")))
    _owner_guard(d, meta, args.owner, args.force, "return")
    try:
        returns = int(meta.get("returns", "0"))
    except ValueError:
        returns = 0
    returns += 1
    meta["returns"] = str(returns)
    body = _append_run(body, "returned", note=args.reason, spent=args.spent or "",
                       owner=args.owner or meta.get("owner", ""))
    note = "## Возврат %d (%s)\n%s" % (returns, datetime.date.today().isoformat(), args.reason)
    body = body.rstrip() + "\n\n" + note + "\n"
    # статус остаётся in_progress — задача у того же исполнителя
    write_task(path, meta, body)
    regen_index(d)
    _multi_end(d, mx)
    print("%s -> возврат #%d (in_progress)" % (meta.get("id"), returns))
    if returns >= 3:
        print("⚠ ЦИКЛ: 3 возврата — СТОП, эскалируй пользователю "
              "(правило circuit breaker в SKILL.md)")


ARCHIVE_FILE = "_ARCHIVE.md"


def _fallback_summary(body):
    """Первое предложение текста после ПОСЛЕДНЕГО заголовка `## Приёмка ...`."""
    matches = list(re.finditer(r"## Приёмка[^\n]*\n+(.+?)(?:[.;]\s|\n)", body, re.S))
    if matches:
        return matches[-1].group(1).strip()
    return "приёмка не записана"


def _load_archive_entries(d):
    """id -> полный текст записи (bullet), из существующего _ARCHIVE.md."""
    path = os.path.join(d, ARCHIVE_FILE)
    entries = {}
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as f:
        text = f.read()
    for m in re.finditer(r"- \*\*(\d{4})\*\*.*?(?=\n- \*\*\d{4}\*\*|\Z)", text, re.S):
        entries[m.group(1)] = m.group(0).rstrip("\n")
    return entries


def _archive_entry_line(meta, summary):
    date = datetime.date.today().isoformat()
    line = "- **%s** %s" % (meta.get("id"), meta.get("title", ""))
    if meta.get("spent"):
        line += " — spent %s" % meta["spent"]
    line += " — архив %s. %s" % (date, summary)
    return line


def _write_archive_file(d, entries):
    path = os.path.join(d, ARCHIVE_FILE)
    lines = [
        "# Архив задач",
        "",
        "> Генерируется CLI (archive). Руками не редактировать.",
        "",
    ]
    for tid in sorted(entries):
        lines.append(entries[tid])
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def _do_archive_one(d, tid, summary=None):
    path = find(d, tid)
    meta, body = parse_task(path)
    if meta.get("status") != "done":
        sys.exit("Задача %s: архивируются только done." % meta.get("id"))
    if not summary:
        summary = _fallback_summary(body)
    adir = os.path.join(d, "archive")
    os.makedirs(adir, exist_ok=True)
    dst = os.path.join(adir, os.path.basename(path))
    os.replace(path, dst)
    entries = _load_archive_entries(d)
    entries[meta["id"]] = _archive_entry_line(meta, summary)
    _write_archive_file(d, entries)
    regen_index(d)
    print("%s -> archive/" % meta["id"])


def cmd_archive(args):
    d = tasks_dir()
    _schema_check(d)
    lock_notice(d)
    mx = _multi_begin(d)
    if args.done:
        if args.id:
            sys.exit("id и --done взаимоисключимы.")
        if args.summary:
            sys.exit("--summary только при одиночном id.")
        done_ids = [t["id"] for t in all_tasks(d) if t.get("status") == "done"]
        for tid in done_ids:
            _do_archive_one(d, tid)
        print("архивировано %d задач" % len(done_ids))
    else:
        if not args.id:
            sys.exit("Укажи ID задачи или --done.")
        _do_archive_one(d, args.id, args.summary)
    _multi_end(d, mx)


def _parse_spent(s):
    """'sonnet(2):34k, haiku:6200' -> ({'sonnet': 34000, 'haiku': 6200}, {'sonnet': 2, 'haiku': 1})"""
    totals, counts = {}, {}
    for part in s.split(","):
        if ":" not in part:
            continue
        name, val = part.split(":", 1)
        name = name.strip()
        cnt = 1
        m = re.match(r"^([\w.-]+)\s*\((\d+)\)$", name)
        if m:
            name, cnt = m.group(1), int(m.group(2))
        val = val.strip().lower().replace("_", "")
        mult = 1
        if val.endswith("k"):
            mult, val = 1000, val[:-1]
        elif val.endswith("m"):
            mult, val = 1000000, val[:-1]
        try:
            totals[name] = totals.get(name, 0) + int(float(val) * mult)
            counts[name] = counts.get(name, 0) + cnt
        except ValueError:
            pass
    return totals, counts


CONSTANTS_FILE = "_CONSTANTS.md"


def _load_constants(d):
    path = os.path.join(d, CONSTANTS_FILE)
    out = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^([\w.-]+):\s*([\d.]+[km]?)\s*$", line.strip(), re.I)
                if m:
                    t, _ = _parse_spent("%s:%s" % (m.group(1), m.group(2)))
                    out.update(t)
    return out


def cmd_calibrate(args):
    d = tasks_dir()
    mx = _multi_begin(d)
    path = os.path.join(d, CONSTANTS_FILE)
    if args.set:
        _schema_check(d)
        totals, _ = _parse_spent(args.set)
        if not totals:
            sys.exit('Не распарсил значения. Формат: calibrate --set "sonnet:12k,haiku:4k,serena:8k"')
        cur = _load_constants(d)
        cur.update(totals)
        lines = [
            "# Калибровка цены спавна (input-токены)",
            "",
            "> Генерируется `calibrate --set`. Руками не редактировать. Последняя калибровка: %s" % datetime.date.today().isoformat(),
            "> Модели — базовый спавн (системный промпт + стандартные тулы).",
            "> serena / codebase_memory — приращение контекста за подключённый MCP на один спавн.",
            "",
        ]
        for k in sorted(cur):
            lines.append("%s: %d" % (k, cur[k]))
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        print("Сохранено: %s" % os.path.relpath(path))
    cur = _load_constants(d)
    if cur:
        print("Константы (input-токены на спавн/подключение):")
        for k in sorted(cur):
            print("  %s: %s" % (k, "{:,}".format(cur[k])))
    else:
        print("Калибровка пуста. Процедура — раздел «Калибровка» в SKILL.md, затем calibrate --set.")
    _multi_end(d, mx)


def cmd_stats(args):
    d = tasks_dir()
    tasks = all_tasks(d)
    archived = archived_tasks(d)
    by_status = {}
    by_model = {}
    spawns = {}
    tracked = 0
    for t in tasks:
        by_status[t.get("status", "?")] = by_status.get(t.get("status", "?"), 0) + 1
    for t in tasks + archived:
        if t.get("spent"):
            tracked += 1
            tt, cc = _parse_spent(t["spent"])
            for m, n in tt.items():
                by_model[m] = by_model.get(m, 0) + n
            for m, n in cc.items():
                spawns[m] = spawns.get(m, 0) + n
        if t.get("spawns"):  # legacy-формат: отдельное поле spawns "sonnet:2"
            tt, _ = _parse_spent(t["spawns"])
            for m, n in tt.items():
                spawns[m] = spawns.get(m, 0) + n
    print("Задач: %d  (%s)  archived: %d" % (len(tasks),
          ", ".join("%s: %d" % kv for kv in sorted(by_status.items())), len(archived)))
    live_done = by_status.get("done", 0)
    if live_done >= ARCHIVE_HINT:
        print("Подсказка: done-задач %d — сожми историю: python3 %s/_cli.py archive --done" % (
            live_done, os.path.basename(os.path.abspath(d).rstrip("/"))))
    if by_model:
        total = sum(by_model.values())
        print("Потрачено токенов (по %d задачам с учётом): %s  итого ~%s" % (
            tracked,
            ", ".join("%s: %s" % (m, "{:,}".format(n)) for m, n in sorted(by_model.items())),
            "{:,}".format(total)))
        done_tracked = [t for t in tasks if t.get("spent") and t.get("status") == "done"]
        if done_tracked:
            print("Среднее на закрытую задачу: ~%s" % "{:,}".format(total // max(len(done_tracked), 1)))
        init_map = _load_constants(d)
        if getattr(args, "init", None):
            init_map.update(_parse_spent(args.init)[0])
        if init_map and spawns:
            print("Разложение (оценка; константы из %s, кэш не учтён):" % CONSTANTS_FILE)
            for m in sorted(by_model):
                oh = spawns.get(m, 0) * init_map.get(m, 0)
                work = max(by_model[m] - oh, 0)
                if by_model[m]:
                    if oh > by_model[m]:
                        print("  %s: (!) константа x спавны (~%s) превышает расход (%s) — проверь калибровку и счётчики в скобках" % (
                            m, "{:,}".format(oh), "{:,}".format(by_model[m])))
                    else:
                        print("  %s: работа ~%s, инициализация ~%s (%d спавнов, %.0f%% расхода)" % (
                            m, "{:,}".format(work), "{:,}".format(oh),
                            spawns.get(m, 0), 100.0 * oh / by_model[m]))
            tot_oh = sum(spawns.get(m, 0) * init_map.get(m, 0) for m in by_model)
            if total:
                print("  Итого доля инициализации: %.0f%% — если стабильно >30%%, задачи слишком мелкие, укрупняй декомпозицию." % (100.0 * tot_oh / total))
    else:
        print("Учёт расхода пуст: закрывай задачи с --spent \"model:tokens,...\" (данные — из счётчиков инструмента, не из самоотчёта).")
    # структурная пропорция: индекс vs полное сканирование спек
    idx = os.path.join(d, "_INDEX.md")
    if os.path.exists(idx):
        idx_size = os.path.getsize(idx)
        full = sum(os.path.getsize(os.path.join(d, n)) for n in os.listdir(d)
                   if re.match(r"^\d{4}-.*\.md$", n))
        adir = os.path.join(d, "archive")
        if os.path.isdir(adir):
            full += sum(os.path.getsize(os.path.join(adir, n)) for n in os.listdir(adir)
                        if re.match(r"^\d{4}-.*\.md$", n))
        if full:
            print("Ориентация по индексу vs чтение всех спек: %s vs %s байт (x%.1f)" % (
                "{:,}".format(idx_size), "{:,}".format(full), full / max(idx_size, 1)))


def _risk_suffix(t):
    try:
        r = int(t.get("risk", ""))
    except ValueError:
        return ""
    return " [r%d]" % r if r >= 2 else ""


def _find_cycle(rem):
    """rem: {id: meta}. Вернуть список участников цикла (deps внутри rem) или None."""
    color = {}  # 0 unvisited, 1 in-stack, 2 done
    stack = []

    def dfs(u):
        color[u] = 1
        stack.append(u)
        for dp in csv(rem[u], "depends"):
            if dp in rem:
                if color.get(dp, 0) == 1:
                    return stack[stack.index(dp):] + [dp]
                if color.get(dp, 0) == 0:
                    c = dfs(dp)
                    if c:
                        return c
        color[u] = 2
        stack.pop()
        return None

    for u in sorted(rem):
        if color.get(u, 0) == 0:
            c = dfs(u)
            if c:
                return c
    return None


def _compute_waves(tasks, done):
    """Топосортировка Кана open-задач по волнам + разведение пересечений файлов.

    Возвращает (waves, placed, remaining, live_status): waves — список списков meta;
    placed — {id: номер волны}; remaining — {id: meta} застрявших; live_status —
    {id: status} всех живых задач.
    """
    live_status = {t["id"]: t.get("status") for t in tasks if t.get("id")}
    remaining = {t["id"]: t for t in tasks if t.get("status") == "open"}
    satisfied = set(done)
    waves, placed = [], {}
    wn = 0
    while remaining:
        cand = [t for tid, t in remaining.items()
                if set(csv(t, "depends")) <= satisfied]
        if not cand:
            break  # застряли — waiting или цикл
        cand.sort(key=lambda t: t["id"])
        wn += 1
        wave, used = [], set()
        for t in cand:
            f = set(csv(t, "files"))
            if f & used:
                continue  # пересечение по файлам — в следующую волну
            wave.append(t)
            used |= f
        for t in wave:
            satisfied.add(t["id"])
            placed[t["id"]] = wn
            del remaining[t["id"]]
        waves.append(wave)
    return waves, placed, remaining, live_status


def _wait_reason(t, satisfied, live_status, remaining):
    """Описание, почему open-задача не попала в волны (первый невыполнимый dep)."""
    for dp in csv(t, "depends"):
        if dp in satisfied:
            continue
        st = live_status.get(dp)
        if st == "blocked":
            return "блокирована %s" % dp
        if st == "in_progress":
            return "в работе %s" % dp
        if dp in remaining:
            return "цикл через %s" % dp
        if st is None:
            return "нет задачи %s" % dp
        return "ждёт %s (%s)" % (dp, st)
    return "нет свободных файлов"


def cmd_ready(args):
    d = tasks_dir()
    lock_notice(d)
    mx = _multi_begin(d)   # свежий трекер: без sync ready видит устаревшие чужие claim'ы
    _multi_end(d, mx)
    tasks = all_tasks(d)
    done = set(t["id"] for t in tasks if t.get("status") == "done")
    done |= {t["id"] for t in archived_tasks(d)}

    if getattr(args, "waves", False):
        waves, placed, remaining, live_status = _compute_waves(tasks, done)
        cycle = _find_cycle(remaining)
        for widx, wave in enumerate(waves, 1):
            parts = []
            for t in sorted(wave, key=lambda x: x["id"]):
                tid = t["id"]
                ann = ""
                if widx >= 2:
                    odeps = sorted(dp for dp in csv(t, "depends")
                                   if dp in placed and placed[dp] < widx)
                    natural = 1 + max([placed[dp] for dp in odeps], default=0)
                    if widx > natural:
                        ann = " (отложена из-за файлов)"
                    elif odeps:
                        ann = " (после %s)" % ", ".join(odeps)
                parts.append(tid + _risk_suffix(t) + ann)
            print("Волна %d: %s" % (widx, ", ".join(parts)))
        if not waves:
            print("Нет открытых задач для волн.")
        # застрявшие, объяснимые blocked/in_progress/отсутствием
        satisfied = set(done) | set(placed)
        cyc_set = set(cycle) if cycle else set()
        waiting = [t for tid, t in sorted(remaining.items()) if tid not in cyc_set]
        if waiting:
            print("Ждут:")
            for t in waiting:
                print("  %s (%s)" % (t["id"],
                                     _wait_reason(t, satisfied, live_status, remaining)))
        if cycle:
            print("⚠ ЦИКЛ зависимостей: %s" % " -> ".join(cycle))
            sys.exit(1)
        return

    busy = set()
    for t in tasks:
        if t.get("status") == "in_progress":
            busy.update(csv(t, "files"))
    ready = []
    for t in tasks:
        if t.get("status") != "open":
            continue
        if not set(csv(t, "depends")) <= done:
            continue
        if set(csv(t, "files")) & busy:
            continue
        ready.append(t)
    # предупреждение о цикле — и в обычном ready (exit 0)
    _, _, remaining, _ = _compute_waves(tasks, done)
    cycle = _find_cycle(remaining)
    if not ready:
        print("Нет задач, готовых к диспатчу (проверь blocked/depends/пересечения файлов).")
        if cycle:
            print("⚠ ЦИКЛ зависимостей: %s" % " -> ".join(cycle))
        return
    print("Готовы к диспатчу:")
    for t in ready:
        print("  %s%s  %s" % (t["id"], _risk_suffix(t), t.get("title", "")))
    for i in range(len(ready)):
        for j in range(i + 1, len(ready)):
            inter = set(csv(ready[i], "files")) & set(csv(ready[j], "files"))
            if inter:
                print("  ! %s и %s пересекаются по файлам (%s) — параллелить нельзя, выбери одну." % (
                    ready[i]["id"], ready[j]["id"], ", ".join(sorted(inter))))
    if cycle:
        print("⚠ ЦИКЛ зависимостей: %s" % " -> ".join(cycle))


def cmd_verify(args):
    import subprocess
    d = tasks_dir()
    meta, _ = parse_task(find(d, args.id))
    declared = set(csv(meta, "files"))
    branch = args.branch or ("task/%s" % meta["id"])
    allow = tuple(x.strip() for x in (args.allow or "tests/").split(",") if x.strip())
    try:
        out = subprocess.check_output(
            ["git", "diff", "--name-only", "%s...%s" % (args.base, branch)],
            text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as e:
        sys.exit("git diff не удался: %s" % e.output.strip())
    changed = set(l.strip() for l in out.splitlines() if l.strip())
    tprefix = os.path.basename(os.path.abspath(d).rstrip("/")) + "/"
    tasks_touched = sorted(f for f in changed if f.startswith(tprefix))
    # Префикс-матч каталогов (files-запись, оканчивающаяся на "/", покрывает
    # все вложенные файлы) — задача 0021, регрессировало при sync из task.py
    # в 0024, восстановлено в 0028. НЕ ТЕРЯТЬ при sync из task.py (и обратно).
    dir_prefixes = tuple(p for p in declared if p.endswith("/"))

    def covered(f):
        return f in declared or f.startswith(dir_prefixes) if dir_prefixes else f in declared

    undeclared = sorted(f for f in changed
                        if not covered(f) and not f.startswith(tprefix)
                        and not f.startswith(allow))
    missing = sorted(p for p in declared
                     if p not in changed
                     and not (p.endswith("/") and any(f.startswith(p) for f in changed)))
    print("Задача %s, дифф %s...%s" % (meta["id"], args.base, branch))
    print("  изменено файлов: %d; заявлено в спеке: %d" % (len(changed), len(declared)))
    if missing:
        print("  заявлены, но не тронуты: %s" % ", ".join(missing))
    ok = True
    if undeclared:
        ok = False
        print("  ВНЕ СПЕКИ (files): %s" % ", ".join(undeclared))
    if tasks_touched:
        ok = False
        print("  НАРУШЕНИЕ КОНВЕРТА — исполнитель трогал %s: %s" % (tprefix, ", ".join(tasks_touched)))
    print("Вердикт: %s" % ("OK — скоуп соблюдён" if ok else "ПРОВАЛ — вернуть исполнителю или обновить files в спеке"))
    if not ok:
        sys.exit(1)


def cmd_index(args):
    regen_index(tasks_dir())
    print("_INDEX.md перегенерирован.")


def cmd_lock(args):
    d = tasks_dir()
    info = read_lock(d)
    if not args.owner:  # статус
        if info:
            print("Залочен: owner=%s, %s" % (info.get("owner", "?"), lock_age_str(info)))
        else:
            print("Свободен.")
        return
    if multi_on(d):
        sys.exit("ОТКАЗ: включён multi-режим (_MULTI) — эксклюзивный lock несовместим. "
                 "Либо работай через multi-протокол, либо выключи: multi off.")
    if info is None:
        try:
            write_lock(d, args.owner, exclusive=True)
            print("Lock захвачен: owner=%s" % args.owner)
            return
        except FileExistsError:  # гонка — кто-то успел между read и write
            info = read_lock(d) or {}
    if info.get("owner") == args.owner:
        write_lock(d, args.owner, exclusive=False)
        print("Lock уже твой, timestamp обновлён.")
        return
    if args.force:
        print("⚠ Перехват lock у owner=%s (%s) по --force." % (
            info.get("owner", "?"), lock_age_str(info)))
        write_lock(d, args.owner, exclusive=False)
        print("Lock захвачен: owner=%s" % args.owner)
        return
    print("ОТКАЗ: трекер уже залочен: owner=%s, %s." % (
        info.get("owner", "?"), lock_age_str(info)))
    print("Другой оркестратор активен — не запускай конвейер. "
          "Перехват (только с подтверждения пользователя): lock --owner %s --force" % args.owner)
    sys.exit(1)


def cmd_unlock(args):
    d = tasks_dir()
    info = read_lock(d)
    if info is None:
        print("Трекер не залочен.")
        return
    if info.get("owner") != args.owner and not args.force:
        print("ОТКАЗ: lock принадлежит owner=%s (%s), а не %s. "
              "Чужой lock снимай только через --force с подтверждения пользователя." % (
                  info.get("owner", "?"), lock_age_str(info), args.owner or "<не указан>"))
        sys.exit(1)
    os.remove(lock_path(d))
    print("Lock снят (был owner=%s)." % info.get("owner", "?"))


def cmd_multi(args):
    d = tasks_dir()
    p = os.path.join(d, MULTI_NAME)
    if args.action == "on":
        if read_lock(d):
            sys.exit("ОТКАЗ: держится эксклюзивный _LOCK — сними его (unlock), multi-режим и single-lock взаимоисключимы.")
        if not os.path.exists(p):
            with open(p, "w", encoding="utf-8") as f:
                f.write("enabled: %s\n" % datetime.datetime.now().isoformat(timespec="seconds"))
        _schema_write(d, only_if_lower=True)
        with _Mutex(d):
            _sync(d)
        print("Multi-режим ВКЛ. Протокол оркестратора:")
        print("  1. git worktree add ../<repo>-orch-<owner> -b orch/<owner> main")
        print("  2. в worktree: python3 %s/_cli.py sync --adopt" % os.path.basename(d))
        print("  3. взятие задач только через start N --owner <owner>")
        print("  4. merge веток исполнителей: merge-main N (под глобальным mutex)")
    elif args.action == "off":
        if not os.path.exists(p):
            print("Multi-режим и так выключен.")
            return
        with _Mutex(d):
            _sync(d, quiet=True)  # свежий трекер: иначе чужие in_progress не видны
            busy = [t for t in all_tasks(d) if t.get("status") == "in_progress"]
            if busy and not args.force:
                sys.exit("ОТКАЗ: есть in_progress задачи (%s) — заверши оркестраторы или multi off --force." %
                         ", ".join("%s@%s" % (t["id"], t.get("owner", "?")) for t in busy))
            os.remove(p)
            _sync(d, quiet=True)  # разослать выключение остальным worktree
        print("Multi-режим ВЫКЛ. Не забудь закоммитить каталог трекера в main.")
    else:  # status
        print("Multi-режим: %s" % ("ВКЛ" if multi_on(d) else "выкл"))
        tipr = _git(["rev-parse", "--verify", "-q", "refs/heads/%s" % SYNC_BRANCH], d, check=False)
        if tipr.returncode == 0:
            print("  %s: %s" % (SYNC_BRANCH, tipr.stdout.strip()[:8]))
        bp = _sync_base_path(d)
        if os.path.exists(bp):
            print("  локальная база: %s" % open(bp).read().strip()[:8])
        busy = [t for t in all_tasks(d) if t.get("status") == "in_progress"]
        for t in busy:
            print("  in_progress: %s %s (owner=%s)" % (t["id"], t.get("title", ""), t.get("owner", "—")))
        wt = _git(["worktree", "list"], d, check=False)
        if wt.returncode == 0:
            print("  worktrees:\n    " + "\n    ".join(wt.stdout.strip().splitlines()))


def cmd_sync(args):
    d = tasks_dir()
    with _Mutex(d):
        _sync(d, adopt=args.adopt, prefer=args.prefer)


def _try_find(d, tid):
    """meta задачи tid из живого каталога или archive/, либо None (без sys.exit)."""
    tid = "%04d" % int(tid)
    for base in (d, os.path.join(d, "archive")):
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            if name.startswith(tid + "-") and name.endswith(".md"):
                return parse_task(os.path.join(base, name))[0]
    return None


def _depends_gate(d, tid, base):
    """Ш6: перед merge — все depends задачи tid должны быть done и влиты в base."""
    meta = _try_find(d, tid)
    if meta is None:
        return
    for dep in csv(meta, "depends"):
        dmeta = _try_find(d, dep)
        if dmeta is None:
            print("⚠ зависимость %s задачи %s не найдена в трекере." % (dep, tid))
            continue
        if dmeta.get("status") != "done":
            sys.exit("merge-main: зависимость %s не закрыта — сначала заверши и влей её." % dep)
        dbranch = "task/%04d" % int(dep)
        if _git(["rev-parse", "--verify", "-q", dbranch], d, check=False).returncode == 0:
            in_base = _git(["merge-base", "--is-ancestor", dbranch, base], d, check=False).returncode == 0
            has_integ = _git(["rev-parse", "--verify", "-q", "integration"], d, check=False).returncode == 0
            in_integ = has_integ and _git(
                ["merge-base", "--is-ancestor", dbranch, "integration"], d, check=False).returncode == 0
            # при fallback-потоке dep может быть влит в integration, а не в base — это легально
            if not (in_base or in_integ):
                tgt = "%s (и не в integration)" % base if has_integ else base
                sys.exit("merge-main: зависимость %s закрыта, но ветка %s не влита в %s." % (
                    dep, dbranch, tgt))
        # ветки нет (уже удалена после мержа) → OK


def _sync_integration(d, base):
    """Гарантировать: ветка integration — superset base (main), чтобы финализация
    `git merge --ff-only integration` в дереве base всегда проходила.
    Создаёт integration при отсутствии; выравнивает при отставании/расхождении."""
    if _git(["rev-parse", "--verify", "-q", "integration"], d, check=False).returncode != 0:
        _git(["branch", "integration", base], d)
        return
    # (а) base уже ancestor integration → integration superset, ничего не делаем
    if _git(["merge-base", "--is-ancestor", base, "integration"], d, check=False).returncode == 0:
        return
    old = _git(["rev-parse", "integration"], d).stdout.strip()
    bsha = _git(["rev-parse", base], d).stdout.strip()
    # (б) integration ancestor base → ff integration к base
    if _git(["merge-base", "--is-ancestor", "integration", base], d, check=False).returncode == 0:
        _git(["update-ref", "refs/heads/integration", bsha, old], d)
        return
    # (в) разошлись → влить base в integration тем же merge-tree-механизмом (без checkout)
    r = _git(["merge-tree", "--write-tree", "integration", base], d, check=False)
    if r.returncode != 0:
        sys.exit("merge-main: integration разошлась с %s и авто-синхронизация упала на конфликте.\n"
                 "Разрули: merge-main --branch %s --base integration --resolve, затем повтори." % (base, base))
    tree = r.stdout.strip().splitlines()[0]
    c = _git(["commit-tree", tree, "-p", old, "-p", bsha,
              "-m", "sync integration <- %s" % base], d).stdout.strip()
    _git(["update-ref", "refs/heads/integration", c, old], d)


def _resolve_worktree(d, base, branch, tid):
    """Ш5.2: подготовить временный worktree _merge/NNNN для ручного резолва конфликта."""
    idpart = ("%04d" % int(tid)) if tid else re.sub(r"[^A-Za-z0-9]", "", branch) or "x"
    mbranch = "_merge/%s" % idpart
    repo_top = _git(["rev-parse", "--show-toplevel"], d).stdout.strip()
    wt = os.path.join(os.path.dirname(repo_top), "%s-merge-%s" % (os.path.basename(repo_top), idpart))
    exists_branch = _git(["rev-parse", "--verify", "-q", mbranch], d, check=False).returncode == 0
    exists_wt = os.path.exists(wt)
    if exists_wt or exists_branch:
        print("⚠ worktree/ветка %s уже существуют — переиспользую." % mbranch)
    if not exists_wt:
        if exists_branch:
            _git(["worktree", "add", wt, mbranch], d)
        else:
            _git(["worktree", "add", wt, "-b", mbranch, base], d)
    _git(["merge", "--no-ff", branch], wt, check=False)  # ожидаемо упадёт с конфликтами
    conflicts = _git(["diff", "--name-only", "--diff-filter=U"], wt).stdout.strip()
    print("Площадка резолва: %s (ветка %s)" % (wt, mbranch))
    if conflicts:
        print("Конфликтующие файлы:")
        for f in conflicts.splitlines():
            print("  %s" % f)
    idref = tid if tid else ("--branch " + branch)
    print("Разрули конфликты, git add + git commit, затем: merge-main %s --branch %s" % (idref, mbranch))
    print("После успеха: git worktree remove %s && git branch -D %s" % (wt, mbranch))


def _merge_core(d, base, branch, msg, args, allow_fallback):
    """Ядро merge (под mutex). allow_fallback — можно ли уходить в integration при грязном base."""
    if _git(["rev-parse", "--verify", "-q", base], d, check=False).returncode != 0:
        sys.exit("Базовая ветка %s не найдена." % base)
    if _git(["merge-base", "--is-ancestor", branch, base], d, check=False).returncode == 0:
        print("%s уже влита в %s." % (branch, base))
        return
    r = _git(["merge-tree", "--write-tree", base, branch], d, check=False)
    if r.returncode != 0:
        if getattr(args, "resolve", False):
            _resolve_worktree(d, base, branch, args.id)
            return
        sys.exit("merge-main: КОНФЛИКТ %s <- %s:\n%s\n"
                 "Ребейзни/смержи %s c %s в worktree исполнителя и повтори, "
                 "либо подготовь площадку резолва: merge-main ... --resolve." % (
                     base, branch, r.stdout.strip(), branch, base))
    tree = r.stdout.strip().splitlines()[0]
    mb = _git(["merge-base", base, branch], d).stdout.strip()
    ahead = _git(["rev-list", "--count", "%s..%s" % (mb, base)], d).stdout.strip()
    if ahead != "0":
        print("⚠ %s ушёл вперёд на %s коммит(ов) от точки ветвления %s (чужие merge?). "
              "Если ветка не перетестирована на свежем %s — сначала подтяни его в ветку "
              "и перегони тесты, потом merge-main." % (base, ahead, branch, base))
    # где-то checked out base? тогда мержим там (иначе update-ref рассинхронизирует то дерево)
    wt_path, cur = None, None
    for line in _git(["worktree", "list", "--porcelain"], d).stdout.splitlines():
        if line.startswith("worktree "):
            cur = line[len("worktree "):]
        elif line == "branch refs/heads/%s" % base:
            wt_path = cur
    if wt_path:
        if _git(["status", "--porcelain", "-uno"], wt_path).stdout.strip():
            if allow_fallback and not getattr(args, "no_fallback", False):
                # выровнять integration в superset base — иначе ff-only финализация упадёт
                _sync_integration(d, base)
                _merge_core(d, "integration", branch, msg, args, allow_fallback=False)
                print("main занят (грязное дерево %s) — влито в integration. "
                      "Финализация: git merge --ff-only integration (в дереве main), "
                      "затем ветку integration можно удалить." % wt_path)
                return
            sys.exit("merge-main: %s checked out в %s, но дерево ГРЯЗНОЕ.\n"
                     "Закоммить/спрячь изменения там, дай авто-fallback (без --no-fallback), "
                     "или мержи в общую ветку: merge-main %s --base integration." % (
                         base, wt_path, args.id or "--branch " + branch))
        _git(["merge", "--no-ff", "-m", msg, branch], wt_path)
        print("merged: %s -> %s (в worktree %s)" % (branch, base, wt_path))
    else:
        old = _git(["rev-parse", base], d).stdout.strip()
        bsha = _git(["rev-parse", branch], d).stdout.strip()
        c = _git(["commit-tree", tree, "-p", old, "-p", bsha, "-m", msg], d).stdout.strip()
        _git(["update-ref", "refs/heads/%s" % base, c, old], d)
        print("merged: %s -> %s (%s, без checkout)" % (branch, base, c[:8]))


def cmd_merge_main(args):
    d = tasks_dir()
    base = args.base
    branch = args.branch or ("task/%04d" % int(args.id) if args.id else None)
    if not branch:
        sys.exit("Укажи id задачи или --branch.")
    with _Mutex(d):
        if _git(["rev-parse", "--verify", "-q", branch], d, check=False).returncode != 0:
            sys.exit("Ветка %s не найдена." % branch)
        if args.id and not args.force:
            _depends_gate(d, args.id, base)
        msg = args.message or ("task %s: merge %s" % (args.id, branch) if args.id else "merge %s" % branch)
        _merge_core(d, base, branch, msg, args, allow_fallback=True)


def main():
    ap = argparse.ArgumentParser(description="Мини-трекер задач (руки-агенты)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="создать tasks/ и скопировать CLI в tasks/_cli.py")

    p = sub.add_parser("new", help="новая задача")
    p.add_argument("title", nargs="+")
    p.add_argument("--files", help="затрагиваемые пути, через запятую")
    p.add_argument("--depends", help="ID задач-зависимостей, через запятую")
    p.add_argument("--risk", type=int, choices=[0, 1, 2, 3],
                   help="риск-скор (0 тривиальное .. 3 flash/загрузчик/протокол/безопасность)")

    p = sub.add_parser("list", help="список задач")
    p.add_argument("--status", default="all",
                   choices=list(STATUSES) + ["all"])

    p = sub.add_parser("view", help="показать задачу")
    p.add_argument("id")

    p = sub.add_parser("start", help="взять в работу (status=in_progress); в multi-режиме --owner обязателен")
    p.add_argument("id")
    p.add_argument("--owner", help="метка оркестратора (multi-режим: claim задачи)")

    p = sub.add_parser("block", help="заблокировать")
    p.add_argument("id")
    p.add_argument("--reason")
    p.add_argument("--owner", help="метка оркестратора (multi: чужую задачу — только --force)")
    p.add_argument("--force", action="store_true", help="обойти owner-проверку (только с подтверждения пользователя)")

    p = sub.add_parser("unblock", help="снять блокировку (status=open)")
    p.add_argument("id")
    p.add_argument("--owner", help="метка оркестратора (multi: чужую задачу — только --force)")
    p.add_argument("--force", action="store_true", help="обойти owner-проверку (только с подтверждения пользователя)")

    p = sub.add_parser("close", help="закрыть с приёмкой (status=done)")
    p.add_argument("id")
    p.add_argument("--note", help="текст приёмки")
    p.add_argument("--owner", help="метка оркестратора (multi: чужую задачу — только --force)")
    p.add_argument("--force", action="store_true", help="обойти owner-проверку (только с подтверждения пользователя)")
    p.add_argument("--spent", help='расход, напр. "sonnet(2):34k,haiku(1):6.2k,serena(2):2k" — в скобках число спавнов (для MCP — спавнов с инструментом)')

    p = sub.add_parser("return", help="вернуть задачу исполнителю на доработку (статус остаётся in_progress)")
    p.add_argument("id")
    p.add_argument("--reason", required=True, help="что не так — записывается в ## Возврат и Runs")
    p.add_argument("--owner", help="метка оркестратора (multi: чужую задачу — только --force)")
    p.add_argument("--force", action="store_true", help="обойти owner-проверку (только с подтверждения пользователя)")
    p.add_argument("--spent", help="расход этой итерации (как в close)")

    p = sub.add_parser("stats", help="сводка: статусы, расход по моделям, разложение работа/инициализация")
    p.add_argument("--init", help='переопределить константы из _CONSTANTS.md, напр. "sonnet:12k"')

    p = sub.add_parser("calibrate", help="цены спавна: показать или сохранить в _CONSTANTS.md")
    p.add_argument("--set", help='значения из калибровочных замеров, напр. "sonnet:12k,haiku:4k,serena:8k"')

    p = sub.add_parser("verify", help="сверить дифф ветки с заявленными files (контроль скоупа)")
    p.add_argument("id")
    p.add_argument("--base", default="main", help="базовая ветка (default: main)")
    p.add_argument("--branch", help="ветка задачи (default: task/NNNN)")
    p.add_argument("--allow", help="разрешённые префиксы вне files, через запятую (default: tests/)")

    p = sub.add_parser("ready", help="что можно диспатчить (deps выполнены, файлы свободны)")
    p.add_argument("--waves", action="store_true",
                   help="топосорт open-задач по волнам параллельного диспатча + детект циклов")
    sub.add_parser("index", help="перегенерировать _INDEX.md")

    p = sub.add_parser("lock", help="захватить трекер на сессию оркестратора (_LOCK); без --owner — статус")
    p.add_argument("--owner", help="метка сессии, напр. cc-0704-1512")
    p.add_argument("--force", action="store_true", help="перехватить чужой lock (только с подтверждения пользователя)")

    p = sub.add_parser("unlock", help="снять lock трекера")
    p.add_argument("--owner", help="метка сессии-владельца")
    p.add_argument("--force", action="store_true", help="снять чужой lock (только с подтверждения пользователя)")

    p = sub.add_parser("multi", help="мультиоркестраторный режим: on/off/status")
    p.add_argument("action", choices=["on", "off", "status"])
    p.add_argument("--force", action="store_true", help="off при живых in_progress (только с подтверждения пользователя)")

    p = sub.add_parser("sync", help="синхронизировать трекер с веткой task-sync (multi-режим)")
    p.add_argument("--adopt", action="store_true", help="свежий worktree: заменить локальную копию трекера состоянием ветки")
    p.add_argument("--prefer", choices=["ours", "theirs"], help="разрешение конфликтов (только после ручного разбора)")

    p = sub.add_parser("merge-main", help="влить ветку задачи в main под глобальным mutex (без checkout)")
    p.add_argument("id", nargs="?", help="ID задачи (ветка task/NNNN)")
    p.add_argument("--branch", help="явная ветка вместо task/NNNN")
    p.add_argument("--base", default="main", help="куда вливать (default: main; занят/грязный main — авто-fallback в integration)")
    p.add_argument("--message", help="сообщение merge-коммита")
    p.add_argument("--resolve", action="store_true",
                   help="при конфликте — подготовить временный worktree _merge/NNNN для ручного резолва")
    p.add_argument("--no-fallback", action="store_true",
                   help="грязный main — отказ вместо авто-fallback в integration")
    p.add_argument("--force", action="store_true",
                   help="обойти depends-гейт (только с подтверждения пользователя)")

    p = sub.add_parser("archive", help="сжать done-задачу(и): файл -> archive/, выжимка -> _ARCHIVE.md")
    p.add_argument("id", nargs="?", help="ID одной задачи (взаимоисключимо с --done)")
    p.add_argument("--summary", help="выжимка 2-3 строки (только при одиночном id; иначе авто-fallback из ## Приёмка)")
    p.add_argument("--done", action="store_true", help="архивировать разом все текущие done-задачи (fallback-выжимка)")

    args = ap.parse_args()
    {
        "init": cmd_init, "new": cmd_new, "list": cmd_list, "view": cmd_view,
        "start": cmd_start, "block": cmd_block, "unblock": cmd_unblock,
        "close": cmd_close, "return": cmd_return, "ready": cmd_ready, "index": cmd_index,
        "verify": cmd_verify, "stats": cmd_stats, "calibrate": cmd_calibrate,
        "archive": cmd_archive, "lock": cmd_lock, "unlock": cmd_unlock,
        "multi": cmd_multi, "sync": cmd_sync, "merge-main": cmd_merge_main,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
