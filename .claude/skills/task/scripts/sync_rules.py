#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Генерирует кросс-форматные правила из SKILL.md.

Берёт инструментонезависимое ядро скилла (между маркерами core:start / core:end
в SKILL.md) и раскладывает его в целевой репозиторий:
  - AGENTS.md            — для Codex (блок между маркерами, безопасно обновляется)
  - .cursor/rules/*.mdc  — для Cursor

Claude Code / Claude Desktop / Claude в VS Code читают сам SKILL.md, для них
ничего генерировать не нужно.
"""
import argparse
import os
import re
import sys

MARK_START = "<!-- task:start -->"
MARK_END = "<!-- task:end -->"

PREAMBLE = """## Конвейер «руки-агенты» (локальный трекер задач)

Примечание для инструментов без субагентов (Codex, Cursor): роли оркестратора и
исполнителя выполняются последовательно в одной сессии либо в отдельных
сессиях/вкладках. Конверт исполнителя и все запреты действуют без изменений.
Модели выбираются в интерфейсе самого инструмента.
"""


def main():
    ap = argparse.ArgumentParser(description="Синхронизация правил для Codex/Cursor")
    ap.add_argument("--repo", default=".", help="корень целевого репозитория (по умолчанию cwd)")
    args = ap.parse_args()

    skill_md = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "SKILL.md")
    with open(skill_md, encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"<!-- core:start -->(.*?)<!-- core:end -->", text, re.S)
    if not m:
        sys.exit("В SKILL.md не найдены маркеры core:start / core:end")
    core = m.group(1).strip()
    block = "%s\n%s\n%s\n%s" % (MARK_START, PREAMBLE, core, MARK_END)

    # --- AGENTS.md (Codex) ---
    agents = os.path.join(args.repo, "AGENTS.md")
    if os.path.exists(agents):
        with open(agents, encoding="utf-8") as f:
            old = f.read()
        if MARK_START in old and MARK_END in old:
            new = re.sub(re.escape(MARK_START) + r".*?" + re.escape(MARK_END),
                         lambda _: block, old, flags=re.S)
        else:
            new = old.rstrip() + "\n\n" + block + "\n"
    else:
        new = block + "\n"
    with open(agents, "w", encoding="utf-8") as f:
        f.write(new)

    # --- .cursor/rules (Cursor) ---
    rules_dir = os.path.join(args.repo, ".cursor", "rules")
    os.makedirs(rules_dir, exist_ok=True)
    mdc_path = os.path.join(rules_dir, "task.mdc")
    mdc = ("---\n"
           "description: Конвейер «руки-агенты» с локальным трекером задач в tasks/. Применять при декомпозиции работы, ведении задач, диспатче исполнителей.\n"
           "alwaysApply: false\n"
           "---\n\n" + PREAMBLE + "\n" + core + "\n")
    with open(mdc_path, "w", encoding="utf-8") as f:
        f.write(mdc)

    print("Обновлено: %s" % agents)
    print("Создано:   %s" % mdc_path)


if __name__ == "__main__":
    main()
