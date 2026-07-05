#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Генерирует кросс-форматные правила из SKILL.md.

Берёт инструментонезависимое ядро скилла (между маркерами core:start / core:end
в SKILL.md) и раскладывает его в целевой репозиторий. Два источника:
  - .claude/skills/task/SKILL.md        — базовый /task
  - .claude/skills/task-multi/SKILL.md  — надстройка /task-multi (Ф11, задача 0064)

Каждый источник пишет свой блок в AGENTS.md (Codex) и свой файл в
.cursor/rules/ (Cursor):
  - AGENTS.md            — блок task:start/end (базовый) + блок
                            task-multi:start/end (multi-режим), оба обновляются
                            независимо, безопасно перезаписываются
  - .cursor/rules/task.mdc        — базовый /task
  - .cursor/rules/task-multi.mdc  — /task-multi

Claude Code / Claude Desktop / Claude в VS Code читают сами SKILL.md, для них
ничего генерировать не нужно.
"""
import argparse
import os
import re
import sys

MARK_START = "<!-- task:start -->"
MARK_END = "<!-- task:end -->"
MARK_START2 = "<!-- task-multi:start -->"
MARK_END2 = "<!-- task-multi:end -->"

PREAMBLE = """## Конвейер «руки-агенты» (локальный трекер задач)

Примечание для инструментов без субагентов (Codex, Cursor): роли оркестратора и
исполнителя выполняются последовательно в одной сессии либо в отдельных
сессиях/вкладках. Конверт исполнителя и все запреты действуют без изменений.
Модели выбираются в интерфейсе самого инструмента.
"""

# Ф11 (задача 0064): преамбула второго блока — дословно из спеки
# docs/impl_spec_task_features_2026-07-05.md, раздел Ф11.2.
PREAMBLE_MULTI = """## Конвейер «руки-агенты»: мультиоркестраторный режим (task-multi)

multi-режим требует git worktree + POSIX flock; в средах без них — использовать
только базовый /task.
"""


def _extract_core(skill_md_path):
    """Ш8.3 (волна 1) / Ф11.3 (волна 2): единый guard пустого core-блока —
    общий для обоих источников (task/SKILL.md и task-multi/SKILL.md)."""
    with open(skill_md_path, encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"<!-- core:start -->(.*?)<!-- core:end -->", text, re.S)
    if not m:
        sys.exit("В %s не найдены маркеры core:start / core:end" % skill_md_path)
    core = m.group(1).strip()
    if not core:
        sys.exit("core-блок пуст — проверь маркеры в %s" % skill_md_path)
    return core


def _update_marked_block(path, mark_start, mark_end, block):
    """Заменить (или дописать) блок между mark_start/mark_end в файле path.
    Идемпотентно: повторный вызов с тем же block не меняет остальной файл."""
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            old = f.read()
        if mark_start in old and mark_end in old:
            new = re.sub(re.escape(mark_start) + r".*?" + re.escape(mark_end),
                         lambda _: block, old, flags=re.S)
        else:
            new = old.rstrip() + "\n\n" + block + "\n"
    else:
        new = block + "\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)


def main():
    ap = argparse.ArgumentParser(description="Синхронизация правил для Codex/Cursor")
    ap.add_argument("--repo", default=".", help="корень целевого репозитория (по умолчанию cwd)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    skill_md = os.path.join(here, "..", "SKILL.md")
    core = _extract_core(skill_md)
    block = "%s\n%s\n%s\n%s" % (MARK_START, PREAMBLE, core, MARK_END)

    # Ф11 (задача 0064): второй источник — task-multi/SKILL.md.
    skill_md_multi = os.path.join(here, "..", "..", "task-multi", "SKILL.md")
    core2 = _extract_core(skill_md_multi)
    block2 = "%s\n%s\n%s\n%s" % (MARK_START2, PREAMBLE_MULTI, core2, MARK_END2)

    # --- AGENTS.md (Codex) — оба блока, каждый обновляется независимо ---
    agents = os.path.join(args.repo, "AGENTS.md")
    _update_marked_block(agents, MARK_START, MARK_END, block)
    _update_marked_block(agents, MARK_START2, MARK_END2, block2)

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

    mdc_path2 = os.path.join(rules_dir, "task-multi.mdc")
    mdc2 = ("---\n"
            "description: Мультиоркестраторный режим конвейера «руки-агенты» — несколько оркестраторов на одном репозитории через git worktree + служебную ветку task-sync. Применять при параллельной работе нескольких оркестраторов над одним репозиторием.\n"
            "alwaysApply: false\n"
            "---\n\n" + PREAMBLE_MULTI + "\n" + core2 + "\n")
    with open(mdc_path2, "w", encoding="utf-8") as f:
        f.write(mdc2)

    print("Обновлено: %s" % agents)
    print("Создано:   %s" % mdc_path)
    print("Создано:   %s" % mdc_path2)


if __name__ == "__main__":
    main()
