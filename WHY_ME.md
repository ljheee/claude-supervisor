# Make AI Work for You — Stop Working Alongside It

[中文版](WHY_ME-zh.md) | English (this file)

When doing real work with Claude Code, the most expensive thing isn't tokens. It's your time at the keyboard. A worker session stalls — you type "continue". Rate limit hits — you wait it out and nudge again. A chunk finishes — you personally review it before the next one can start. It's called AI doing the work, but really you've been pulling night shifts.

This toolkit takes you off the night shift. One supervisor session manages N worker sessions: you write the goal, answer the upfront requirement questions, and walk away. Everything after that — progression, review, interruption self-healing — the supervisor runs itself, and only notifies you when a decision needs your call.

## What Lets You Walk Away

**Rate-limit self-healing, no more typing "continue".** Run multiple workers in parallel and collectively hitting 429 is the norm, not the exception. The instant a worker gets cut off, a StopFailure/Stop hook (an event callback, not a prompt instruction) reports the interruption straight to the supervisor. The supervisor logs it, backs off for five minutes, wakes workers one by one in a stagger (each extra worker gets one more minute of delay), and resumes from the interruption point. You never need to show up.

**Automatic phase-to-phase flow.** When a worker finishes a phase, it self-reviews first, then submits to the supervisor's adversarial review. Approved — the supervisor automatically issues the full instructions for the next phase. Rejected — it goes back with an issue list and gets redone. The pipeline moves by itself; you only get escalated to when it gets stuck.

**All the questions upfront, none afterwards.** Before work starts, the supervisor grinds the fuzzy goal into a spec and a plan, and concentrates all the requirement questions into this one phase. After that, it comes to you in only two situations: decisions that need your call (QUESTIONS protocol, queued asynchronously), and incidents it can't handle itself (desktop notification, straight to you). The rest of the time, your absence is the norm, not negligence.

**Crashes resume, never restart.** All progress is persisted in sharded ledgers under `.supervisor/`. A worker crashes — open a new session, realign with the ledger, carry on. The supervisor itself crashes — resume, and it picks up the same way. "Months of work gone overnight" is not an outcome this design allows.

## Four Modes, One Class of Blocked Pain Each

Greenfield projects (`/supervisor`): the biggest risk of AI building from scratch is it misunderstanding the goal without you noticing — by the time you see the finished product, it's too late. The supervisor interrogates the goal into a spec and plan for your confirmation upfront, then reviews phase by phase; drift gets rejected on the spot. The supervisor acts as a course-corrector against the project goal. Your involvement shrinks to twenty minutes at the start plus a final acceptance.

Legacy rework (`/rework`): the scariest thing about AI touching old code is "convenience" — the casual refactor, the test tweaked green, the thing you explicitly froze, touched anyway. The supervisor first excavates the baseline, sets up a regression safety net, freezes a don't-touch list, and after every phase double-checks scope with git; any boundary crossing gets sent back.

Research (`/research`): the biggest pit of AI research is confident hallucination. Evidence gets graded on five levels, the supervisor personally spot-checks and reproduces key evidence, and one fabrication re-opens the whole chapter. In the report you receive, every claim traces back to a source.

Synthesis (`/abstract`): hand it a pile of material to summarize, and it either gives you "correct-sounding platitudes" or quietly pulls in extra material as it writes. The material inventory locks once finalized; coverage reconciliation guarantees every item is either explained by a proposition or explicitly marked as a counterexample; propositions that can't be falsified and have no use get demoted.

## Why You Can Trust It

Behind every defensive layer of this toolkit lies a real crash: a worker silently killed by 429 with nobody knowing — that's where hook-level interruption reporting came from; the supervisor itself degrading for three and a half hours with zero signal (author's own incident log, 2026-09-07) — that's where the out-of-process watchdog came from. Five lines of defense, ordered by a session's life:

**Session starts, identity verified**: every session automatically receives its own SESSION_ID at startup (SessionStart injector); a worker's self-reported identity gets cross-checked against the session registry. Wrong format, mismatch, no such session — none of them pass the registration gate. With multiple supervisors coexisting, impersonation has no entry point.

**Round cut off, death reported for it**: when a worker's round is interrupted by 429 rate limiting, network error, or API failure (StopFailure event callback), the interruption is delivered straight to the supervisor via the hook, and an interruption record is written to the project at the same time. A finished round can't speak for itself; reporting the death is done by the event callback, not by the model. The supervisor then backs off, retries, and has the worker resume from the interruption point.

**Fake completion, anomaly caught**: the sneakiest failure mode is a round that "seemingly ends normally" but is actually model:error, degradation-induced empty responses, or tail degradation (the Stop hook identifies these). Without catching it, the supervisor mistakes fake-normal for completion and keeps waiting forever. Healthy rounds only get a millisecond-scale bounded tail scan — zero writes, zero disturbance; only anomalous rounds touch the ledger.

**Before the pen lands, miswrites blocked**: Write and Edit get mechanically checked before execution (PreToolUse guard). Writing to the wrong ledger shard, bypassing the registry to edit shared JSON directly — these actions are blocked before they happen, with the correct way shown, instead of reconciling after the fact.

**Outside all sessions, periodic surveillance**: the four defenses above all depend on some session's life or death. The watchdog is a system process independent of every session, registered in crontab, checking every ten minutes for silent workers and supervisor heartbeats. Timeout — desktop notification straight to the user. It carries alert de-duplication and gradient escalation, so it never becomes an alarm storm.

Running indefinitely doesn't depend on luck; it depends on structure. All progress is on disk — session life or death doesn't affect the ledger. Hooks, cron, shard guards are all hard code — no matter how the model degrades, the safety nets keep working; degradation only affects "judgment quality", and bad judgment is still caught by adversarial review and mechanical checks. Routine actions are all designed for long-term operation: idempotent reinstall, idempotent cron de-duplication, upsert self-healing supervisor registration, automatic heartbeat rebuilding — this toolkit runs the same on day thirty as on day one.

## The Boundaries, Stated Plainly

The supervisor cannot be guaranteed error-free. Its persona comes from Claude slash commands (prompts), and compliance is not strictly one hundred percent. The goal of this design is to compress the worst-case outcome from "never noticed" to "noticed a bit late". Desktop notifications use osascript and work on macOS. If a task fits in a single prompt, don't use this.

## Start in 30 Seconds

```bash
curl -fsSL https://raw.githubusercontent.com/ljheee/claude-supervisor/main/install.sh | sh
```

Terminal A: `/rename supervisor`, then `/supervisor build a XXX feature`. Answer its upfront questions.
Terminal B (same project directory): `/worker`.

Then go do your own thing. When it needs you, it'll send a notification.
