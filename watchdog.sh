#!/usr/bin/env bash
# supervisor-watchdog: two jobs, cron-friendly (always exits 0, never noisy):
#   1. detect overdue (interrupted/silent) WORKERS and alert the supervisor;
#   2. triage the SUPERVISOR ITSELF (heartbeat vs socket liveness) and notify
#      the USER via desktop notification - nobody watches the watcher, so the
#      watchdog does (see stop-anomaly.md / incident 2026-09-07: supervisor
#      degraded 3.5h with zero protocol path to detect it).
#
# Worker sessions killed by 429 / network loss / process death cannot send any
# message themselves (no WORKER REPORT will ever arrive). This script is the
# external timer the passive supervisor lacks.
#
# Supervisor triage (v3.1):
#   - heartbeat clock: registry entry's last heartbeat (the supervisor refreshes
#     it on every patrol cron tick, by protocol);
#   - liveness clock: session transcript mtime in ~/.claude/projects/... (the
#     only machine-readable "the session is still producing something" signal);
#   - DELIVERY (session dead):     notify user "supervisor session dead,
#     claude --resume <sid>" - the alert the supervisor would have wanted;
#   - DEGRADED (socket alive + heartbeat stale >= threshold): notify user
#     "supervisor suspected degraded (responding but not progressing), needs
#     human intervention (/compact / model switch)". Model-error / empty-turn
#     rounds keep the transcript moving while zero heartbeat - that's exactly
#     the 3.5h incident signature;
#   - alert dedup: same per-shard watchdog_state.json, key "supervisor:<sid>",
#     ladder reset when the heartbeat basis moves forward (recovered).
#
# v3 shard-aware:
#   - enumerates UUID-named shard dirs under .supervisor/ (archive/ and any
#     non-UUID dir are invisible by construction); zero shards -> legacy flat
#     state.json fallback;
#   - each shard gets INDEPENDENT overdue detection and its own alert-dedup
#     state (.supervisor/<sid>/watchdog_state.json), so multiple supervisors
#     never reset each other's escalation ladders;
#   - alerts are delivered by DIRECT UDS INJECTION to the shard's
#     supervisor_session_id (resolved against ~/.claude/sessions/), never by
#     session NAME routing - same-named supervisors would cross-wire.
#     Delivery is best-effort: a dead/absent supervisor socket means the
#     alert is dropped (the watchdog is the 4th defensive layer, not a
#     guaranteed channel).
#
# Silence clock = last WORKER-ORIGINATED event only (last_report_ts /
# last_response_ts / registered_at). last_instruction_ts is deliberately
# ignored: a STATUS CHECK from the supervisor must NOT reset the clock,
# otherwise "alert -> check -> clock reset" loops forever without escalation.
#
# Alert de-duplication: per-worker state in the shard's watchdog_state.json,
# keyed by worker session_id (same-name workers must not share one ladder);
# re-alert only when silence grew by another full threshold (escalation
# ladder: T, 2T, 3T, ...) or the entry is new. First alert at T. The basis
# (max worker-originated ts the silence was measured against) is snapshotted
# per entry: if the worker RECOVERED in between (basis moved forward), the
# ladder resets and the next silence episode alerts from scratch.
#
# Usage:   supervisor-watchdog <project-dir> [threshold_minutes]   (default 60)
# Cron:    */10 * * * * ~/.claude/supervisor/supervisor-watchdog '/path/to/repo' 60
set -uo pipefail

PROJECT_DIR="${1:-}"
THRESHOLD_MIN="${2:-60}"

# never let a cron job become noisy, whatever goes wrong below
trap 'exit 0' EXIT

[ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ] || exit 0
SUP_DIR="$PROJECT_DIR/.supervisor"
[ -d "$SUP_DIR" ] || exit 0
[[ "$THRESHOLD_MIN" =~ ^[0-9]+$ ]] || exit 0

python3 - "$SUP_DIR" "$THRESHOLD_MIN" <<'PYEOF' 2>/dev/null || exit 0
import datetime
import glob
import json
import os
import re
import socket
import sys

sup_dir, threshold_min = sys.argv[1], int(sys.argv[2])

SESSIONS_DIR = os.environ.get(
    "CLAUDE_SUPERVISOR_SESSIONS_DIR",
    os.path.expanduser("~/.claude/sessions"))

SHARD_NAME_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

