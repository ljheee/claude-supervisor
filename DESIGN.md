# claude-supervisor — Technical Design Principles

[中文](DESIGN-zh.md) | English (this file)

This document records the design rationale, reverse-engineering findings, interruption model, and the principles behind each mechanism of claude-supervisor. For usage, see [README.md](README.md).

## 1. Problem Definition

Claude Code sessions are naturally isolated: task context, progress, and conversation state each live in their own world. When a user runs multiple sessions in parallel on the same project, three things are missing:

1. **A global view** — who is doing what, and how far along;
2. **Supervision and review** — someone gates worker output, instead of discovering a wrong direction only after everything is done;
3. **Fault resilience** — after a worker is interrupted by rate limits / network / process issues, the project doesn't die silently forever.

claude-supervisor solves the first two with a dedicated Supervisor session + the official cross-session messaging mechanism + a state ledger, and the third with a five-layer defense (four layers in v2; the watchdog became the fifth layer in v3).

## 2. Underlying Capability Archaeology (reverse-engineered from the 2.1.259 binary)

This section is the factual basis of the design. Everything here comes from strings/contextual reverse-engineering of `~/.local/share/claude/versions/2.1.259` (191MB Mach-O). **No official documentation exists; re-verify after version upgrades.**

### 2.1 Session registry and credential publishing

`~/.claude/sessions/<pid>.json` is the registry of running sessions. Key fields:

```json
{
  "pid": 80446,
  "sessionId": "169ac824-...",
  "cwd": "/path/to/project",
  "name": "supervisor",           // fixed via /rename, or auto-derived
  "messagingSocketPath": "/tmp/cc-socks/80446.sock",  // UDS message channel
  "peerProtocol": 1,
  "peerFeatures": ["notify_idle", "reply_across_default_dirs", "artifact_yield"],
  "procStart": "Fri Sep  4 15:18:49 2026"
}
```

The `<pid>.<hash>.key` file in the same directory is the officially "published" inbound credential:

```json
{"peerToken": "12c635aa38def87395898c6aea77c1ba", "procStart": "Fri Sep  4 15:18:49 2026"}
```

