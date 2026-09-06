#!/usr/bin/env bash
# supervisor-watchdog: detect overdue (interrupted/silent) workers and alert
# the supervisor. Cron-friendly: always exits 0, never noisy.
#
# Worker sessions killed by 429 / network loss / process death cannot send any
# message themselves (no WORKER REPORT will ever arrive). This script is the
# external timer the passive supervisor lacks.
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
# Alert de-duplication: per-worker state in the shard's watchdog_state.json;
# re-alert only when silence grew by another full threshold (escalation
# ladder: T, 2T, 3T, ...) or the entry is new. First alert at T.
#
# Usage:   supervisor-watchdog <project-dir> [threshold_minutes]   (default 60)
# Cron:    */10 * * * * ~/.agent-mail/supervisor-watchdog '/path/to/repo' 60
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
    return int((datetime.datetime.now() - ts).total_seconds() // 60)


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

now = datetime.datetime.now()
all_alert_names = []

for st, ledger_dir in ledgers:
    if st.get("done"):
        continue

    overdue = []  # (name, session_id, phase, silence_min)
    for w in st.get("workers") or []:
        if not isinstance(w, dict) or w.get("phase") == "done":
            continue
        m = worker_silence_min(w)
        if m is not None and m > threshold_min:
            overdue.append((str(w.get("name") or "?"),
                            str(w.get("session_id") or "(未记录)"),
                            str(w.get("phase") or "?"), m))
    if not overdue:
        continue

    # ---- alert de-duplication (escalation ladder), per shard ----
    wd_state_path = os.path.join(ledger_dir, "watchdog_state.json")
    wd_state = {}
    try:
        with open(wd_state_path) as f:
            wd_state = json.load(f)
        if not isinstance(wd_state, dict):
            wd_state = {}
    except Exception:
        wd_state = {}

    to_alert = []
    for name, sid, phase, m in overdue:
        rec = wd_state.get(name) or {}
        prev = rec.get("last_alert_silence_min")
        if prev is None or m >= prev + threshold_min:
            to_alert.append((name, sid, phase, m))
            wd_state[name] = {"last_alert_silence_min": m,
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
