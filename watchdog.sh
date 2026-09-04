#!/usr/bin/env bash
# supervisor-watchdog: detect overdue (interrupted/silent) workers and alert
# the supervisor via agent-mail. Cron-friendly: always exits 0, never noisy.
#
# Worker sessions killed by 429 / network loss / process death cannot send any
# message themselves (no WORKER REPORT will ever arrive). This script is the
# external timer the passive supervisor lacks.
#
# Silence clock = last WORKER-ORIGINATED event only (last_report_ts /
# last_response_ts / registered_at). last_instruction_ts is deliberately
# ignored: a STATUS CHECK from the supervisor must NOT reset the clock,
# otherwise "alert -> check -> clock reset" loops forever without escalation.
#
# Alert de-duplication: per-worker state in .supervisor/watchdog_state.json;
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
STATE="$PROJECT_DIR/.supervisor/state.json"
[ -f "$STATE" ] || exit 0
[[ "$THRESHOLD_MIN" =~ ^[0-9]+$ ]] || exit 0

# resolve the agent-mail CLI: prefer the copy next to this script, then
# AGENT_MAIL_HOME, then the default home. Data still goes to AGENT_MAIL_HOME.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIL_HOME="${AGENT_MAIL_HOME:-$HOME/.agent-mail}"
if [ -x "$SCRIPT_DIR/agent-mail" ]; then
  CLI="$SCRIPT_DIR/agent-mail"
elif [ -x "$MAIL_HOME/agent-mail" ]; then
  CLI="$MAIL_HOME/agent-mail"
else
  exit 0
fi

python3 - "$STATE" "$THRESHOLD_MIN" "$CLI" <<'PYEOF' 2>/dev/null || exit 0
import datetime
import json
import os
import subprocess
import sys

state_path, threshold_min, cli = sys.argv[1], int(sys.argv[2]), sys.argv[3]

try:
    with open(state_path) as f:
        st = json.load(f)
except Exception:
    sys.exit(0)  # unreadable/half-written ledger is the supervisor's business

if not isinstance(st, dict) or st.get("done"):
    sys.exit(0)


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


now = datetime.datetime.now()
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
    sys.exit(0)

# ---- alert de-duplication (escalation ladder) ----
wd_state_path = os.path.join(os.path.dirname(state_path), "watchdog_state.json")
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
                          "last_alert_ts": now.strftime("%Y-%m-%d %H:%M:%S")}

# nothing new to alert on (all suppressed by dedup) -> stay completely silent
if not to_alert:
    sys.exit(0)

# persist de-dup state atomically BEFORE alerting (worst case: one lost alert
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

sup = st.get("supervisor_name") or "supervisor"
lines = ["WATCHDOG ALERT",
         f"阈值: 超过 {threshold_min} 分钟无 worker 主动消息", ""]
for name, sid, phase, m in to_alert:
    lines.append(f"- worker '{name}' (phase: {phase}, session_id: {sid}) "
                 f"已静默 {m} 分钟")
lines += ["",
          "请巡检: STATUS CHECK 该 worker；无回应则升级用户",
          "（恢复指引: claude --resume <session-id> / codex resume）。"]
body = "\n".join(lines)

mail_home = os.environ.get("AGENT_MAIL_HOME", os.path.expanduser("~/.agent-mail"))
try:
    env = dict(os.environ, AGENT_MAIL_HOME=mail_home)
    subprocess.run([cli, "send", sup, body, "--from", "watchdog"],
                   check=False, timeout=15, env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
except Exception:
    pass

# best-effort macOS notification: text passed via argv, never interpolated
# into AppleScript source (worker names are untrusted)
try:
    names = ", ".join(n for n, _, _, _ in to_alert)
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
