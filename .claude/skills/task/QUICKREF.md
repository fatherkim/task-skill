# QUICKREF — шпаргалка /task и /task-multi

Аддитивный файл (D1): полная семантика — в `SKILL.md` (single) и `../task-multi/SKILL.md`
(multi), эту страницу они не заменяют. Здесь — только последовательность команд
и топ-5 ошибок для быстрого старта. `<tracker>` = каталог трекера (обычно `tasks/`,
в этом репозитории — `agent_tasks/`).

## Цикл single (один оркестратор)

```
lock --owner <метка>                         # предохранитель от второго оркестратора
new "Заголовок" --files a.py --risk N        # декомпозиция, задача на файл
ready [--waves]                              # что можно диспатчить прямо сейчас
start N                                       # взять в работу
git commit                                    # закоммить <tracker>/ ДО создания worktree/ветки —
                                               # иначе исполнитель не увидит спеку (Ф10 warning)
{dispatch}                                    # конверт исполнителю → путь к файлу задачи
verify N [--base main] [--check-wiring]      # детерминированный контроль скоупа
close N --note "..." [--spent "..."]         # приёмка; или return N --reason "..." на доработку
git merge task/NNNN                           # слить ветку задачи
git commit                                    # закоммить <tracker>/ после close: "task NNNN: приёмка"
unlock --owner <метка>                        # в конце сессии
```

`doctor` — health-check трекера в любой момент цикла (read-only, безопасен всегда).

## 6 шагов multi (несколько оркестраторов)

1. **Вход.** `multi status` → `multi on` (если ещё не включён) → свой worktree
   (`git worktree add ../<repo>-orch-<owner> -b orch/<owner> main`) → `sync --adopt`.
2. **Декомпозиция/планирование.** Как в single: `new`, `ready` (сами синхронизируются,
   видят чужие claim'ы).
3. **Взятие задачи.** Только `start N --owner <owner>` — без `--owner` в multi отказ.
4. **Диспатч исполнителей.** Worktree исполнителя ветвится от worktree оркестратора
   (`orch/<owner>`, не от `main`); конверт — абсолютный путь к спеке.
5. **Приёмка.** `verify N --base main`, слияние — только `merge-main N` (не ручной
   `git merge`): грязный main → авто-fallback в `integration`; конфликт → `--resolve`;
   depends-гейт проверяет, что зависимости done И влиты в base.
6. **Выход / финализация.** Закрыть свои задачи, убрать worktree исполнителей;
   последний оркестратор по команде пользователя — влить `integration` в `main`
   (`merge-main --finalize-integration` или вручную `ff-only` + `multi off`).

## Топ-5 ошибок

1. **Диспатч с незакоммиченным `<tracker>/`.** Worktree исполнителя ответвляется от
   HEAD — незакоммиченная спека ему не видна. `start N` в single предупреждает
   об этом сам (Ф10), если `<tracker>/` грязный.
2. **Мутация под чужим `_LOCK` / без `--owner` в multi.** Trекер отвергает (exit 1),
   не просто предупреждает. → `RECOVERY.md#lock`.
3. **Паника на `sync: конфликт — обе стороны меняли`.** Не редактировать руками —
   сначала посмотреть обе версии (`git show task-sync:<файл>` vs локальная), потом
   `sync --prefer`. → `RECOVERY.md#sync-conflict`.
4. **Ручной `git merge` вместо `merge-main` при грязном main.** `merge-main` сам
   уходит в `integration` (авто-fallback) — ручной merge не подчиняется mutex и
   гонится с другими оркестраторами. → `RECOVERY.md#dirty-main`.
5. **`git worktree remove` без `--force` падает на артефактах** (`__pycache__` и
   т.п., оставленных исполнителем). → `RECOVERY.md#worktree-remove`.

Полные рецепты — `RECOVERY.md`; протокол multi целиком — `../task-multi/SKILL.md`;
почему так спроектировано — `DESIGN.md`.
