# Анализ конкурентов /task и /task-multi (GitHub, 2026-07-04)

Разобраны по коду (не по README): Backlog.md, GNAP, CCPM, taskplane, agent-orchestrator, parallel-worktrees.
ccswarm не скачан (гигантский Rust-репо, клон убит). Полные отчёты агентов-аналитиков — в scratchpad сессии
(salvage/*.txt + финальные отчёты добора); здесь — синтез.

## Вердикт по каждому

| Репо | Что это | Сильное | Слабое против нас |
|---|---|---|---|
| **Backlog.md** (TS/Bun) | markdown-трекер + CLI/MCP/web | ID-аллокация с учётом соседних worktree+веток, lock на git-common-dir, sequence-волны из DAG, MCP-слой с валидацией | нет owner/claim, нет контроля скоупа (verify), циклы deps не детектит |
| **GNAP** (RFC, кода нет) | git-репо как доска задач | разделение Task vs Run (1:N попытки), version-gate схемы, message-слой | конкуренцию claim'ов НЕ решает (push-retry-rebase), наш flock+owner-guard строго сильнее |
| **CCPM** (bash+prose) | PRD→эпик→задачи→GitHub Issues | шаблоны прогресс-отчётов в issue | параллельность декларативная (`conflicts_with` руками, код не проверяет), N агентов в ОДНОМ worktree эпика, sed вместо CLI |
| **taskplane** (спеки) | волны/дорожки, watchdog, eval-гейты | изолированный merge-worktree, Tier-0 recovery каталог, circuit breakers, risk-score→глубина ревью, PROMPT/STATUS.md как память | TMUX-инфраструктура, тяжёлый рантайм |
| **agent-orchestrator** (Go+Electron) | IDE для N агент-сессий | дедуп нотификаций по сигнатуре (sendOnce), «failed probe ≠ death», blocked-by-parent | нет DAG/очереди задач вообще, SQLite вместо файлов |
| **parallel-worktrees** (bash) | скрипты worktree + промпт-конвенции | честный дисклеймер «~15x токенов» | всё на honor system: статусы добровольные, merge падает на первом конфликте |

Общий вывод: наш стек (frontmatter+CLI+verify+task-sync+flock+owner-guard) закрывает дыры, которые у
большинства оставлены «на совести агента». Уникального «убийцы» не нашлось; есть точечные механизмы для переноса.

## Что переносить (ранжировано)

Колонка «Скилл»: CLI физически общий (один task.py), поэтому «скилл» = где фича активна/даёт пользу.

| # | Механизм | Откуда | Что даёт | Куда | Скилл | Сложность |
|---|---|---|---|---|---|---|
| 1 | **Изолированный merge-worktree**: merge-main при занятом/грязном main-дереве делает временный worktree `_merge-temp`, мержит там, удаляет | taskplane §7.4 | убирает наш отказ «main checked out в грязном дереве» (частый кейс: primary-дерево пользователя всегда грязное) | task-multi CLI | **multi** (merge-main есть только там) | M |
| 2 | **`sequence`-волны из DAG** (Кан): раскладка open-задач на волны параллельно-готовых | Backlog.md sequences.ts | оркестратор раздаёт волну целиком вместо цикла ready→одна; заодно детект циклов deps (у нас его нет!) | task CLI (`ready --waves`) | **оба** (параллельные исполнители есть и в single) | S/M |
| 3 | **Circuit breakers приёмки**: max ревью-раундов на задачу (3), max debt-задач из одного провала (5) → pause/эскалация пользователю | taskplane eval §7.4 | глушит бесконечный пинг-понг исполнитель↔ревьюер | SKILL.md + счётчик в frontmatter | **оба** (приёмка одинаковая) | S |
| 4 | **Run-лог попыток**: append-секция `## Runs` в task-файле (агент, время, исход, spent) — задача ≠ попытка | GNAP Task/Run | история «кто падал на задаче до закрытия», честный spent по попыткам | task CLI (close/return пишут строку) | **оба** | S |
| 5 | **Risk-score → глубина ревью**: поле `risk: 0-3` (blast radius/новизна/security/обратимость) в frontmatter при декомпозиции; 0 — без ревьюера, 3 — полный опровергатель | taskplane review-loop | дешевле на тривиальных, строже на опасных | SKILL.md + frontmatter | **оба** | S |
| 6 | **Дедуп фидбека по сигнатуре**: повторный возврат исполнителю только если сигнатура провала изменилась (hash диффа/лога) | agent-orchestrator sendOnce | не заваливать исполнителя тем же замечанием | SKILL.md (процессно) | **оба** | S |
| 7 | **Schema-version gate**: `tasks/.schema-version`, CLI отказывается писать при незнакомой версии | GNAP version | старый оркестратор не портит трекер после апгрейда схемы | task CLI | **multi** (гл. риск — разноверсионные оркестраторы; single выигрывает побочно: отставший tasks/_cli.py от каноника) | S |
| 8 | **Depends-замержены-гейт в merge-main**: перед эскалацией конфликта проверить, что depends-задачи уже в main | agent-orchestrator blocked-by-parent | конфликт из-за невлитой зависимости ≠ настоящий конфликт | task-multi CLI | **multi** (живёт в merge-main) | S |
| 9 | **Уровни автономии**: Interactive/Supervised/Autonomous как параметр вызова скилла (что можно без вопроса) | taskplane §4.5 | ночные прогоны без присмотра, явная граница деструктива | SKILL.md | **оба** (multi — главный потребитель, но и single-конвейеру полезно) | S |
| 10 | **Дубль-ID → готовый fix-промпт**: при «⚠ ДУБЛЬ id» печатать готовый текст задания на перенумерацию (mv+id+depends+index) | Backlog.md duplicate-detection | самовосстановление вместо ручного разбора | task CLI | **multi** (дубли рождаются только при нескольких оркестраторах; детект сидит в sync) | S |

Уже есть у нас (подтверждено анализом, не брать повторно): lock на git-common-dir (наш mutex там же),
детект дублей id, owner-claim, программный контроль пересечений files, атомарный new, 3-way sync трекера.

## Не брать

- TS/Bun/Go/SQLite/Electron/TMUX/web-UI — конфликт со stdlib-Python + markdown философией.
- Drafts/Decisions/Docs/Milestones как типы сущностей (Backlog.md) — оверинжиниринг для нашего масштаба.
- Message-слой GNAP (агент↔агент чат) — координации через спеки и оркестратора достаточно; вернуться, если появится реальный кейс «директива всем».
- GitHub Issues как трекер (CCPM) — противоречит локальности.
- Multi-branch fetch+hydrate ID-неймспейса (Backlog.md) — наш task-sync решает то же явно и дешевле.
