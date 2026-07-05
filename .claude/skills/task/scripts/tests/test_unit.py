#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Юнит-тесты чистых функций каноника (stdlib unittest, без pytest — И1).

Запуск: TASK_PY=/path/to/task.py python3 test_unit.py
Каркас волны 1: таблица кейсов paths_conflict (Ш1). Дописывать сюда
parse/render round-trip, _parse_spent, _compute_waves и т.п. — по Ш9.
"""
import importlib.util
import os
import unittest

_TASK_PY = os.environ.get("TASK_PY") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "task.py")
_spec = importlib.util.spec_from_file_location("taskcli", _TASK_PY)
tc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tc)


class PathsConflict(unittest.TestCase):
    # (a, b, ожидаемый конфликт) — таблица из Ш1
    CASES = [
        ("src/", "src/foo.c", True),        # каталог покрывает файл
        ("src/foo.c", "src/", True),        # симметрично
        ("./src//a.c", "src/a.c", True),    # нормализация -> один путь
        ("src/a.c", "src/a.c", True),       # равенство
        ("src/", "src/", True),             # каталог сам с собой
        ("a/b/", "a/b/c/d.c", True),        # вложенный каталог
        ("docs/wiki/", "docs/wiki/x.md", True),
        ("./src/a.c", "src/a.c", True),     # снятие ./-префикса, прежний кейс не сломать
        ("src/foo.c", "src/foobar.c", False),  # префикс без границы /
        ("src/", "srcx/y.c", False),           # граница по /
        ("a/b.c", "a/bc.d", False),
        (".env", "env/", False),            # ведущая точка скрытого файла != ./-префикс
        (".claude/x", "claude/x", False),   # то же: .claude/ не срезается в claude/
    ]

    def test_table(self):
        for a, b, want in self.CASES:
            self.assertEqual(tc.paths_conflict(a, b), want, "%s vs %s" % (a, b))

    def test_norm(self):
        self.assertEqual(tc._norm_path("./src//foo.c"), "src/foo.c")
        self.assertEqual(tc._norm_path("./src/a.c"), "src/a.c")
        self.assertEqual(tc._norm_path("src/"), "src/")
        self.assertEqual(tc._norm_path(" src/a.c "), "src/a.c")
        self.assertEqual(tc._norm_path(".env"), ".env")        # точка скрытого файла цела
        self.assertEqual(tc._norm_path("...foo"), "...foo")    # ведущие точки не срезаются

    def test_filesets(self):
        self.assertTrue(tc.filesets_conflict(["src/"], ["x", "src/a.c"]))
        self.assertFalse(tc.filesets_conflict(["a.c"], ["b.c"]))
        self.assertFalse(tc.filesets_conflict([], ["src/"]))  # пустой набор ни с чем


if __name__ == "__main__":
    unittest.main()
