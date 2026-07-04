# task — orchestrator + coder-subagents pipeline

A Claude Code skill: decompose work into tasks in a local file-based tracker
(`agent_tasks/*.md` + a stdlib-only Python mini-CLI) and dispatch them to
coding subagents. No GitHub Issues, no external dependencies.

*Русская версия: [README.ru.md](README.ru.md). Skill docs (SKILL.md, DESIGN.md)
are in Russian.*

## What's new (2026-07-04)

- **`/task-multi` skill** — multiple orchestrators in parallel on one repository:
  each in its own git worktree, shared tracker via a service branch `task-sync`
  (checkout-less 3-way merge), global flock mutex, owner+worktree guard, atomic
  `new` (a task is born as a commit on the branch), mutex-guarded `merge-main`
  with auto-fallback to `integration` and a `--resolve` worktree for conflicts.
- **Base CLI upgrade** (after a code-level survey of Backlog.md/GNAP/taskplane etc. —
  see `analysis_task_competitors_2026-07-04.md`): `return` + `## Runs` attempt log
  + circuit breaker (3 returns = stop), `ready --waves` (parallel dispatch waves +
  dependency cycle detection), `new --risk 0..3` mapped to review depth, `_SCHEMA`
  tracker version gate, autonomy levels, a hard ban on nested subagent spawning
  in the envelopes. Docs are in Russian: `update_task_multi_2026-07-04.md`,
  spec `impl_spec_task_upgrade_2026-07-04.md`.

## What's inside

