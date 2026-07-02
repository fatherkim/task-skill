# task — orchestrator + coder-subagents pipeline

A Claude Code skill: decompose work into tasks in a local file-based tracker
(`agent_tasks/*.md` + a stdlib-only Python mini-CLI) and dispatch them to
coding subagents. No GitHub Issues, no external dependencies.

*Русская версия: [README.ru.md](README.ru.md). Skill docs (SKILL.md, DESIGN.md)
are in Russian.*

## What's inside

```
.claude/skills/task/
├── SKILL.md              # the skill itself (canonical text)
├── DESIGN.md             # design log (why it is the way it is)
└── scripts/
    ├── task.py           # tracker mini-CLI (new/list/start/close/verify/ready/stats/calibrate)
    └── sync_rules.py     # generates rules for Codex (AGENTS.md) and Cursor (.cursor/rules)
```

## Key ideas

- **The orchestrator writes no code.** It decomposes, dispatches subagents
  (haiku readers, sonnet coders), accepts the work, and moves statuses.
- **One file per task** in `agent_tasks/NNNN-slug.md` with frontmatter
  (status/files/depends/spent) — no merge conflicts between tasks.
- **`_INDEX.md` is a generated artifact**: orienting via the index is ~40-50×
  cheaper than reading all the specs.
- **4 layers of collision protection**: `ready` (prevention), git worktrees
  (isolation), `verify` (diff scope control), merge conflicts (detection).
- **Anti-fabrication acceptance**: every criterion = a file:test link, existence
  is checked with grep, passing is checked by an actual run.
- **Token accounting**: `close N --spent "sonnet(2):141k,opus(1):59k"`; `stats`
  splits the spend into work vs spawn initialization (constants come from
  `calibrate --set`); init share >30% ⇒ tasks are too small.

## Install

Claude Code: copy `.claude/skills/task/` into the root of your repository —
the skill is picked up as `/task`. On first use the CLI bootstraps itself into
the tracker directory (`agent_tasks/_cli.py`).

Codex / Cursor (no subagents):

```sh
python3 .claude/skills/task/scripts/sync_rules.py --repo /path/to/repo
```

— extracts the tool-agnostic core of SKILL.md into `AGENTS.md` and
`.cursor/rules/task.mdc`.

## CLI

```sh
python3 agent_tasks/_cli.py new "Title" --files a.c,b.h --depends 0001
python3 agent_tasks/_cli.py list|index
python3 agent_tasks/_cli.py start 0002
python3 agent_tasks/_cli.py verify 0002 [--base main] [--allow tests/]
python3 agent_tasks/_cli.py close 0002 --spent "sonnet(1):69k"
python3 agent_tasks/_cli.py ready          # what can be taken without collisions
python3 agent_tasks/_cli.py stats          # pipeline economics
python3 agent_tasks/_cli.py calibrate --set "sonnet:23300,opus:18100"
```

Requirements: Python 3 (stdlib only), git.
