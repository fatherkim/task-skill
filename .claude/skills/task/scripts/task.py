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


def write_task(path, meta, body):
    lines = ["---"]
    for k in ("id", "status", "title", "files", "depends", "created", "spent", "spawns"):
        if k in meta:
            lines.append("%s: %s" % (k, meta[k]))
    lines.append("---")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n\n" + body.lstrip("\n"))


def all_tasks(d):
    items = []
    for name in sorted(os.listdir(d)):
        if re.match(r"^\d{4}-.*\.md$", name):
            meta, _ = parse_task(os.path.join(d, name))
            items.append(meta)
    return items


def csv(meta, key):
    return [x.strip() for x in meta.get(key, "").split(",") if x.strip()]


def find(d, tid):
    tid = "%04d" % int(tid)
    for name in sorted(os.listdir(d)):
        if name.startswith(tid + "-") and name.endswith(".md"):
            return os.path.join(d, name)
    sys.exit("Задача %s не найдена." % tid)


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
    regen_index(d)
    print("Готово: %s" % d)
    print('Дальше: python3 tasks/_cli.py new "Название задачи" --files src/a.py,src/b.py')


def cmd_new(args):
    d = tasks_dir()
    ids = [int(t["id"]) for t in all_tasks(d) if t.get("id", "").isdigit()]
    nid = "%04d" % (max(ids) + 1 if ids else 1)
    title = " ".join(args.title).strip()
    path = os.path.join(d, "%s-%s.md" % (nid, slugify(title)))
    meta = {
        "id": nid, "status": "open", "title": title,
        "files": args.files or "", "depends": args.depends or "",
        "created": datetime.date.today().isoformat(),
    }
    write_task(path, meta, TEMPLATE)
    regen_index(d)
    print("Создана задача %s: %s" % (nid, os.path.relpath(path)))
    print("Заполни спеку в теле файла (секции Задача / Контекст / Критерии приёмки / Вне скоупа).")


def cmd_list(args):
    d = tasks_dir()
    tasks = sorted(all_tasks(d),
                   key=lambda t: (STATUS_ORDER.get(t.get("status"), 9), t.get("id", "")))
    if args.status != "all":
        tasks = [t for t in tasks if t.get("status") == args.status]
    print("\n".join(table(tasks)))


def cmd_view(args):
    d = tasks_dir()
    with open(find(d, args.id), encoding="utf-8") as f:
        print(f.read())


def _set_status(tid, status, append=None):
    d = tasks_dir()
    path = find(d, tid)
    meta, body = parse_task(path)
    meta.pop("_path", None)
    meta["status"] = status
    if append:
        body = body.rstrip() + "\n\n" + append + "\n"
    write_task(path, meta, body)
    regen_index(d)
    print("%s -> %s" % (meta.get("id"), status))


def cmd_start(args):
    _set_status(args.id, "in_progress")


def cmd_block(args):
    note = "## Блокировка (%s)\n%s" % (datetime.date.today().isoformat(),
                                       args.reason or "<причина не указана>")
    _set_status(args.id, "blocked", append=note)


def cmd_unblock(args):
    _set_status(args.id, "open")


def cmd_close(args):
    note = "## Приёмка (%s)\n%s" % (datetime.date.today().isoformat(),
                                    args.note or "Критерии приёмки выполнены.")
    d = tasks_dir()
    path = find(d, args.id)
    meta, body = parse_task(path)
    meta.pop("_path", None)
    meta["status"] = "done"
    if args.spent:
        meta["spent"] = args.spent
    write_task(path, meta, body.rstrip() + "\n\n" + note + "\n")
    regen_index(d)
    print("%s -> done" % meta.get("id"))


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
    path = os.path.join(d, CONSTANTS_FILE)
    if args.set:
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