# --- UDS delivery helpers (same mechanism as hooks/worker-stopfailure.py:
# messagingSocketPath liveness check, peerToken auth frame, bounded timeouts) ---
UDS_CONNECT_TIMEOUT = 1.0
UDS_SEND_TIMEOUT = 1.0


def load_sessions():
    out = []
    for p in glob.glob(os.path.join(SESSIONS_DIR, "*.json")):
        try:
            with open(p) as f:
                o = json.load(f)
            if isinstance(o, dict):
                out.append(o)
        except Exception:
            continue
    return out


def find_peer_token(pid, proc_start):
    if not isinstance(pid, int):
        return None
    for p in glob.glob(os.path.join(SESSIONS_DIR, "%d.*.key" % pid)):
        try:
            with open(p) as f:
                o = json.load(f)
            if not isinstance(o, dict):
                continue
            if proc_start and o.get("procStart") != proc_start:
                continue
            tok = o.get("peerToken")
            return tok if isinstance(tok, str) else None
        except Exception:
            continue
    return None


def send_uds(sock_path, token, body):
    frames = []
    if token:
        frames.append(json.dumps({"type": "auth", "token": token}))
    frames.append(json.dumps({
        "type": "user",
        "message": {"role": "user", "content": body},
    }))
    payload = ("\n".join(frames) + "\n").encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(UDS_CONNECT_TIMEOUT)
        s.connect(sock_path)
        s.settimeout(UDS_SEND_TIMEOUT)
        s.sendall(payload)
        return True
    except OSError:
        return False
    finally:
        try:
            s.close()
        except OSError:
            pass


def parse_ts(s):
    """ISO-8601 / RFC3339 tolerant parser; returns naive local time or None."""
    if not isinstance(s, str) or not s.strip():
        return None
    v = s.strip()
    if v.endswith(("Z", "z")):
        v = v[:-1] + "+00:00"
    try:
        d = datetime.datetime.fromisoformat(v)
        if d.tzinfo is not None:
            d = d.astimezone().replace(tzinfo=None)
        return d
    except ValueError:
        pass
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.datetime.strptime(v, fmt)
        except ValueError:
            continue
    return None


def load_ledger(path):
    try:
        with open(path) as f:
            st = json.load(f)
        if isinstance(st, dict):
            return st
    except Exception:
        pass
    return None  # unreadable/half-written ledger is the supervisor's business