```
.claude/skills/task/
├── SKILL.md              # the skill itself (canonical text)
├── DESIGN.md             # design log (why it is the way it is)
└── scripts/
    ├── task.py           # tracker mini-CLI (new/list/start/close/verify/ready/stats/calibrate/archive)
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
- **Archival compaction**: closed tasks compact into `_ARCHIVE.md` digests —
  orientation cost doesn't grow with history.

## Design decisions (from DESIGN.md)

Why this shape and not the obvious alternatives:

- **One file per task + a mini-CLI** — not a single BACKLOG.md, not SQLite, not
  an off-the-shelf tracker. One file = no conflicts under parallel work;
  markdown = human-readable diffs and specs you can edit as text; a stdlib-only
  CLI runs everywhere. On `init` the CLI copies itself into the tracker dir
  (`agent_tasks/_cli.py`) — the project is self-contained, every tool calls the
  same script.
- **Only the orchestrator mutates the tracker dir** (executors are forbidden),
  and **statuses change only through the CLI** (`open → in_progress → done`,
  plus `blocked`) — that's what keeps the generated index conflict-free and in
  sync by construction.
- **`ready` encodes scheduling deterministically**: dependencies done AND
  declared `files` don't intersect any in-progress task; it also warns about
  intersections among ready tasks. The weak link is completeness of `files` —
  fill it via impact analysis.
- **Execution mode**: the user's directive ("parallel"/"sequential") has top
  priority; the default is sequential. Parallel ⇒ git worktrees are mandatory
  even for two agents — branches isolate history, NOT the working directory
  (a shared dir means mixed edits and a race for the git index). Sequential ⇒
  main tree, branch `task/NNNN`. A branch per task is always required: `verify`
  and rollback hang off it. The directive never overrides safety: tasks with
  intersecting `files` run sequentially regardless.
- **`verify` is deterministic scope control** (`git diff main...task/NNNN`
  against declared `files`): it catches edits outside the spec and touches to
  the tracker dir. It exists because envelope prohibitions are instructions,
  not mechanisms. The `tests/` prefix is allowed by default (`--allow` is
  configurable).
- **Model defaults live in the skill text** (haiku for reading / sonnet for
  code), overridable per invocation. A config file was consciously rejected as
  an extra entity.

## Rules born from incidents

Each of these came from an actual failure during battle-testing, not from
speculation:

1. **Commit the tracker dir BEFORE creating a worktree** — a worktree branches
   from HEAD; an uncommitted spec is invisible to the executor.
2. **`git worktree remove --force`** — plain remove fails on test artifacts
   (`__pycache__` etc.); a `.gitignore` is mandatory.
3. **Anti-fabrication acceptance** — an executor twice reported tests that
   didn't exist or were never run. Hence: every criterion is a file:test link,
   existence is grep-checked, passing is verified by an actual run. A claimed
   but missing test = the task goes back.
4. **All executor work must be committed before reporting** — uncommitted work
   doesn't exist for `verify`/merge. The orchestrator commits the tracker dir
   after every `close` — its git history is the pipeline journal.
5. **Symbol-level tooling (e.g. Serena MCP) activates on the worktree's own
   path**, not the main tree's.
6. **MCP tools proportionally, not ritually** — tools cost context on every
   spawn; small edits go through plain edit. The orchestrator prescribes
   tooling in the spec **with a reason** ("Serena not needed: small files" /
   "edits via Serena: rename with 40+ references"), and the executor reports
   whether it was used and why — accumulated reasons calibrate this very rule.
7. **Wiring rule** — twice in one day an executor shipped a module with a new
   API without hooking it into the main loop ("deferred wire, trivial
   follow-up"): green unit tests, dead feature in firmware. Root cause was the
   decomposition: `files` didn't include the integration point. Hence: the
   consumer goes into `files`, e2e observability goes into the criteria.
8. **Shared-resource rule** — a parallel-wave executor grabbed a namespace
   already claimed by a sibling task with the opposite factory-reset semantics;
   `ready` passed it — the files didn't intersect. Hence: pin allocations
   (namespaces, key ranges, register addresses) to concrete values in the spec;
   for a parallel wave, a shared allocation map.
9. **Symmetric-cases rule** — the spec flagged a race for one register, the
   executor fixed exactly that one and missed the mirror register with the same
   race (the reviewer disproved it experimentally). An executor fixes the
   letter of the spec — enumerating symmetric cases is the orchestrator's job.
10. **Deletion-sweep rule** — after a component was removed, present-tense
    descriptions of it survived across README and header comments. A task that
    deletes or renames a component includes docs/comments in `files` and a
    repo-wide grep in the criteria; historical "formerly/dropped" mentions are
    fine.

## Review discipline

Borrowed after a review-side analysis of
[alexxety/multi-model-pipeline-skill](https://github.com/alexxety/multi-model-pipeline-skill)
— their strength (independent, adversarial review) was this skill's weak half:

- **Debt from review and reports** — material non-blocking findings (from the
  reviewer or the executor's "Adjacent findings" section) don't die in
  acceptance notes: each one becomes a `new` debt task linked from the note.
  "We'll wire it later" without a tracked task does not exist.
- **Vacuous-pass control** — a green test is not evidence: a new guard test
  must be shown to FAIL without the fix. "Tests are green but the protection
  silently died" is an unconditional return.
- **Reviewer envelope** — review is refutation, not summary: the change is
  framed as a claim to attack, with hunt categories per change type and a
  CONFIRMED (file:line) / NO FINDINGS verdict per category, with an explicit
  not-a-finding list (pre-existing, compiler-caught, spec-mandated changes).
- **Merge review** — the orchestrator's own merge/fixup commits are reviewed
  by a reading subagent, not their author: no single executor ever saw the
  merged result.
- **Hypothesis labeling** — unverified context in a spec is marked as a
  hypothesis ("likely X — verify before relying"), never stated as fact.
- **Executor self-refutation** — before the final report the executor attacks
  its own work: adversarial pass over the acceptance criteria plus a grep for
  old-behavior wording left in comments/docs of touched files.
- **Flag, don't fix** — adjacent problems outside the task scope go into a
  dedicated "Adjacent findings (not fixed)" report section; material ones
  become tracked debt tasks. A spec "fact" that contradicts the live code is
  a blocker, not something to build on.

Considered and deferred: cross-vendor review (Codex read-only vs a
Claude-driven pipeline) — candidate escalation for high-risk tasks.

## Token economics

`--spent "sonnet(2):34k,serena(2):2k"` — parentheses = number of spawns (for
MCP keys: spawns with the tool connected, NOT call counts — the constant is the
price of loading the tools into context). Numbers come only from tool counters;
no counter ⇒ the field is omitted, never invented. We account for what was
*spent*, not what was "saved" (savings are a counterfactual, measurable only
against a baseline).

**Calibration**: a trivial subagent per configuration ⇒ its input tokens = the
spawn constant; an MCP constant = the difference (with − without). Constants
live in `_CONSTANTS.md` next to the tasks, not in the skill folder (after
`init` the CLI doesn't know the skill path; Codex/Cursor don't have one; the
tool set is a property of the project). `stats` then decomposes spend into work
(model-invariant) vs initialization (spawns × constant). If the init share is
consistently >30%, the tasks are too small — coarsen the decomposition. The
estimate ignores prompt caching and differing iteration counts between models.

## Install

Claude Code: copy `.claude/skills/task/` into the root of your repository —
the skill is picked up as `/task`. On first use the CLI bootstraps itself into
the tracker directory (`agent_tasks/_cli.py`).

Codex reads skills natively from `.agents/skills/` — a symlink
`.agents/skills/task → ../../.claude/skills/task` gives a single source of
truth. Fallback path for Codex/Cursor without skill support:

```sh
python3 .claude/skills/task/scripts/sync_rules.py --repo /path/to/repo
```

— extracts the tool-agnostic core of SKILL.md (between `core:start`/`core:end`
markers) into `AGENTS.md` and `.cursor/rules/task.mdc`. In tools without
subagents the orchestrator and executor roles run sequentially in one session
or in separate tabs; the executor envelope and all prohibitions apply
unchanged.

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
python3 agent_tasks/_cli.py archive 0001 --summary "..."  # or `archive --done`
```

Requirements: Python 3 (stdlib only), git.

## Notes and boundaries

- The tracker directory is renameable (`tasks/` → `agent_tasks/`): the CLI is
  anchored to its own location and `verify` derives the prefix dynamically.
  Rename only while paused (no in-progress tasks or worktrees), via `git mv`.
- Task numbering has no ceiling (`\d{4,}`, numeric sort).

## Origin and license

This project started as a port of the `fable-ruki-agenty` skill from
[serejaris/personal-corp-skills](https://github.com/serejaris/personal-corp-skills/),
moving it from GitHub Issues to a local file tracker; requirements were: no
network/gh, and cross-tool support for Claude Code (terminal / VS Code /
Desktop), Codex, and Cursor.

License: [MIT](LICENSE).
