# claude-supervisor

[中文文档](README-zh.md) | English (this file)

When doing real work with Claude Code, the most expensive thing isn't tokens — it's your time at the keyboard: workers stall and need you to type "continue", rate limits hit and you wait them out, and every finished chunk needs your personal review before the next one starts. This toolkit removes the night shift: one Supervisor session manages N Worker sessions. You write the goal, answer the upfront requirement questions, and walk away — you only get notified when a decision needs your call.

What lets you walk away:

- **Rate-limit self-healing, no more typing "continue"**: the instant a worker gets cut off by a 429, a hook (an event callback, not a prompt instruction) reports the interruption straight to the supervisor, which backs off, wakes workers in a staggered manner, and resumes from the interruption point.
- **Automatic phase-to-phase flow**: when a worker finishes, it self-reviews first, then submits to adversarial review by the supervisor; approved, the next phase's instructions are issued automatically; rejected, it goes back with a numbered issue list. You only get escalated to when things get stuck.
- **Crashes resume, never restart from zero**: all progress is persisted in sharded ledgers under `.supervisor/`; a crashed worker or supervisor realigns with the ledger and carries on. "Back to square one overnight" is not an outcome this design allows.
- **Someone watches the watcher**: a watchdog runs from the system crontab, checking every 10 minutes for silent workers and supervisor heartbeats, and pops a desktop notification when thresholds are exceeded.

Five modes are supported:

- **Greenfield** (`/supervisor`, build a new project from scratch).
- **Rework** (`/rework`, patch/refactor an existing project — archaeology baseline + regression safety net + frozen-behaviors list).
- **Research** (`/research`, investigation/exploration tasks — produces reports and evidence, not code changes).
- **Abstract** (`/abstract`, synthesis — distills the high-level propositions that govern a pile of existing material).
- **Adversarial review** (`/adversarial`, review existing output — PR diffs / design docs / research reports — with multiple isolated perspectives, anonymous cross-attack, and a convergent report).

It's a combination of hard-coded safety nets plus a prompt protocol: interruption detection, shard guards, and external watch never depend on the model's own diligence — if the model degrades, the safety nets keep working (worst case shrinks from "never noticed" to "noticed a bit late"). Full motivation and design origins: [WHY_ME.md](WHY_ME.md); design principles, reverse-engineering notes, and the interruption model: [DESIGN.md](DESIGN.md).

## Installation

```bash
# Option 1:
git clone git@github.com:ljheee/claude-supervisor.git && cd claude-supervisor
bash install.sh

# Option 2:
curl -fsSL https://raw.githubusercontent.com/ljheee/claude-supervisor/main/install.sh | sh
# Private fork / self-hosted mirror: override the repo URL with
#   curl -fsSL .../install.sh | sh -s -- <repo-url>
# or SUPERVISOR_REPO_URL=<url> sh ./install.sh
```

What gets installed: five slash commands — `/supervisor`, `/rework`, `/research`, `/abstract`, `/worker` (→ `~/.claude/commands/`; supervisor/rework/research/abstract are spliced at install time from a mode layer + the shared `_core-supervisor.md` core protocol); four hooks (→ `~/.claude/hooks/claude-supervisor/`, registered into `~/.claude/settings.json` at user level, idempotent) — StopFailure (auto-report of interrupted workers), SessionStart (v3 identity injector), PreToolUse·Write|Edit (v3 shard guard), Stop (model-layer anomaly capture: model-error / empty turns / tail degradation); plus registry.py and the watchdog (→ `~/.claude/supervisor/`; all registry.json writes go through the former). Existing files are backed up before being overwritten; an unreadable settings.json **aborts the install** after backup — your config is never silently reset; spliced commands must pass structural assertions, and a failure aborts the install with no half-written output.

Requirements: Claude Code >= 2.1.259 (ListAgents + SendMessage + StopFailure hook + CronCreate/ScheduleWakeup scheduled tasks). Verify with `claude --version`. Desktop notifications use osascript and currently work on macOS only (everything else is cross-platform).

## Quick Start (multi-terminal)