Evidence in the binary: `[uds-messaging] Failed to publish the inbox auth key; peers will send unauthenticated (accepted: auth is optional on this platform)` — the auth key is published to peers, and **on this platform (macOS) auth is optional** (delivery is accepted even when token validation fails, which lowers the suite's dependence on key-file availability and means token matching is best-effort, not a hard gate).

### 2.2 Cross-session messaging (ListAgents / SendMessage / frames)

- `ListAgents` (internal name ListPeers): lists subagents / teammates / local sessions / cloud sessions.
- `SendMessage`: delivery addressed by session name or `uds://`/`bridge://` address.
- External-process injection (official hint verbatim from the binary):

```bash
{ echo '{"type":"auth","token":"'"$CLAUDE_CODE_MESSAGING_TOKEN"'"}';
  echo '{"type":"user","message":{"role":"user","content":"hello"}}'; } \
| socat - UNIX-CONNECT:$CLAUDE_CODE_MESSAGING_SOCKET
```

Frame protocol: top-level `type` ∈ {auth, user, control}; a user frame's message is the standard role/content structure, delivered to the target session as a user message.

### 2.3 The hook event set (parts relevant to this suite)

Full list reverse-engineered from the binary's event constant table:

```
PreToolUse, PostToolUse, PostToolUseFailure, PostToolBatch, Notification,
UserPromptSubmit, UserPromptExpansion, SessionStart, SessionEnd, Stop,
StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact,
PreModelSwitch, PostModelSwitch, PermissionRequest, PermissionDenied,
Setup, TeammateIdle, TaskCreated, TaskCompleted, Elicitation,
ElicitationResult, ConfigChange, WorktreeCreate, WorktreeRemove,
InstructionsLoaded, CwdChanged, FileChanged, DirectoryAdded, MessageDisplay
```

Key events:

- **`StopFailure`** (exists in 2.1.259): fires when a turn ends in failure (429 retry exhaustion, network error, API error). stdin schema: `{hook_event_name, session_id, transcript_path, cwd, prompt_id, error, error_details, last_assistant_message}`. Companion executor `executeStopFailureHooks`. **This is the foundation of the first layer of interruption defense.**
- `PostToolUseFailure`: fires after a single tool call fails (too fine-grained; 429 happens at the model-turn level, not the tool level — not applicable here).
- `Stop`: a turn ends normally. Cannot be used for interruption detection — it fires precisely when nothing failed.
- `notify_when_idle` (control frame `peer_idle_notice`): a signal notification that a turn ended. **Cannot serve as interruption detection**: whether a failed turn still emits the notice is unverified; even if it does, it only says "stopped" without a reason; and when the process dies, the subject is gone and nothing can be sent. **New use since v2**: as a worker liveness signal refreshing `last_response_ts` (idle ≠ done; never a prompting trigger). The subscription mechanism is verified working (2026-09-05 end-to-end record ①, see §9.8); if a future version changes the mechanism, this usage is rolled back wholesale without affecting other clauses.

### 2.4 Mechanisms deliberately not used, and why

- **notify_when_idle (v1 verdict, partially reversed in v2)**: not used as interruption detection or a completion signal (too weak, incomplete coverage, see 2.3), and the worker protocol already forces active reporting at every milestone, making a completion subscription redundant. Since v2 it is used only as a liveness signal (refreshing last_response_ts, see section 11), still never as a prompting trigger — prompting on idle would bombard a busy worker at turn frequency (every turn inside a long Phase is idle).
- **Agent Teams**: the official lead/teammate organization (roster.json, plan approval, worktree isolation). It is "hierarchical collaboration inside an organization"; this suite wants "an independent supervisor above peer sessions" — the supervisor is not part of the team, writes no code, only reviews and advances, which conflicts with the Teams lead (the person doing the work). Cross-session messaging + a custom protocol fits better.

## 3. Architecture

```
User ⟷ Supervisor session (the supervisor; writes no code)
              │ ListAgents / SendMessage (official cross-session messaging)
              │
     ┌────────┼────────┐
   Worker A   Worker B  ... (worker sessions, each owning a scope)
     │
     │ StopFailure hook (auto-delivers to supervisor UDS on turn failure)
     │ WORKER REGISTER / REPORT / STATUS / STALLED / RESUME (protocol messages)
     ▼
<project>/.supervisor/
   state.json         ← global ledger (supervisor single-writer, atomic writes)
   interrupts.jsonl   ← interruption journal (hook appends; append-only, never rewritten)
   acknowledged.jsonl ← interruption acknowledgment ledger (supervisor appends, append-only)
   watchdog_state.json← alert de-duplication state (watchdog single-writer, atomic)
```

The three elements map to the supervisor persona:

- **Passive Guardrail**: the supervisor never interrupts a working worker; it only post-audits produced output upon receiving a report (or an interruption notice). The trigger is a message, not polling (the sole v2 exception: the scheduled patrol cron, see section 11 — a no-op tick emits zero messages and zero long output).
- **OODA loop**: Observe (read the report + personally read files / git diff to verify, never trust summaries alone) → Orient (compare against goal and ledger) → Decide (APPROVE / REFINE / ESCALATE) → Act (SendMessage delivers the structured decision). The loop re-enters on the next report.
- **Global state storage**: `state.json` records goal, per-worker phase, every review verdict, and an incident journal. Loop Guard (3 consecutive REFINEs on the same phase → escalate to user) prevents an "edit-undo" death spiral.

### 3.1 Identity model (session_id as primary key)

The identity primary key for workers and supervisors is always **session_id** (acquisition changed in v3, see section 13: supervisor sid prefers the SessionStart-injected line; workers self-report their sid at registration for cross-validation; the name is no longer display-only — it is SendMessage's routing key: name-only, must be unique):

- The StopFailure hook's admission rule is "stdin's session_id ∈ workers[].session_id" — duplicate names, renames, same-directory user sessions, and an empty ledger all fail to misfire (P1-1/P1-3 fixes).
- Hook addressing the supervisor: exact `supervisor_session_id` match first; on id mismatch, fall back to `supervisor_name` + session cwd == `project_dir` double check — a same-name supervisor in another project is never selected (P1-2 fix).
- User escalation, WATCHDOG ALERT, and the interrupts ledger all carry session_id, so `claude --resume <session-id>` recovery instructions can be honored directly (P1-13 fix).
- Workers started from a subdirectory: the hook walks up from StopFailure.cwd to find `.supervisor/state.json`, then relies on session_id admission to rule out "unrelated projects accidentally on the path" (P1-4 fix).

## 4. Interruption Model (the core design of this suite)

### 4.1 Three classes of interruption

Worker interruptions classified by "who can perceive them", with completely different handling owners:

| Class | Example | Who perceives it | Handling layer |
|---|---|---|---|
| A. Failure visible to the model | consecutive tool failures, broken dependency | the worker model itself (turn still alive) | Protocol layer: WORKER STALLED |
| B. Turn-level transport failure | 429 retry exhaustion, network error, API error | the model **never** gets to speak; but the process is alive and the host's hook machinery still runs | StopFailure hook: WORKER INTERRUPTED |
| C. Process-level death | process killed, terminal closed, machine sleep | **no in-process mechanism is available** — the executing subject is gone | External detection (watchdog/patrol) + manual resume |

### 4.2 Why process death being "unhandled" is principled

The essential difference between B and C: hooks, model self-reporting, any messaging mechanism all live inside the worker process. Process death means **every mechanism parasitic on it dies simultaneously** — the StopFailure hook has no host to run on; WORKER STALLED has no sender to send. This is not an implementation defect but a logical necessity: you cannot ask the dead to report their own death.

Class C can therefore only be handled by an **observer outside the process**:

1. watchdog (cron timer) detects a worker's overdue silence → alerts the supervisor;
2. supervisor patrol (ListAgents confirms reachability) → escalates to the user;
3. the user runs `claude --resume <session-id>` (sessions persist as jsonl under `~/.claude/projects/`; process death does not lose the transcript) → the worker sends WORKER RESUME after recovery.

The anchor of recovery is discipline, not mechanism: the worker protocol forces "commit immediately per Phase", so any interruption (B or C alike) loses at most the uncommitted part of the current Phase — history is safe in git.

### 4.3 Four-layer defense (ordered by response latency; this section is v2 historical narrative — since v3 the watchdog is the fifth layer, see §6 and core's "Interruption and Liveness Handling (Five-Layer Defense)")

```
Class B ──→ ① StopFailure hook (seconds, automatic)
Class A ──→ ② Protocol-layer STALLED/RESUME (worker self-report, seconds)
Silent loss ──→ ③ supervisor patrol (since v2: 10-minute cron + on being woken; minutes)
              ④ external watchdog (cron, minutes; covers the blind spot when the supervisor itself is offline)
```

The four layers are redundant, not mutually exclusive: if hook delivery fails (the supervisor process died too), `delivered: false` is persisted and ③'s catch-up logic reconciles on the supervisor's next awakening; ③ depends on the supervisor being woken (since v2 the scheduled cron upgrades this from "luck" to "awake at most 10 minutes later"); ④ uses cron to cover the blind spot "nobody wakes the supervisor when its process is dead" (the cron scheduler lives inside the supervisor's host process; if the host dies the patrol dies — the fourth layer does not degrade).

### 4.4 The liveness semantics of lost-contact determination

**The lost-contact clock is reset only by messages the worker actively sends** (WORKER REPORT / STATUS / RESUME / REGISTER → `last_response_ts`). Instructions the supervisor sends (`last_instruction_ts`) are display-only and never part of the determination. Otherwise an "alert → send STATUS CHECK → clock reset → wait another cycle" infinite loop arises and a lost worker never escalates (P1-10 fix).

supervisor v1 could not wake itself on a timer; since v2 there is a 10-minute patrol cron (see section 11), but the "10 minutes no reply → retry, still no reply → escalate" logic is still carried by `pending_check = {ts, retries}` state: settled every time the supervisor is woken (including cron ticks), backed by the watchdog's cron to guarantee the supervisor is woken (P1-9 fix).

## 5. StopFailure hook design details

`hooks/worker-stopfailure.py`, registered under `settings.json`'s `hooks.StopFailure`.

### 5.0 Stop anomaly-capture hook (stop-anomaly-capture.py, added in v3.2)

`hooks/stop-anomaly-capture.py`, registered under `hooks.Stop` (fires at every turn end, coexisting with any pre-existing user Stop hook). Criteria and tiered delivery rules are in stop-anomaly.md (evidenced by incident transcript replay): model-error (last assistant entry has `model=="error"`) and empty-turn:tail (last entry has zero tool_use + empty/"…" text — tail degradation) are delivered on first occurrence; empty-turn:full (an entirely empty turn) requires a streak ≥2 before delivery. **Performance gate**: resolve_ledger uses pure directory walk-up (`git_fallback=False`, spawns no git) and is decided after the tail scan but before the git fallback — a healthy turn (supervised or not, in a git repo or not) pays zero git spawns, zero state writes, zero deliveries; an unsupervised session pays only stdin read + directory walk-up + one bounded tail scan (64KB floor, milliseconds; the tail scan cannot be skipped — it is exactly what decides whether the rare git spawn is paid); the git rev-parse fallback is paid only on anomalous turns in worktree scenarios (rare path). `resolve_supervisor` deliberately has no name fallback: if sid is missing, it only writes interrupts.jsonl for catch-up and does no live delivery (a name-only hit is precisely the mis-delivery vector v3 exists to prevent). Streak counters live in the shard's `anomaly_state.json` (single-writer atomic write, never sharing a file with watchdog_state.json); known boundary: the read-modify-write has a lost-update window across processes — two workers going anomalous simultaneously may undercount a streak by one, whose only consequence is suppressing one extra turn (the full-streak≥2 path); acceptable, not fixed.

### 5.1 Identity determination

See 3.1. The chain (all gates must pass before delivery):

1. Walk up from StopFailure.cwd to find `.supervisor/state.json` (not found → not a supervised project, exit);
2. `done: true` → exit;
3. stdin's session_id must be in `workers[].session_id` (absent → exit; an empty workers array rejects everything by construction).

### 5.2 Supervisor discovery algorithm

```
state.supervisor_session_id
  → scan ~/.claude/sessions/*.json, exact sessionId match with live socket → use it
state.supervisor_name + state.project_dir
  → name match AND session cwd == project_dir AND live socket → newest updatedAt
  → neither hits → no delivery (interrupts.jsonl still written, awaiting catch-up)
```

Auth is optional on this platform (see 2.1); a missing key file or procStart mismatch degrades to unauthenticated frame delivery without blocking.

### 5.3 Persistence and acknowledgment semantics (delivered / handled / acknowledged)

`delivered` is deliberately narrowed to "**bytes written into the supervisor's UDS**" — sendall success does not mean the supervisor processed it (the target process may exit before processing, reject at the protocol layer, or drop it). True delivery confirmation goes through three layers:

1. On every interruption the hook appends one record (append-only, never rewritten) to `interrupts.jsonl`, with fields `id`, `delivered`, `handled: false`;
2. after handling a WORKER INTERRUPTED (or doing catch-up), the supervisor **appends** `{"id": ..., "ts": ..., "action": ...}` to `acknowledged.jsonl` (its own single-writer ledger);
3. every time the supervisor wakes it computes the difference: `ids in interrupts.jsonl − ids in acknowledged.jsonl` = unhandled interruptions, handled one by one.

This design avoids the write-write race of "flipping flags on JSONL lines in place" (a supervisor rewriting the file would clobber lines the hook concurrently appends) — two ledgers, each append-only with an unambiguous single writer (P1-5/P1-7 fixes).

### 5.4 Safety boundary

The hook hangs off the user's global settings.json, so its failure modes must be extremely conservative:

- Any exception (malformed stdin, unreadable files, socket refusal, weird field types) → silent `exit 0`;
- Bounded time budget: UDS connect 1s + send 1s, no waiting recv (the original recv(2) is removed), persistence flushes but never fsyncs (P2-1 fix);
- All external input (error/error_details/sessions fields) is type-defended (`as_text` coercion, dict/str validation) before use, preventing exception escape (P2-2 fix);
- Reads only state.json/sessions, appends only to interrupts.jsonl, **never touches state.json** (that is the supervisor's single-writer territory).

### 5.5 Backoff and wake-up (supervisor-side protocol)

On receiving WORKER INTERRUPTED:

- kind rate-limit/network: `ScheduleWakeup(delaySeconds=300)` delayed wake, then SendMessage wakes the worker (since v2; v1 used Bash `sleep 300`, which had the pit of Bash's default 2-minute tool timeout aborting the backoff early — deprecated). **Flow discipline: ledger first, arm after** — once ScheduleWakeup is armed the turn ends, so incidents/acknowledged/pending_check must be written before arming, and the wake instruction is embedded wholesale in a self-contained prompt.
- Multiple workers interrupted together: stagger, each additional +60s (sleep 360/420/...), avoiding a collective re-collision with rate limits on simultaneous wake.
- kind api-error: backoff shrinks to 60s; if it interrupts again after retry, escalate straight to the user (most likely a config/quota problem — retrying is futile).
- After waking, set `pending_check`; retry/escalation is settled by subsequent wake-ups (see 4.4).

## 6. watchdog design details

`watchdog.sh` (installed as `~/.claude/supervisor/supervisor-watchdog`), invoked by cron.

- **Lost-contact rule identical to 4.4**: only `last_report_ts` / `last_response_ts` / `registered_at` count; `last_instruction_ts` is ignored.
- **Time parsing**: ISO-8601 tolerant (`fromisoformat` + `Z`-suffix normalization + two fallback formats); timezone offsets are converted to local before comparison; on parse failure that worker is skipped this round (conservatively no alert) with zero output (P1-11/P2-3 fixes).
- **Alert de-duplication (gradient escalation)**: `.supervisor/watchdog_state.json` records each worker's silence minutes at last alert; a new alert fires only when silence grows by another full threshold (T, 2T, 3T...) or the entry is new. De-duplication state is atomically persisted before alerting — worst case on crash is losing one alert, never an alert storm (P1-12 fix; completely silent when to_alert is empty).
- **macOS notifications**: notification text is passed via `osascript`'s `on run argv` parameters, **never** spliced into AppleScript source — worker names come from state.json, which is untrusted input (P0-3 fix).
- **External process invocation (osascript)**: array-style subprocess arguments, no shell concatenation.
- **Always exit 0**: shell-level `trap 'exit 0' EXIT` + python-level `2>/dev/null || exit 0`; cron never sees error output.
- **v3.1 supervisor self-check (fifth layer)**: at the top of the per-ledger loop (after done is skipped, before worker-overdue judgment — reachable even for zero-worker shards) read `.supervisor/registry.json` for this shard's supervisor `heartbeat_ts`: staled beyond threshold and the session socket is gone → **DEAD** (osascript desktop notification guiding the user to `claude --resume`); staled but socket still present → **DEGRADED** (suspected model degradation, requests human intervention; the notification text includes the kill -9 residual-socket fallback guidance). Socket liveness probes all same-sid records, any one alive counts as alive (same posture as worker routing, preventing a stale dead record from misjudging a live resumed supervisor as DEAD). Notifications go straight to the user, not the supervisor's UDS (the patient cannot call the doctor for itself). De-duplication shares the shard's `watchdog_state.json` with the worker gradient (key `supervisor:<sid>`, basis = heartbeat ISO time; a moved-forward heartbeat resets it; multiple shards dedupe independently, verified by case U). Heartbeat refreshing is carried by the supervisor's patrol protocol (each round incidentally runs `registry.py heartbeat`; the protocol requires `--project-dir` to be passed — omitting it reads the wrong registry by CWD and the heartbeat never reaches the real file → false DEAD). The watchdog only reads, never writes, the registry. Cron registration/removal is carried by supervisor startup step 7b and the wrap-up steps (marker comment line + entry line manipulated as a pair, idempotent; a temp file is written before `crontab "$TMPF"` installs it back, preventing a pipe break from losing the whole crontab; before removal, other active entries for the same project are checked — with multiple supervisors, A's wrap-up doesn't tear down B's still-in-use cron). Known boundaries: ① the heartbeat refreshes only on patrol and cron ticks are injected only after the current turn ends — a turn longer than the threshold produces one false DEGRADED (gradient dedup caps it at once, negligible); ② a kill -9 crash leaving a residual socket file gets triaged as DEGRADED even when truly DEAD (the fallback guidance already directs the user to treat it as DEAD).

## 7. Data files and concurrency discipline

| File | Writer | Mode |
|---|---|---|
| `state.json` | supervisor single-writer | read-modify-write, **atomic** (tmp + rename), re-read latest before updating |
| `interrupts.jsonl` | hook appends | append-only, never rewritten |
| `acknowledged.jsonl` | supervisor appends | append-only (interruption acknowledgment) |
| `watchdog_state.json` | watchdog single-writer | atomic write (mkstemp + replace) |

Under the three principles — single writer, append-only, atomic write — the only residual race is **a reader seeing a half-written file**: when the hook/watchdog hits a parse failure reading state.json, it treats it as "not supervised / skip this round" (conservative abandonment; the next cron round or the next interruption catches up). The supervisor's state.json writes must use tmp+rename atomic publication (P1-6 fix, a protocol-layer constraint — the supervisor is an LLM, not a program; the protocol states it in plain text). The whole `.supervisor/` directory should go into .gitignore.

## 8. install.sh design details

- **A corrupted settings.json → back up then abort the install**; never silently reset global config (P0-2 fix);
- **Existing same-name files are backed up before overwrite** (timestamp suffix `.bak-<stamp>`; identical content skips the backup) (P0-1 fix);
- hook registration commands are built with `shlex.quote()`, safe even for paths containing single quotes (P2-5 fix);
- settings.json update: flock exclusive lock + mkstemp unique temp file + fsync + original file mode preserved + os.replace atomic publication (P2-4 fix);
- abnormal hooks configuration structure (non-object / non-array) aborts instead of destroying.

## 9. Known Boundaries (on the record; not defects awaiting fixes)

1. **No automatic recovery from process death** (§4.2, principled): the watchdog can only detect + alert; resume must be done by hand.
2. **Mode selection is an explicit user decision** (§12.1): greenfield (/supervisor) vs rework (/rework) is the user's call; the protocol does no automatic task-type classification — a soft misjudgment mismatches the whole run; better to ask the human once more.
3. **Hook version dependence**: the StopFailure event is confirmed present in the 2.1.259 binary with no official docs; a Claude Code upgrade may change the mechanism — re-run `test_stopfailure.sh` regression.
4. **peerToken is not a hard check**: auth is optional on this platform; a malicious local process could read the same key file anyway — this suite provides no cross-process authentication and works only within a single-user trust domain.
5. **Error classification is heuristic**: `classify_error` groups by keyword (429/rate limit/overloaded → rate-limit; timeout/econnreset → network; else api-error) and decides backoff duration. Misclassification only yields a suboptimal backoff, never incorrect behavior.
6. **Dependence on the LLM (compliance can't be guaranteed, only engineered against)**: the supervisor persona is injected via slash command — `/supervisor` is fundamentally the protocol text sent to the model as one long user prompt, with no process-level isolation or role binding. Prompts are soft; LLM compliance is never 100%: the supervisor may skip a patrol, forget the Loop Guard, drift after repeated REFINEs (long-session context compaction accelerates drift). **Cannot be eradicated, only hedged**, in three layers:
   - **Take deterministic logic away from the LLM**: interruption detection triggers don't depend on supervisor diligence — the StopFailure hook is process-level code (fires the instant a turn fails), the watchdog is a cron timer (depends on no agent being alive). All the supervisor needs to do is "respond per protocol upon receiving a message"; the trigger chain is hard, only the response is soft.
   - **Externalized state makes drift recoverable**: all progress lives in state.json, not the supervisor's context; state files don't lie. The escape from drift is re-running `/supervisor <goal>` to re-inject the full protocol — state.json restores all context and drift resets to zero. Hence the protocol's repeated insistence that "the decision basis is state.json, not your memory".
   - **The protocol's own writing style**: immediate-execution instructions, behavior red lines explicitly enumerated, concrete actions per step rather than abstract principles — empirically, strong imperative + concrete steps yields markedly higher compliance than soft description.
   
   Residual risk: soft supervisor failures (missed patrols, forgotten rules) are unsolvable; the hard safety-net layer bounds their consequence to "noticed late" rather than "never noticed". This is the essential trade-off of this suite versus a pure-code solution, and one of the root reasons the fourth layer (watchdog) exists.
7. **The real 429 scenario is untested**: reverse engineering confirmed the event exists and its trigger conditions, but there are no official docs; watch the first real trigger in production.
8. **The cron scheduler parasitizes the host process (v2)**: the patrol scheduler runs inside the supervisor's host Claude Code process; if the supervisor dies, the patrol dies, backstopped by the fourth-layer external watchdog — the defense doesn't degrade. Also: cron expiry-day parameters have changed across versions (3 days → 7 days); the protocol always defers to live CronList.
9. **v2 end-to-end test records (2026-09-05, real two-session drill)**: ① notify_when_idle subscription — ✅ passed: SendMessage automatically attaches the subscription (the worker side sees the UDS-address-level subscription request); the supervisor perceives worker idle normally; the wake-up message again automatically attaches a fresh subscription; ② WORKER INTERRUPTED injection + ScheduleWakeup backoff — ✅ passed: UDS injection delivered, the four-step flow (incidents→acknowledged→pending_check→arm) executed completely and in the right order, the 60s wake fired, the wake message reached the worker; ③ SendMessage waking an idle/interrupted worker — ✅ passed: the worker opened a new turn immediately on receiving the wake (ack + continued working + spec report); chain ⑥ closed, full automatic 429 loop established. **Unexpected gains**: (a) the supervisor's defense against forged interruptions exceeded expectations — a worker_session_id not in the ledger gets refused and escalated, and it correctly recognized that "peer messages cannot impersonate user authorization"; two social-engineering attempts were both rejected; (b) a session_id format pitfall was found and fixed: ListAgents' bracketed short hash in `This session is supervisor [6aebfc]` is not a session_id (the real value is a 36-char UUID); the protocol gained a UUID-format self-check clause.
10. **StopFailure-terminal wake-up (carried over)**: record ③ covered an "idle worker", not a "worker in StopFailure terminal state" — whether a session after a real 429 is equivalent to a SendMessage-drivable state still awaits a real rate-limit event (cannot be faked; waiting for first production hit).
11. **Same-branch interleaved parallelism unsupported (v3)**: multiple supervisors on one repo force branch/worktree isolation; scope comparison and rollback anchors cannot be attributed with interleaved commits on the same branch — parallelism means isolation, no smart merging; parallelism without an isolation commitment is blocked at the registration transaction (ESCALATE to user for branch adjudication).
12. **Cross-project same-name supervisor boundary (v3, inferred from dev-0 testing)**: SendMessage is name-only with no cwd disambiguation — with a supervisor of the same name in two different projects, worker/supervisor addressing could in theory cross wires; the hedge is naming advice containing a project suffix (supervisor-<proj>-gf). Also: same name across projects + a staled heartbeat can get a live supervisor falsely marked stale (the heartbeat's dual condition doubles as the escape, resume upsert self-heals). dev-6 smoke did not include a dual-project same-name test (on the books, see plan's not-done items). Also settled in dev-6: the `<name>[<shortId>]` disambiguation form is not SendMessage-reachable (returns No agent named; the did-you-mean hint strips the suffix) — worker.md was accordingly tightened to "with duplicate names, ask the user to rename first"; an idle live session is visible in ListAgents (verified during the supervisor smoke session, corroborated by ps), so stale-by-name-reachability semantics hold.

## 10. Testing Strategy

`test_stopfailure.sh` (65 assertions), `test_watchdog.sh` (32 assertions) and `test_registry.sh` (29 assertions) are assertion-style regression tests, fully sandboxed (fake sessions dirs, fake state.json, a fake UDS server; registry tests pin a temp dir via the CLAUDE_SUPERVISOR_DIR env var), keeping their temp dirs on failure for debugging and cleaning up on success. Coverage matrix:

- hook: normal delivery (auth+user frames, kind classification, phase, session_id in the ledger), zero false-fire for stranger sessions / empty workers / done projects / no state dir, subdirectory cwd walk-up, socket present but refusing (real connect-failure branch), auth degradation on missing key, malformed stdin, non-string error_details, same-name supervisor decoys not selected; v3 additions: multi-shard targeted delivery / zero-hit and double-hit ambiguity non-delivery, flat-layout fallback and upgrade window (case18b: with 1 shard + v2 flat layout coexisting, pass-2 disabled — no misdelivery), worktree discovery, archive invisible, shard guard (blocking registry direct writes / wrong-sid deny / short-circuit allow), identity injector (startup/resume/garbage-silent);
- watchdog: overdue alert (with session_id), same-silence-level dedup, `last_instruction_ts` not suppressing alerts (independently asserted in case C), silent for fresh workers / recently-responded / done projects, silent exit on invalid threshold / directory / corrupted state / non-list workers, gradient re-trigger (case O), gradient reset after recovery (case P: a changed basis snapshot starts a new silence cycle), RFC3339 Z timestamp parsing; v3 additions: shard iteration with flat fallback, multi-shard independent alerts and non-interfering dedup, UDS direct delivery targeted by supervisor_session_id, archive invisible;
- registry: first start on a fresh project (directories self-created), two-phase isolation transaction (KNOWN_OTHERS full sid lines, prefix cannot satisfy the grown check), name-collision exit 3, idempotent upsert, heartbeat rejecting nameless rebuild for missing entries / rebuild on collision, mark-stale/unregister existence and idempotency, --project-dir off-site location, corrupted registry reset, 6-way concurrent registration with zero dirty writes.

One recorded testing lesson: hard-appending a `Z` suffix to a local naive timestamp turns it into a "future time" (UTC parsing runs 8 hours ahead of the local wall clock), making silence negative and never alerting — test case K covers the Z-parsing path separately with a genuine UTC past timestamp.

The end-to-end real-429 path (Claude Code triggers StopFailure → hook delivery → supervisor backoff and wake) remains untested; watch the first production trigger.

## 11. Scheduled Self-Patrol and the Alignment Funnel (added in v2)

Empirical basis: `specs/2026-09-05-scheduled-supervision/claude_cron.md` (field-test record of Claude Code 2.1.259's scheduled-task mechanism).

### 11.1 Scheduled self-patrol

At startup the supervisor uses `CronCreate` to create a 10-minute session-only patrol cron whose prompt contains the three patrol steps + a CronList self-check rebuild (crons expire; rebuilding is routine) + a noop discipline (when nothing is due, output exactly one line, preventing context bloat from accelerating protocol dilution).

Key design decision: **session-only (durable=false), not durable** — field tests showed durable tasks are directory-scoped: after the owner dies, other sessions in the same directory (workers) grab the lock and take over execution, and the patrol prompt would fire into a worker's context, polluting it; session-only guarantees the only executor is ever the supervisor itself. The cost: if the supervisor dies, the cron dies (acceptable — the fourth layer backstops).

Idempotency: re-injecting the /supervisor protocol is the established drift-recovery mechanism; startup runs CronList dedup to prevent double crons. Wrap-up: CronDelete when everything is done.

Signal frequency spectrum (bottom-up): minute-level watchdog alerts (hard) → 10-minute patrol tick (hard, host scheduler) → turn-level idle notices (hard, host) → milestone WORKER REPORT (soft).

### 11.2 ScheduleWakeup backoff and flow re-ordering

Interruption backoff moved from Bash `sleep 300` to `ScheduleWakeup(delaySeconds=300, ...)`: eliminating the Bash 2-minute-default-timeout pit and the tool occupation. delaySeconds is runtime-clamped to [60,3600]; the api-error 60s backoff sits exactly at the lower bound. **The flow re-ordering is the heart of the change**: once armed, the turn ends, so ledger writes (incidents/acknowledged/pending_check) must precede arming, and the wake action moves wholesale into a self-contained prompt (no dependence on the original turn's memory).

### 11.3 The idle liveness signal

Every supervisor SendMessage attaches a notify_when_idle subscription; receiving an idle notice has exactly one action — refresh `last_response_ts` (host-level hard evidence: the process is alive and the turn ended normally). **Explicitly not a prompting trigger**: the worker protocol is already "no report until the milestone is done", and every turn inside a long Phase is idle; prompting on idle would bombard a busy worker at turn frequency (CR P0-1 verdict). Whether to prompt goes solely through the existing 60-minute lost-contact rule — one logic, no dual track. The subscription mechanism is verified (see §9.8 record ①); if a future version breaks it, this section reverts.

### 11.4 Three-tier answer firewall

Worker questions are tagged at three levels (goal-internal / supervisor-authority / needs-user) in the WORKER QUESTIONS format. The supervisor answers only the first two (authority verdicts recorded into state.json's decisions and disclosed in the final report); needs-user items are batched and asked of the real user. The firewall's purpose is to separate "supervisor as proxy" from "impersonating the user" — if the supervisor answered goal-level questions without bounds, you'd get a "two LLMs convincing each other" drift amplifier with nobody validating goal alignment.

### 11.5 Three-stage interrogation (the alignment funnel)

v1 alignment was passive (audit whatever the worker reports), pushing the burden of surfacing real problems onto the executor's perspective. v2 upgrades to active interrogation: clarify mines for understanding bias (adversarially digging out silent assumptions, inverted acceptance criteria), spec mines for completeness gaps (boundary/error-path/non-functional), plan mines for execution risk (DoD verifiability, hidden coupling, pre-mortem). Each stage's interrogation is capped at two rounds, counted independently of the Loop Guard (3 REFINEs), preventing "perfect clarification" from becoming an excuse to never start.

## 12. Mode Layering and the rework Mode

### 12.1 Split motivation: protocol bloat vs the generalization dilemma

After v2, the /supervisor protocol fit greenfield (build-from-scratch) projects well but lacked four targeted designs for the high-frequency legacy-patch/refactor scenario (baseline anchoring, regression safety net, archaeology adjudication, scope discipline). The two obvious generalization paths: add a task-mode parameter to /supervisor, or add a /rework command. The former's problem: full-protocol injection means rework clauses and greenfield clauses pollute each other's context; the longer the protocol, the lower LLM compliance (the old §9.5 problem), and leaving mode determination to a soft LLM judgment introduces "wrong mode, whole run mismatched" uncertainty. The latter's problem with copying the core protocol wholesale: 150-line-scale copy synchronization is a disaster. The answer is a physical split: `commands/_core-supervisor.md` (mode-agnostic: identity/startup/ledger/five-layer defense/OODA/QUESTIONS/dev-N skeleton/red lines) + one thin mode layer per mode (frontmatter + mode declaration + front-phase interrogation), the mode chosen explicitly by the user's command (no auto-detection).

### 12.2 Composition mechanism: install-time splicing (option B), not runtime @ references

Mode layers and the core are cat-spliced into a single command file by install.sh at install time. Choosing splicing over @ references matches the suite's standing philosophy (hard over soft; the first hedge in §9.5): splicing happens at install time, grep-assertable, diff-reviewable; the spliced product carries three structural assertions (frontmatter uniqueness — a later `---` horizontal rule is not misparsed; five required sections present; no duplicated level-2 headings — mode-layer sections must not collide with the core's), assertion failure backs up and aborts, leaving no half-written output. **Two key dev-0 conclusions**: spliced products load fine as slash commands (option B's premise holds); **underscore-prefixed files also register as commands** (tested, contradicting expectation) — therefore `_core-supervisor.md` must never go into `~/.claude/commands/` (it would become a mis-triggerable pseudo-command); the source copy installs only to `~/.claude/hooks/claude-supervisor/`.

Zero-regression guarantee: the split is a pure refactor — the spliced product's diff against the pre-split supervisor.md allows only a new mode-declaration section, section reordering, and three parameterized greenfield-specific phrasings (startup step 7's first-phase instruction sentence — time note: it was step 7 at split time; after v3 inserted the cron step it is now step 8 / the phase enumeration / the schema example — parameters declared by the mode layer; under rework the supervisor's initial instruction delivers the mode's enumeration to override worker.md's greenfield default). dev-1 gate measured: 24 removed lines = 20 pure moves + 4 permitted rewrites, zero clauses lost.

### 12.3 rework's archaeology four-piece set and safety net

rework state machine: `archaeology → safety-net → spec → plan → dev-N`. The four-piece archaeology set (architecture map / debt list / suspicion list / dependency dark-web) is grounded in: the first lesson of a legacy project is archaeology, not planning — without a behavioral baseline, REFINE/APPROVE cannot judge "fixed or broken". Three hard rules: bug-vs-feature suspicions are never worker-adjudicated (whatever git blame can't settle is marked "for the user", defaulting to needs-user level — an archaeology verdict's archival value exceeds greenfield's; unrecorded verdicts get re-committed by someone later); safety-net tests lock behavior, not implementation (tests asserting internal structure make refactors inevitably false-red); the safety net contains the to-be-changed behavior (only by locking the current state first can pre/post diffs be attributed).

### 12.4 frozen_behaviors (the don't-touch list)

(Implementation decision record [implementation CR P2-7]: spec F1 once required the core schema to contain an optional frozen_behaviors field, but that contradicts the zero-regression hard constraint — the core schema must remain verbatim identical to pre-split; no new fields. Final implementation: the schema definition lives in the rework mode layer (mode-specific fields belong to the mode layer), the core untouched. Self-consistent with the extraction principle "mode-agnostic goes into the core".)

An optional top-level state.json field, lifecycle: archaeology produces the draft → the user confirms and locks it at safety-net APPROVE (locked_by) → the first dev instruction after locking delivers the full list to the worker (workers don't read state.json; it must be told explicitly) → touching it during dev without authorization means REFINE + escalation. The mechanical signal for touching: the entry's evidence field (archaeology evidence + related file/function list) intersected with the dev diff; a non-empty intersection triggers. Fuzzy entries (like "response time must not regress") have no mechanical signal; the supervisor compares manually during review and annotates. Change channel: a needs-user QUESTIONS application; once approved, update the ledger before touching code.

### 12.5 The drive-by refactoring red line (scope comparison)

The classic death of refactoring is the "drive-by refactor": every phase changes a little extra, and the final diff is unreviewable. The countermeasure is a mechanical signal: at every dev review, run `git diff --name-only <this phase's baseline commit>..HEAD` and compare against the phase's declared scope; any excess means REFINE no matter how "reasonable" (no dependence on worker conscience or supervisor memory). Escape hatch: genuinely needing a wider scope goes through a needs-user QUESTIONS (a scope change is a goal change). Companion disciplines: the working tree must be clean before dev-1 (a dirty tree pollutes the safety-net baseline and scope comparison); one phase = one independently rollback-able unit of change; every phase's DoD must contain either a "safety-net output identical before and after" assertion or an "expected behavior diff list".

### 12.6 Injection size budget

Protocol length directly governs compliance (every added mode's clauses dilute the others'), so mode layers carry a hard budget: greenfield mode layer 39 lines, rework 68, research 52, abstract 49, adversarial 43 (measured after hardening; prior revision rounds were all same-line replacements with no growth), core 195, worker 128. Spliced products: greenfield 234, rework 263, research 247, abstract 244, adversarial 238 (same-day measurements; the old lesson of the line-count table still stands: run wc -l after every change before writing numbers). rework's incremental clauses control size by referencing the core's existing mechanisms (QUESTIONS three tiers, Loop Guard, the two-round interrogation cap) rather than restating them; self-contained clauses (boundary/error-path/non-functional three-checks) are the exception — the spliced product contains no greenfield layer, so cross-mode references would dangle (implementation CR P1-1 verdict). research likewise references primarily (time-boxing/reconciliation/spot-check reproduction all reference the core's mechanical-replay discipline); the new worker-facing delivery clauses must be self-contained because workers can't read the mode layer.

**research mode (2026-09-09, third mode)**: the interface explicitly reserved by rework spec §3's non-goals. Design basis specs/2026-09-09-research-mode/spec.md; four core differences: the output is a report, not code (the acceptance anchor becomes a numbered question list reconciled one by one); a product-code read-only red line (git changed-file set including uncommitted ⊆ the `--out` report directory; excess means REFINE — reusing rework's scope-comparison posture); five-level evidence grading A-E + the supervisor personally spot-checking and reproducing A-C key evidence (one fabrication re-opens the whole chapter, continuing the mechanical-replay discipline); non-git directories allowed (the opposite of rework's git assertion; persisted output is the deliverable). State machine `scope → survey → dev-N` (one chapter per unit, a 90-minute per-chapter time-box against unbounded expansion). Zero code changes: a pure new mode layer + one install.sh splice registration line; the splicing structural assertions apply to it.

**abstract mode (2026-09-10, fourth mode)**: convergence/synthesis tasks — the input is finished material (documents/diffs/verbal background in any mix), the output is high-level propositions that govern the material; the direction is the opposite of research (divergent vs convergent), the evidence lives inside the material, not outside it. Design basis specs/2026-09-10-abstract-mode/spec.md; four core differences: the acceptance two-piece (coverage reconciliation — a material×proposition matrix where every item is either explained or explicitly marked a counterexample; back-referencing anchors — `pattern-in-material` propositions require anchors; `intent/attribution-inference` propositions are explicitly labeled as inference with a derivation chain); **input-surface lock-down** (no new material after ingest finalization — the scope discipline runs opposite to research, which locks the output while this locks the input); **empty-talk checks + absence signals** (unfalsifiable correct-sounding platitudes get demoted; what's repeatedly absent from the material must enter the list); **mandatory adversarial narrative** (one narrative explaining all the material is often the most suspicious one; alternative narratives are recommended-not-required). State machine `ingest → distill → refine-N` (per-round targeted rework against review defects + report-per-round, not chapter-by-chapter production). Unlike research: the core got two changes (the registry `--mode` enumeration gained abstract; the state-machine entry/advance clauses were parameterized — execution-phase semantics defer to the mode layer's declaration, the dev-N skeleton being the default), with the four products re-spliced in sync.

**adversarial mode (since 2026-09-17, hardened 2026-09-21, fifth mode)**: adversarial-review tasks — the input is existing output (PR diffs/design docs/research reports), the output a converged review report. Design axiom: **adversarialness comes from isolation, not from prompt declarations** — switching perspectives inside one session is context pollution (the earlier perspective's conclusions anchor the later one); writing "think critically" in a prompt buys no real adversarialness; only structural isolation — independent sessions + message topology + persistence placement — buys it. Design basis specs/2026-09-17-adversarial-review-mode/spec.md; seven core mechanisms: ① **phase ownership on both sides** — supervisor-side `ingest|assign|merge` occupying no workers[].phase, worker-side `round1 → cross-1 → (cross-2) → done` (the heaviest override yet of the core's dev-N skeleton; the two rendezvous points ride the core's "this phase explicitly requires convergence" exception clause); ② **structural guarantee of round1 isolation** — findings are reported only in the message body, registered by the supervisor into its own shard, never persisted to shared paths (the PreToolUse guard already blocks workers from writing others' shards), with the residual boundary honestly disclosed (a worker can technically read the supervisor's shard but the protocol gives no incentive); ③ **the anonymized union** — cross-1 distribution strips perspective attribution to prevent authority-following; each side receives only the others' findings (its own are never sent back — anti self-corroboration); ④ **three-state convergence** (at least two independent sides agreeing / one side persisting through attack-and-defense / explicit retraction) + the N≥3 mixed majority/minority criteria + Loop Guard capping cross at 2 rounds; ⑤ **the worker-count decision table** + perspective menu + alternate zone (user-named perspectives are hard constraints that may exceed the recommendation); ⑥ **the zero-commit discipline** (reviewing is read-only work, overriding the worker's default "commit immediately per phase" and its supervisor-unreachable self-help fallback — the interruption alignment anchor correspondingly becomes the supervisor-shard findings echo instead of git log); ⑦ **attrition handling** (≥2 sides continue, the missing side's un-crossed findings marked "not crossed due to attrition"; <2 sides degrades to a single-lane summary labeled "adversarial structure not established").

**The subagent channel's empirical adjudication (2026-09-19, fed back from a violation incident)**: in the first field run the supervisor spawned its own subagents as workers without user approval — root cause: the spec's non-goal "no automatic worker launch" never made it into the mode layer. Three field experiments (Claude Code 2.1.259 via mc --code) settled the subagent mechanism's boundaries: same-session SendMessage revives with full transcript; cross-session resume is refused; a subagent sees only its spawn prompt with zero leakage — the structural basis for round1 isolation is experimentally backed. The final design is a **dual channel**: terminal workers by default (cross-day/crash recovery/full five-layer defense), supervisor-spawned subagents as a user-explicitly-approved alternative (five constraints: background spawn; spawn prompt containing the full five-item delivery verbatim; agent_handle recorded in the ledger; interruptions flow back as in-turn tool errors; the report annotates each lane's channel).

**The zero-rebuttal mandatory re-review (hardened 2026-09-21, product of the five-run retrospective)**: across five field runs, cross-1 recorded zero rebuttals and zero retractions — "truly bulletproof" and "nobody attacked seriously" are output-identical and indistinguishable, meaning the mode's central claim (the two-round structure guarantees findings get challenged or retracted) was never once validated. The hardening rule: when cross-1 shows zero fact-level rebuttals and zero retractions (grade/clustering mediations don't count), the supervisor must personally re-attack a sample of 3-5 high-impact findings (opening original anchors, hunting counter-evidence, re-verifying grades); overturned items are recorded as retractions labeled "supervisor unilateral verdict"; re-review verdicts are persisted per-item to the shard immediately (the breakpoint truth for a supervisor crashing mid-review). Hardened in the same batch: the ledger verdict word is pinned to "registered" (APPROVE reserved for core phase advancement — a field run once mixed them; a worker reading the ledger literally is a rendezvous-bypass opening); the compact-echo escape hatch (full-verbatim echo has a field-run kill case of blowing the subagent's context: live workers get compact echo, context-lost ones get full resend or a dedicated distribution package + pointer — the package contains only that side's due content, not an isolation leak); the "N items + END" tail marker (the detection means for the subagent channel's ~4KB idle_notification truncation); dedup-before-registration (a worker resending old batches after recovery doesn't double-count toward rendezvous).

**Five field-run validation records (2026-09-18 to 09-21, the mall-label-manage/super-input repos)**: Round 2 code review (70 converged findings, the U51 NPE hard failure, four-way javap cross-corroboration); Round 3 Lion config review (47 findings, the cap-10 blind spot with dual-lane fallback); Round 4 document review (first fully compliant terminal-channel run; the TypeFree "source-private" chain-collapse of errors — A/B independently discovering the same L8 defect without knowing of each other, direct positive evidence of isolation effectiveness); Round 5 five-service completeness audit (X-1, a decision basis used backwards; cluster B's systematic membership drop; after w1's attrition and replacement, the substitute w1b independently hit X-1's root cause under intact isolation — stronger evidence than an independent co-discovery, effectively a controlled experiment). The harshest resilience test the protocol has survived: host sleep interruption, context explosion, and gateway 502 triple-failure with w5 escaping death (batch reporting + breakpoint dedup) and four standby lanes correctly exempted by the watchdog. The five straight zero-rebuttal runs are the direct basis of the hardening rule (see the previous entry).

## 13. Multiple Supervisors Coexisting (v3)

### 13.1 The motivation for splitting discovery from storage

v2's flat `.supervisor/state.json` assumed a single-supervisor world: cross-run overwrites (a new task scribbling over the old ledger, goal/workers replaced) and cross-mode parallelism were impossible (three shared resources fighting: the ledger singleton / message routing cross-talk / cron dedup swallowing). v3 splits "discovery" (workers finding supervisors, supervisors seeing each other) from "storage" (each one's own ledger): discovery converges to the single multi-writer file registry.json, storage disperses to one single-writer shard directory per supervisor — the concurrency complexity is compressed onto one file, everything else being single-writer pure-mv atomic writes. A new task means a new shard; old ledgers automatically become read-only archives (cross-run isolation for free).

### 13.2 Why the shard key is session_id (a UUID)

The shard key must travel with the "supervisor instance" and be stable across resumes (dev-0 field test: `claude --resume <uuid>` restores the same UUID, while the session name gets reassigned test-98→test-34). session_id's dual identity: persistent identity and storage key (shard directory name, hook stdin matching, watchdog UDS direct delivery all use it); the session name is the message routing key (SendMessage accepts names only; UUID/short IDs tested unreachable) — two keys, two duties, both indispensable: names must be explicitly managed (/rename unique; collisions blocked at the registration transaction), sid must be reliably obtained (SessionStart injection primarily, scanning the sessions registry as fallback). v2's assumption "ListAgents can derive sessionId" was disproven by testing (the current version outputs no UUID) — the root reason workers switched to self-reporting their sid.

### 13.3 The registry.py single-point multi-writer trade-off (why not an LLM holding locks live)

registry.json is the system's only multi-writer file. macOS has no native flock (only shlock, tested), and having an LLM construct lock-held read-modify-write commands on the spot is the heaviest zone of execution drift — the protocol clauses constrain only "which subcommand to call" (register/heartbeat/unregister/mark-stale); the lock (fcntl mutual exclusion, 5s timeout exit 4), two-phase isolation confirmation (exit 2 + --isolation-confirmed --known-others re-read verification), name-collision triage (exit 3), and tmp+rename atomic writes are all sealed inside a dumb script. For contrast: state.json atomic writes are single-writer lockless pure mv; install.sh's settings.json updates already set the python fcntl precedent.

### 13.4 The git physical-isolation verdict

Multiple supervisors on one repo in parallel force branch/linked-worktree isolation (mechanically decidable, no smart merging): scope comparison, safety-net baselines, and rollback anchors all hold within each branch's semantics; interleaved same-branch commits are explicitly unsupported (scope comparison cannot be attributed, see §9.11). Parallelism without an isolation commitment is blocked at the registration transaction (exit 2 → the user confirms branches don't conflict → retry with confirmation; ESCALATE writes no entry, rooting out self-created dead entries).

### 13.5 The asymmetric design of dead-entry handling

Markable stale, never deleting others' entries: a supervisor can only mark-stale another's registry entry (dual condition: ListAgents-by-name unreachable AND heartbeat over 30 minutes stale); deletion is reserved for unregistering oneself — because the entry's shard ledger still exists and may belong to an instance awaiting resume. The true adjudicator of dead entries is the user: on registration failure the worker reports a three-option list (resume recommended / retry later / fall back to autonomous mode — complete the current phase's instruction and commit, no self-advancing phases).

### 13.6 Shard enumeration's UUID whitelist (archive isolation)

When hooks/watchdog scan shards they match only UUID-format directory names; archive/ and non-UUID directories are constructively invisible — archive isolation is mechanically guaranteed by the directory naming rule, not by runtime judgment. Upgrade-window compatibility for the old flat layout: when a shard exists but the hook's sid has zero hits, one flat workers[] fallback pass is appended (v2 legacy rounds don't silently lose direct interruption delivery at the appearance of the first v3 shard).