def worker_silence_min(w):
    # only worker-originated timestamps count (report / response / register)
    cands = [
        parse_ts(w.get("last_report_ts")),
        parse_ts(w.get("last_response_ts")),
        parse_ts(w.get("registered_at")),
    ]
    ts = max([c for c in cands if c], default=None)
    if ts is None:
        return None
    return int((datetime.datetime.now() - ts).total_seconds() // 60), ts.isoformat()


def worker_basis(w):
    """Stable snapshot of the max worker-originated timestamp (ISO string):
    stored in the dedup record; if it changes between runs the worker has
    RECOVERED since the last alert and the escalation ladder resets."""
    cands = [
        parse_ts(w.get("last_report_ts")),
        parse_ts(w.get("last_response_ts")),
        parse_ts(w.get("registered_at")),
    ]
    ts = max([c for c in cands if c], default=None)
    return ts.isoformat() if ts is not None else None


# ---- enumerate ledgers: UUID shards first, flat fallback when zero shards ----
ledgers = []  # (state, ledger_dir)
try:
    names = sorted(os.listdir(sup_dir))
except OSError:
    sys.exit(0)
for name in names:
    if not SHARD_NAME_RE.match(name):
        continue
    sd = os.path.join(sup_dir, name)
    st = load_ledger(os.path.join(sd, "state.json"))
    if st is not None:
        ledgers.append((st, sd))

if not ledgers:
    st = load_ledger(os.path.join(sup_dir, "state.json"))
    if st is not None:
        ledgers.append((st, sup_dir))

if not ledgers:
    sys.exit(0)

sessions = load_sessions()

# registry entries: the heartbeat clock for supervisor self-triage lives in
# .supervisor/registry.json (entries refreshed by `registry.py heartbeat` on
# every patrol cron tick, by protocol). Missing/unreadable registry -> no
# heartbeat clock -> supervisor triage silently disabled (worker watch
# unaffected).
registry_entries = []
try:
    with open(os.path.join(sup_dir, "registry.json")) as f:
        reg = json.load(f)
    if isinstance(reg, dict):
        for ent in reg.get("supervisors") or []:
            if isinstance(ent, dict):
                registry_entries.append(ent)
except Exception:
    pass

now = datetime.datetime.now()
all_alert_names = []
# supervisor self-triage hits are printed/notified inline below; no
# aggregate list is needed (the worker section keeps its own to_alert list
# because its delivery is UDS-routed and batched).

for st, ledger_dir in ledgers:
    if st.get("done"):
        continue

    wd_state_path = os.path.join(ledger_dir, "watchdog_state.json")

    # ---- supervisor self-triage (same shard; skipped for done ledgers) ----
    # heartbeat clock lives in the REGISTRY entry (the supervisor refreshes it
    # on every patrol cron tick via `registry.py heartbeat`, by protocol);
    # state.json itself has no heartbeat field.
    sup_sid = st.get("supervisor_session_id")
    sup_name = st.get("supervisor_name") or "(unnamed)"
    # wd_state is shared by self-triage (key supervisor:<sid>) and the worker
    # ladder below; load once here.
    wd_state = {}
    try:
        with open(wd_state_path) as f:
            wd_state = json.load(f)
        if not isinstance(wd_state, dict):
            wd_state = {}
    except Exception:
        wd_state = {}
    reg_hb_ts = None
    if isinstance(sup_sid, str) and sup_sid:
        for ent in registry_entries:
            if isinstance(ent, dict) and ent.get("session_id") == sup_sid:
                reg_hb_ts = parse_ts(ent.get("heartbeat_ts"))
                break
    if reg_hb_ts is not None \
            and (now - reg_hb_ts).total_seconds() / 60.0 > threshold_min:
            sock_alive = False
            # scan ALL records matching this sid (not just the first):
            # resume leaves stale session json behind; the worker-routing
            # loop below only breaks on a LIVE socket -- keep the same
            # defensive posture so a stale record can't fake a DEAD verdict.
            for o in sessions:
                if o.get("sessionId") == sup_sid:
                    sp = o.get("messagingSocketPath")
                    if isinstance(sp, str) and sp and os.path.exists(sp):
                        sock_alive = True
                        break
            mode = "DEGRADED" if sock_alive else "DEAD"
            rec = wd_state.get("supervisor:%s" % sup_sid) or {}
            prev_hb = rec.get("basis")
            hb_iso = reg_hb_ts.isoformat()
            mins_stale = int((now - reg_hb_ts).total_seconds() // 60)
            # ladder reset: heartbeat moved forward since the last alert ->
            # the supervisor recovered in between; alert from scratch next time
            if hb_iso != prev_hb or mins_stale \
                    >= (rec.get("last_alert_min") or 0) + threshold_min:
                wd_state["supervisor:%s" % sup_sid] = {
                    "last_alert_min": mins_stale,
                    "basis": hb_iso,
                    "last_alert_ts": now.strftime("%Y-%m-%d %H:%M:%S"),
                }
                # persist BEFORE notifying (worst case: one lost notification
                # on crash, never a duplicate storm)
                try:
                    import tempfile
                    fd, tmp = tempfile.mkstemp(
                        dir=os.path.dirname(wd_state_path) or ".",
                        prefix=".wdstate-")
                    with os.fdopen(fd, "w") as f:
                        json.dump(wd_state, f, ensure_ascii=False, indent=2)
                    os.replace(tmp, wd_state_path)
                except Exception:
                    pass
                mins = mins_stale
                if mode == "DEAD":
                    body = ("SUPERVISOR DEAD: '%s' (sid %s) 心跳停更 %d 分钟且"
                            "会话 socket 不存在——会话已死（/exit / crash 后未"
                            " resume）。恢复：在项目目录执行 claude --resume"
                            " %s，resume 后 supervisor 会走 register 幂等"
                            "重建自愈。" % (sup_name, sup_sid, mins, sup_sid))
                else:
                    body = ("SUPERVISOR DEGRADED: '%s' (sid %s) 心跳停更 %d 分钟"
                            "但会话仍活着（socket 在）——疑似模型劣化（响应 cron"
                            "但零产出，同 09-07 事故形态）。需人工介入：/compact"
                            " 或换模型后 resume。若会话实际已无响应（kill -9 等"
                            "残留 socket 场景），按 DEAD 处理：claude --resume"
                            " %s。" % (sup_name, sup_sid, mins, sup_sid))
                print(body)
                # notification to the USER (the supervisor may be the patient)
                if not os.environ.get("CLAUDE_SUPERVISOR_WATCHDOG_NO_NOTIFY"):
                    try:
                        import subprocess
                        subprocess.run(
                            ["osascript", "-e",
                             'on run argv\n'
                             'display notification (item 1 of argv) with title'
                             ' (item 2 of argv)\n'
                             'end run',
                             "--", body, "supervisor-watchdog"],
                            check=False, timeout=10,
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
                    except Exception:
                        pass

    overdue = []  # (name, session_id, phase, silence_min, basis)
    for w in st.get("workers") or []:
        if not isinstance(w, dict) or w.get("phase") == "done":
            continue
        m = worker_silence_min(w)
        if m is None:
            continue
        minutes, basis = m
        if minutes > threshold_min:
            overdue.append((str(w.get("name") or "?"),
                            str(w.get("session_id") or "(未记录)"),
                            str(w.get("phase") or "?"), minutes, basis))
    if not overdue:
        continue

    # ---- alert de-duplication (escalation ladder), per shard ----

    to_alert = []
    for name, sid, phase, m, basis in overdue:
        rec = wd_state.get(sid) or {}
        prev = rec.get("last_alert_silence_min")
        prev_basis = rec.get("basis")
        # ladder reset: the worker reported/responded since the last alert
        # (basis moved) -> this is a NEW silence episode, alert from scratch
        if basis is not None and prev_basis is not None and basis != prev_basis:
            prev = None
        if prev is None or m >= prev + threshold_min:
            to_alert.append((name, sid, phase, m))
            wd_state[sid] = {"last_alert_silence_min": m,
                             "basis": basis,
                             "last_alert_ts": now.strftime(
                                 "%Y-%m-%d %H:%M:%S")}

    if not to_alert:
        continue  # all suppressed by dedup -> stay completely silent

    # persist de-dup state atomically BEFORE alerting (worst case: one lost
    # alert on crash, never a duplicate storm)
    try:
        import tempfile
        fd, tmp = tempfile.mkstemp(
            dir=os.path.dirname(wd_state_path) or ".",
            prefix=".wdstate-")
        with os.fdopen(fd, "w") as f:
            json.dump(wd_state, f, ensure_ascii=False, indent=2)
        os.replace(tmp, wd_state_path)
    except Exception:
        pass

    # ---- route to THIS shard's supervisor by session_id, never by name ----
    want_sid = st.get("supervisor_session_id")
    target = None
    if isinstance(want_sid, str) and want_sid:
        for o in sessions:
            sock = o.get("messagingSocketPath")
            if o.get("sessionId") == want_sid \
                    and isinstance(sock, str) and sock and os.path.exists(sock):
                target = (sock, find_peer_token(o.get("pid"),
                                                o.get("procStart")))
                break

    if target:
        lines = ["WATCHDOG ALERT",
                 f"阈值: 超过 {threshold_min} 分钟无 worker 主动消息", ""]
        for name, sid, phase, m in to_alert:
            lines.append(f"- worker '{name}' (phase: {phase}, "
                         f"session_id: {sid}) 已静默 {m} 分钟")
        lines += ["",
                  "请巡检: STATUS CHECK 该 worker；无回应则升级用户",
                  "（恢复指引: claude --resume <session-id> / codex resume）。"]
        body = "\n".join(lines)
        try:
            send_uds(target[0], target[1], body)
        except Exception:
            pass

    all_alert_names.extend(n for n, _, _, _ in to_alert)

# best-effort macOS notification: text passed via argv, never interpolated
# into AppleScript source (worker names are untrusted).
# CLAUDE_SUPERVISOR_WATCHDOG_NO_NOTIFY=1 disables it (used by tests).
if all_alert_names \
        and not os.environ.get("CLAUDE_SUPERVISOR_WATCHDOG_NO_NOTIFY"):
    try:
        import subprocess
        names = ", ".join(all_alert_names)
        subprocess.run(
            ["osascript", "-e",
             'on run argv\n'
             'display notification (item 1 of argv) with title (item 2 of argv)\n'
             'end run',
             "--", f"worker 静默超时: {names}", "supervisor-watchdog"],
            check=False, timeout=10,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
PYEOF
exit 0