```bash
# Terminal A: project directory, initialize the supervisor
# (recommended: /rename supervisor first to fix the session name)
claude
> /rename supervisor
> /supervisor build a XXX feature

# Terminal B: same project directory, register a worker
cd /path/to/repo && claude
> /worker

# Terminals C, D, ...: open more workers; multiple workers run in
# parallel under supervision (each with its own isolated scope)
```

After that, you only talk to the supervisor session (progress queries, requirement answers all happen in its terminal); workers execute, self-review, and report. The supervisor identifies each worker by session_id (self-reported at registration plus a cross-check scan by the supervisor — same-name or renamed workers never cross wires). You don't manage any of that.

## Patching / Refactoring an Existing Project (rework mode)

Have existing code to change? Use `/rework` instead of `/supervisor`, same posture:

```bash
# Terminal A: the legacy project directory (must be a git repo)
claude
> /rework fix the YY problem in module XX --baseline <commit-where-behavior-was-correct>

# Terminal B: same project directory
claude
> /worker
```

The rework front phases are "archaeology & baseline → regression safety net → spec → plan": first archaeology produces an architecture map, a debt inventory, bug-vs-feature suspicions (workers are forbidden from adjudicating these themselves — default is escalation to you), and the dependency dark-web; then safety-net tests lock in current behavior (including the behavior to be changed — lock the status quo first so pre/post diffs are attributable); the frozen-behaviors list is confirmed and locked by you when the safety net is APPROVEd, and any worker commit touching it afterwards gets REFINEd. Two hard disciplines during development: **scope comparison** (each phase's diff file set must be a subset of the declared scope — zero tolerance for drive-by refactors) and **one phase = one independently revertible unit of change**. `--baseline` defaults to HEAD.

Note: rework mode requires the project to be a git repository (archaeology hard-depends on git history; non-git directories escalate immediately).

## Research / Exploration Tasks (research mode)

Output is a report, not code? Use `/research`, same posture:

```bash
# Terminal A: any directory (non-git works too — research doesn't
# hard-depend on history)
claude
> /research investigate XX technology choice / incident root cause / dependency status --out <report-dir>

# Terminal B: same directory
claude
> /worker
```

The research front phases are "problem definition → survey plan": a fuzzy research goal gets dug into an **acceptable numbered question list** (for each question, what counts as answered must be decidable) plus explicit out-of-scope boundaries; then the survey plan is reviewed (which chapter answers which questions, source list with priorities, time boxes). Three hard disciplines during execution:

- **Five-level evidence grading** (A first-hand testing / B source-code pinpointing / C official docs / D second-hand paraphrase / E explicit speculation — the supervisor spot-checks and reproduces key A-C evidence; one fabricated item re-opens the whole chapter)
- **Product code is read-only** (probes and artifacts go only into the `--out` directory, default `docs/research/<date-topic>/`; any git diff escaping the report directory is a REFINE)
- **Conclusion reconciliation** (before done, every question is checked: either answered with a confidence level, or explicitly marked unresolved with reasons — "couldn't find" must state what was tried and where it got stuck). Each chapter has a default 90-minute time box against unbounded expansion.

Inside a git repo the report follows commit discipline; in non-git directories, writing to disk is delivery.

## Adversarial Review Tasks (adversarial mode)

Already have an output — a PR diff, a design doc, a research report — and want real criticism instead of a single pass that mixes true and false findings? Use `/adversarial`:

```bash
# Terminal A: any directory (non-git works — the reviewed object is
# often documents; a PR just needs a stable ref)
claude
> /adversarial review the completeness of design doc X / PR #123 [--out <report-dir>]

# Terminal B (same directory, one per perspective)
claude
> /worker
```

The design axiom: **adversarialness comes from isolation, not from prompt declarations**. Each reviewer worker holds one perspective in an independent session (workers can't see each other's findings — they travel only in report messages and the supervisor's shard ledger), then attack each other's findings through an anonymized union. Two rounds: round1 (independent solo review, mutually invisible) → cross-1 (each side must respond to every finding from the others: rebut with counter-anchor / confirm / withdraw; a second cross round only if unresolved disputes remain, capped at 2). The supervisor merges into a three-state convergence — "at least two independent perspectives agree" / "one side held after attack-and-defense" / "explicitly withdrawn" — and unresolved items land in the report as *user-adjudication items*, not infinite rounds. Every finding must carry an anchor + confidence + a falsifiability test; the supervisor spot-checks anchors, and systematic fabrication withdraws that perspective's entire findings set.

Worker-count recommendation at assign time (user adjudicates): <300-line single-module diff → 1 (degraded multi-perspective sweep, report marked "not isolated"); mid-size PR / single-topic doc → 2 (implementer + devil's advocate); cross-module / architecture / concurrency-sensitive → 3-4; money-touching / data migration / >2000 lines → 4-6 (over 5000 lines: split the PR first). Workers you name when assigning the task are hard constraints — never trimmed, may exceed the recommendation. The supervisor may also spawn workers as its own background subagents instead of terminals, but only with your explicit approval at assign adjudication (subagents have no session_id — five-layer defense doesn't cover them, and they die with the supervisor session; the protocol compensates by keeping all state in the supervisor's shard ledger). The report has five sections: TL;DR / disputed items (all sides' arguments + anchors, for your adjudication) / withdrawal record / coverage reconciliation (material × perspective matrix) / perspective list.

## Synthesis Tasks (abstract mode)

A pile of existing material (a few reports/articles, a dozen scattered code changes, some verbal context) and you want the high-level structure distilled from it? Use `/abstract`:

```bash
# Terminal A: the directory holding the material (non-git works — input
# is often a documents directory / links to documents)
claude
> /abstract distill the system's root problems from this batch of reports / extract commonality from the last 30 commits [--out <report-dir>]

# Terminal B: same directory
claude
> /worker
```

Abstract is the opposite direction of research: research diverges (from questions out into the world for evidence), abstract converges (from material toward the governing structure) — **the evidence is inside the material, and the input surface is locked** (after the ingest inventory is finalized, no new material may be introduced, including web search and database queries). The front phases are "material inventory → proposition draft": material is inventoried into a reconcilable list (granularity convention: per document / per commit / per diff hunk group), each item compressed with anchors, then the proposition draft is reviewed. Three hard disciplines during execution:

- **Two-part acceptance** (coverage reconciliation — every material item is either explained by a proposition or explicitly marked as a counterexample; back-referencing anchors — `in-material pattern` propositions must carry anchors, `intent/attribution inference` propositions must be explicitly labeled as inference with a derivation chain, preventing speculation from posing as fact)
- **Anchor spot-checks** (the supervisor personally opens anchors to verify propositions against the material; systematic fabrication re-opens the whole refinement round)
- **Empty-talk checks + absence signals** (unfalsifiable correct-sounding platitudes get demoted to observations; things repeatedly absent from the material must enter the checklist — you can't distill "what's missing" by only looking at "what's there").

The supervisor also enforces **narrative discipline**: the one narrative that explains all the material is often the most suspicious one. Each refine round reports immediately and gets adversarially reviewed — not chapter-by-chapter production. Report default location: `docs/abstract/<date-topic>/`.

## The Flow You'll See

```
clarify (requirements clarified; questions relayed to you via the supervisor)
  → spec (worker produces the spec; supervisor reviews; REFINE = numbered issue list)
  → plan (phased plan review; APPROVE locks the total number of phases)
  → dev-1..N (each phase: worker self-CR first → supervisor adds CR → APPROVE advances)
  → done (supervisor delivers the project summary: what was done, quality verdict, residual risks)
```

(This is the greenfield default skeleton; rework/research/abstract modes override the front phases and execution-phase enumeration — see their sections above.)

## What Happens When a Worker Gets Interrupted

| Interruption type | Behavior |
|---|---|
| Round cut off by 429 / network error / API error | The StopFailure hook auto-reports within seconds; the supervisor uses native `ScheduleWakeup` delayed wake with a ~5-minute backoff (staggered across workers), then messages the worker to resume from the interruption point; two wake-ups without response escalate to you |
| Worker hits an environment blocker (tool failure, broken deps) | The worker actively sends WORKER STALLED; the supervisor offers alternatives or escalates to you |
| Process killed / terminal closed | The hook can't run (its subject is gone) — the watchdog/patrol detects the overdue silence and escalates to you with the session_id and `claude --resume` recovery guidance; on resume the worker reports back with WORKER RESUME |

Interruption records persist to `.supervisor/<sid>/interrupts.jsonl` (v3 sharded path, `<sid>` being the supervisor's session_id; the legacy flat layout is auto-compatible); after processing, the supervisor logs to `acknowledged.jsonl` in the same directory; the set difference equals unprocessed interruptions, and every wake-up replays them (nothing gets lost even if the supervisor was offline at the time). The commit-at-every-phase discipline guarantees any interruption loses at most the current phase's uncommitted part.

## How It Stays Alive

What if nobody is watching — does anything go wrong? Three keep-alive mechanisms, all zero-config:

1. **The supervisor self-patrols every 10 minutes** (session-only cron, auto-created at startup, auto-cleaned at wrap-up; if the task expires it gets rebuilt immediately, and any incoming message also triggers a patrol — double insurance). Patrol contents: liveness verdicts, interruption make-up, worker-presence checks (guards against the "worker checks-then-registers vs supervisor registers late" mutual-wait deadlock).
2. **The watchdog watches everyone from the system crontab** (auto-registered at startup, auto-removed at wrap-up): a silent worker past the threshold alerts the supervisor directly; the supervisor's own heartbeat going stale pops a desktop notification to you (with `claude --resume` recovery guidance) — the checker is independent of the checked party's session, so it still fires when the supervisor is dead. Alerts carry gradient de-duplication and never spam.
3. **Everything is on disk**: state, interruption records, and acknowledgments all live under `.supervisor/`; crashed sessions don't lose the ledger, recovery realigns and continues.

Known edge: when the supervisor is stuck in an over-threshold long turn (e.g., running the full test suite itself), the watchdog produces one false DEGRADED (de-duplication caps it at once — ignorable). Mechanism details in DESIGN.md.

Prerequisite: add `.supervisor/` to the project's `.gitignore` (the supervisor proactively asks to append it at startup and does it on your nod — it never just reminds and moves on).

Also: the host's notify_when_idle notices refresh a worker's liveness clock when it goes idle (idle ≠ done, and it's not used as a supervision trigger — the worker protocol is "no report until milestone complete" by design).

## Commands

- `/supervisor <goal> [--project-dir DIR]`: greenfield supervisor (front phases clarify→spec→plan).
- `/rework <change-goal> [--project-dir DIR] [--baseline <git-ref>]`: rework/refactor supervisor (front phases archaeology→safety-net→spec→plan, with the frozen-behaviors list and the drive-by-refactor red line).
- `/research <research-goal> [--project-dir DIR] [--out <report-dir>]`: research/exploration supervisor (front phases scope→survey, one dev unit per chapter; five-level evidence grading + read-only product code + conclusion reconciliation; non-git directories supported).
- `/abstract <synthesis-goal-and-material-source> [--project-dir DIR] [--out <report-dir>]`: synthesis supervisor (front phases ingest→distill, refine-N adversarial rework; coverage reconciliation + back-referencing anchors + anchor spot-checks + empty-talk checks, input surface locked; non-git directories supported).
- `/adversarial <reviewed-object-and-goal> [--project-dir DIR] [--out <report-dir>]`: adversarial-review supervisor (front phases ingest→assign, worker phases round1→cross-1→(cross-2)→done; isolated perspectives + anonymized cross-attack + three-state convergence, anchor discipline + anchor spot-checks; non-git directories supported; terminal workers by default, supervisor-spawned subagents with explicit user approval).
- `/worker [--supervisor <session-name>]`: registers the current session as a supervised worker (mode-agnostic). Includes the reporting protocol and the interruption-recovery protocol. `--supervisor` takes a **session name** (the only addressable key SendMessage accepts; without it the worker reads `.supervisor/registry.json` and picks a supervisor — a single active entry is chosen directly; multiple entries are listed for you to designate).

The five modes share one core protocol (identity / five-layer interruption defense / ledger / OODA / three-layer answer firewall), spliced into each command at install time.

## Multiple Supervisors Coexisting

One project can run multiple supervisors at once (typical: `/supervisor` on a new module + `/rework` on the legacy codebase, in parallel). Isolation rests on three things:

- **Unique session names**: each supervisor fixes a unique name with `/rename` (recommended `supervisor-<mode-or-project-suffix>`, e.g. `supervisor-gf` / `supervisor-rw`; cross-project same-name supervisors can't be disambiguated by SendMessage — project suffixes make names sturdier). Names are message routing keys; collisions cross-wire.
- **Separate branches/worktrees**: multiple supervisors in one repo is a hard requirement — each party works on its own branch or linked worktree (the protocol enforces an isolation confirmation at startup); mixed commits on the same branch are not supported, conflicts escalate to user adjudication.
- **Sharded ledgers**: each run's ledger lives under `.supervisor/<supervisor's session_id>/` (state.json / interrupts.jsonl / acknowledged.jsonl), invisible to one another; the discovery layer is `.supervisor/registry.json` (maintained by registry.py, read-only to workers picking a supervisor at startup). A new run is a new shard; old ledgers automatically become read-only archives.

The legacy flat layout (v2/rework's `.supervisor/state.json`) is recognized on v3 supervisor startup and guided into `.supervisor/archive/` (the archive directory is invisible to hooks/watchdog and can't be mistaken for a live shard).

When a supervisor dies unexpectedly, its registry entry remains: a worker that fails to register with it reports a three-option list to you (resume that supervisor / retry later / switch to autonomous mode); the stale verdict is dual-condition (unreachable AND heartbeat over 30 minutes) and only marks — never deletes — other people's entries.

## FAQ

- **Greenfield vs rework vs research vs abstract vs adversarial**: existing code to change → `/rework` (archaeology + safety net first); from scratch → `/supervisor`; output is a report → `/research` (problem definition + evidence grading, product code untouched); a pile of material to distill → `/abstract` (coverage reconciliation + anchor spot-checks, input surface locked); an existing output to review → `/adversarial` (isolated perspectives + cross-attack + three-state convergence).
- **Worker can't find the supervisor**: run `/rename supervisor` in the supervisor terminal to fix the name, then have the worker retry; also confirm both sides are in the intended directory.
- **Supervisor behavior drifts** (protocol dilution after a long session gets compacted): re-run the mode's command (`/supervisor`, `/rework`, `/research`, `/abstract`, `/adversarial`) to re-inject the protocol; state.json restores the full context.
- **The supervisor isn't 100% reliable (known boundary)**: the supervisor's persona comes from prompt injection; compliance can't be guaranteed. This suite's hedge: interruption-detection triggers (hooks/watchdog) are hard code that doesn't depend on supervisor diligence; progress lives in state.json, so drift is recoverable by re-injection; soft failures (missed patrols, etc.) have their consequences bounded by the hard safety nets to "noticed late" instead of "never noticed". See DESIGN.md section 9.
- **Suspect a hook isn't firing**: run `bash test_stopfailure.sh`, `bash test_watchdog.sh`, and `bash test_registry.sh` (assertion-based sandboxed tests, no real data touched); after a real interruption, check `.supervisor/<sid>/interrupts.jsonl` (`<sid>` is the supervisor's session_id; the legacy flat layout is `.supervisor/interrupts.jsonl`) for new entries.
- **Want to run the watchdog manually**: `~/.claude/supervisor/supervisor-watchdog /path/to/repo 60` (project directory + threshold minutes, default 60).
- **Want cross-Codex use**: this suite's message channel is the official Claude↔Claude mechanism; Codex workers can switch to the agent-mail bridge for reporting (the two suites complement each other).

## Uninstall

```bash
rm ~/.claude/commands/supervisor.md ~/.claude/commands/rework.md ~/.claude/commands/research.md ~/.claude/commands/abstract.md ~/.claude/commands/adversarial.md ~/.claude/commands/worker.md
rm -rf ~/.claude/hooks/claude-supervisor
rm -rf ~/.claude/supervisor
# Also remove the matching entries from the hooks.StopFailure /
# hooks.SessionStart / hooks.PreToolUse / hooks.Stop arrays in
# ~/.claude/settings.json
```

## Repository Layout

The core protocol `commands/_core-supervisor.md` + five mode layers (`commands/*.md`) + the worker protocol `commands/worker.md`, spliced and distributed by `install.sh` at install time; the four hooks and `registry.py` live in `hooks/`; the watchdog is `watchdog.sh` at the repo root; three regression tests `test_*.sh`; each iteration's spec/plan archives in `specs/` (with design decisions and CR records); technical design principles in [DESIGN.md](DESIGN.md).