def cmd_stats(args):
    d = tasks_dir()
    tasks = all_tasks(d)
    by_status = {}
    by_model = {}
    spawns = {}
    tracked = 0
    for t in tasks:
        by_status[t.get("status", "?")] = by_status.get(t.get("status", "?"), 0) + 1
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
    print("Задач: %d  (%s)" % (len(tasks),
          ", ".join("%s: %d" % kv for kv in sorted(by_status.items()))))
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
        if full:
            print("Ориентация по индексу vs чтение всех спек: %s vs %s байт (x%.1f)" % (
                "{:,}".format(idx_size), "{:,}".format(full), full / max(idx_size, 1)))


def cmd_ready(args):
    d = tasks_dir()
    tasks = all_tasks(d)
    done = set(t["id"] for t in tasks if t.get("status") == "done")
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
    if not ready:
        print("Нет задач, готовых к диспатчу (проверь blocked/depends/пересечения файлов).")
        return
    print("Готовы к диспатчу:")
    for t in ready:
        print("  %s  %s" % (t["id"], t.get("title", "")))
    for i in range(len(ready)):
        for j in range(i + 1, len(ready)):
            inter = set(csv(ready[i], "files")) & set(csv(ready[j], "files"))
            if inter:
                print("  ! %s и %s пересекаются по файлам (%s) — параллелить нельзя, выбери одну." % (
                    ready[i]["id"], ready[j]["id"], ", ".join(sorted(inter))))


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
    undeclared = sorted(f for f in changed - declared
                        if not f.startswith(tprefix) and not f.startswith(allow))
    missing = sorted(declared - changed)
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


def main():
    ap = argparse.ArgumentParser(description="Мини-трекер задач (руки-агенты)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="создать tasks/ и скопировать CLI в tasks/_cli.py")

    p = sub.add_parser("new", help="новая задача")
    p.add_argument("title", nargs="+")
    p.add_argument("--files", help="затрагиваемые пути, через запятую")
    p.add_argument("--depends", help="ID задач-зависимостей, через запятую")

    p = sub.add_parser("list", help="список задач")
    p.add_argument("--status", default="all",
                   choices=list(STATUSES) + ["all"])

    p = sub.add_parser("view", help="показать задачу")
    p.add_argument("id")

    p = sub.add_parser("start", help="взять в работу (status=in_progress)")
    p.add_argument("id")

    p = sub.add_parser("block", help="заблокировать")
    p.add_argument("id")
    p.add_argument("--reason")

    p = sub.add_parser("unblock", help="снять блокировку (status=open)")
    p.add_argument("id")

    p = sub.add_parser("close", help="закрыть с приёмкой (status=done)")
    p.add_argument("id")
    p.add_argument("--note", help="текст приёмки")
    p.add_argument("--spent", help='расход, напр. "sonnet(2):34k,haiku(1):6.2k,serena(2):2k" — в скобках число спавнов (для MCP — спавнов с инструментом)')

    p = sub.add_parser("stats", help="сводка: статусы, расход по моделям, разложение работа/инициализация")
    p.add_argument("--init", help='переопределить константы из _CONSTANTS.md, напр. "sonnet:12k"')

    p = sub.add_parser("calibrate", help="цены спавна: показать или сохранить в _CONSTANTS.md")
    p.add_argument("--set", help='значения из калибровочных замеров, напр. "sonnet:12k,haiku:4k,serena:8k"')

    p = sub.add_parser("verify", help="сверить дифф ветки с заявленными files (контроль скоупа)")
    p.add_argument("id")
    p.add_argument("--base", default="main", help="базовая ветка (default: main)")
    p.add_argument("--branch", help="ветка задачи (default: task/NNNN)")
    p.add_argument("--allow", help="разрешённые префиксы вне files, через запятую (default: tests/)")

    sub.add_parser("ready", help="что можно диспатчить (deps выполнены, файлы свободны)")
    sub.add_parser("index", help="перегенерировать _INDEX.md")

    args = ap.parse_args()
    {
        "init": cmd_init, "new": cmd_new, "list": cmd_list, "view": cmd_view,
        "start": cmd_start, "block": cmd_block, "unblock": cmd_unblock,
        "close": cmd_close, "ready": cmd_ready, "index": cmd_index,
        "verify": cmd_verify, "stats": cmd_stats, "calibrate": cmd_calibrate,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
