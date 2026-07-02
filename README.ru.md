# task — конвейер «оркестратор + руки-агенты»

Skill для Claude Code: декомпозиция работы на задачи в локальном файловом
трекере (`agent_tasks/*.md` + мини-CLI на stdlib-Python) и раздача их кодящим
субагентам. Без GitHub Issues, без внешних зависимостей.

*English version: [README.md](README.md).*

## Что внутри

```
.claude/skills/task/
├── SKILL.md              # сам скилл (канонический текст)
├── DESIGN.md             # журнал проектных решений (почему так)
└── scripts/
    ├── task.py           # мини-CLI трекера (new/list/start/close/verify/ready/stats/calibrate)
    └── sync_rules.py     # генерация правил для Codex (AGENTS.md) и Cursor (.cursor/rules)
```

## Ключевые идеи

- **Оркестратор не пишет код.** Он декомпозирует, диспатчит субагентов
  (haiku-читатели, sonnet-кодеры), принимает работу и двигает статусы.
- **Файл-на-задачу** в `agent_tasks/NNNN-slug.md` с frontmatter
  (status/files/depends/spent) — merge-конфликтов между задачами нет.
- **`_INDEX.md` — генерируемый артефакт**: ориентация по очереди в ~40-50 раз
  дешевле чтения всех спек.
- **4 слоя защиты от коллизий**: `ready` (предотвращение), worktree (изоляция),
  `verify` (контроль скоупа диффа), merge-конфликт (детекция).
- **Анти-фабрикация приёмки**: каждый критерий = ссылка file:test, существование
  проверяется grep-ом, прохождение — реальным прогоном.
- **Учёт токенов**: `close N --spent "sonnet(2):141k,opus(1):59k"`, `stats`
  раскладывает расход на работу и инициализацию спавнов (константы —
  `calibrate --set`), доля инициализации >30% ⇒ задачи слишком мелкие.

## Установка

Claude Code: скопировать `.claude/skills/task/` в корень своего репозитория —
скилл подхватится как `/task`. При первом использовании CLI бутстрапится в
трекер-каталог (`agent_tasks/_cli.py`).

Codex / Cursor (без субагентов):

```sh
python3 .claude/skills/task/scripts/sync_rules.py --repo /path/to/repo
```

— извлечёт инструментонезависимое ядро из SKILL.md в `AGENTS.md` и
`.cursor/rules/task.mdc`.

## CLI

```sh
python3 agent_tasks/_cli.py new "Заголовок" --files a.c,b.h --depends 0001
python3 agent_tasks/_cli.py list|index
python3 agent_tasks/_cli.py start 0002
python3 agent_tasks/_cli.py verify 0002 [--base main] [--allow tests/]
python3 agent_tasks/_cli.py close 0002 --spent "sonnet(1):69k"
python3 agent_tasks/_cli.py ready          # что можно брать без коллизий
python3 agent_tasks/_cli.py stats          # экономика конвейера
python3 agent_tasks/_cli.py calibrate --set "sonnet:23300,opus:18100"
```

Требования: Python 3 (stdlib), git.
