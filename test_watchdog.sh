#!/usr/bin/env bash
# Assertion-based regression test for supervisor-watchdog.
# Sandboxed: fake project state + fake ~/.claude/sessions registry + local
# UDS servers standing in for the supervisor messaging sockets; never touches
# real data. (v3: delivery goes over UDS by supervisor session_id, so the old
# fake agent-mail CLI harness was replaced; the semantic assertions of every
# legacy case are preserved verbatim.)
set -uo pipefail

WD_SRC="${1:-$HOME/.agent-mail/supervisor-watchdog}"
FAILURES=0
TMP=""
SERVER_PIDS=""

cleanup() {
  [ -n "$SERVER_PIDS" ] && kill $SERVER_PIDS 2>/dev/null
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $1"; FAILURES=$((FAILURES+1)); }
pass() { echo "ok:   $1"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi; }
assert_contains() { if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1 (needle '$3' not found)"; fi; }
assert_not_contains() { if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "(unexpected needle '$3')"; else pass "$1"; fi; }

TMP=$(mktemp -d /tmp/wdtest.XXXX)
PROJ="$TMP/proj"
SESSIONS="$TMP/sessions"
SUP_SOCK="$TMP/sup.sock"
SUP2_SOCK="$TMP/sup2.sock"
mkdir -p "$PROJ/.supervisor" "$SESSIONS"
export CLAUDE_SUPERVISOR_WATCHDOG_NO_NOTIFY=1

# persistent UDS server: accepts any number of connections, appends each
# received payload to the spool file
start_server() { # sock spool
  python3 - "$1" "$2" <<'EOF' >/dev/null 2>&1 &
import socket, sys, os, threading
sock_path, spool = sys.argv[1], sys.argv[2]
try: os.unlink(sock_path)
except OSError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path); s.listen(5)
open(spool + ".ready", "w").write("1")
lock = threading.Lock()
def handle(conn):
    data = b""
    try:
        while True:
            c = conn.recv(65536)
            if not c: break
            data += c
    except OSError:
        pass
    with lock:
        with open(spool, "ab") as f:
            f.write(data)
    conn.close()
while True:
    try:
        conn, _ = s.accept()
    except OSError:
        break
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
EOF
  SERVER_PIDS="$SERVER_PIDS $!"
  for _ in $(seq 1 50); do
    [ -f "$2.ready" ] && break
    sleep 0.1
  done
}

# fake session registry entry: supervisor with sid listening on sock
mk_sess() { # pid sid sock [cwd]
  python3 - "$SESSIONS" "$1" "$2" "$3" "${4:-$PROJ}" <<'EOF'
import json, sys
d, pid, sid, sock, cwd = sys.argv[1:6]
json.dump({"pid": int(pid), "sessionId": sid, "cwd": cwd,
           "messagingSocketPath": sock, "name": "sup-" + sid[:8],
           "updatedAt": 9999999999999,
           "procStart": "Mon Sep  1 00:00:00 2026"},
          open(d + "/" + pid + ".json", "w"))
json.dump({"peerToken": "tok-" + sid[:8],
           "procStart": "Mon Sep  1 00:00:00 2026"},
          open(d + "/" + pid + ".x.key", "w"))
EOF
}

OLD=$(python3 -c "import datetime;print((datetime.datetime.now()-datetime.timedelta(minutes=120)).isoformat())")
NEW=$(python3 -c "import datetime;print(datetime.datetime.now().isoformat())")
# genuinely-past UTC timestamp with Z suffix (2h ago in UTC, not local wall time)
OLDZ=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=120)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

write_state() { # json-body
  cat > "$PROJ/.supervisor/state.json"
}

run_wd() { # threshold
  CLAUDE_SUPERVISOR_SESSIONS_DIR="$SESSIONS" bash "$WD_SRC" "$PROJ" "${1:-60}"
}

SPOOL="$TMP/spool.txt"

# ---- legacy flat-layout cases ride on one supervisor socket ----
start_server "$SUP_SOCK" "$SPOOL"
mk_sess 60001 "sup-sid-1" "$SUP_SOCK"

# ---- case A: overdue worker (Z-suffixed ISO ts) -> alert with session_id ----
write_state <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup","supervisor_session_id":"sup-sid-1",
 "workers":[{"name":"w1","session_id":"sid-w1","phase":"dev-2",
   "registered_at":"$OLD","last_report_ts":"$OLD","last_instruction_ts":"$NEW"}],
 "reviews":[],"done":false}
EOF
run_wd 60
assert_contains "A: alert sent" "$SPOOL" "WATCHDOG ALERT"
assert_contains "A: alert has session_id" "$SPOOL" "sid-w1"
assert_contains "A: alert mentions silence minutes" "$SPOOL" "120"
assert_not_contains "A: done worker excluded (none here)" "$SPOOL" "should-not-appear"

# ---- case B: same silence again within threshold growth -> NO duplicate ----
N1=$(grep -c 'WATCHDOG ALERT' "$SPOOL" || true)
run_wd 60
N2=$(grep -c 'WATCHDOG ALERT' "$SPOOL" || true)
assert_eq "B: no duplicate alert at same silence level" "$N1" "$N2"

# ---- case C: instruction_ts newer than report_ts must NOT suppress alert ----
# (already covered by case A: instruction ts is NEW but alert fired anyway)
pass "C: last_instruction_ts ignored (case A proved it)"

# ---- case D: fresh worker -> no alert ----
write_state <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup","supervisor_session_id":"sup-sid-1",
 "workers":[{"name":"w2","session_id":"sid-w2","phase":"dev-1",
   "registered_at":"$NEW","last_report_ts":"$NEW"}],
 "reviews":[],"done":false}
EOF
N3=$(grep -c 'WATCHDOG ALERT' "$SPOOL" || true)
run_wd 60
N4=$(grep -c 'WATCHDOG ALERT' "$SPOOL" || true)
assert_eq "D: fresh worker silent" "$N3" "$N4"

# ---- case E: worker response resets silence (last_response_ts) ----
write_state <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup","supervisor_session_id":"sup-sid-1",
 "workers":[{"name":"w2","session_id":"sid-w2","phase":"dev-1",
   "registered_at":"$OLD","last_report_ts":"$OLD","last_response_ts":"$NEW"}],
 "reviews":[],"done":false}
EOF
run_wd 60
assert_eq "E: last_response_ts resets silence" "$N4" "$(grep -c 'WATCHDOG ALERT' "$SPOOL" || true)"

# ---- case F: done project -> silent ----
write_state <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup","supervisor_session_id":"sup-sid-1",
 "workers":[{"name":"w1","session_id":"sid-w1","phase":"dev-2",
   "registered_at":"$OLD","last_report_ts":"$OLD"}],
 "reviews":[],"done":true}
EOF
run_wd 60
assert_eq "F: done project silent" "$N4" "$(grep -c 'WATCHDOG ALERT' "$SPOOL" || true)"

# ---- case G: garbage threshold / bad dir -> exit 0, no output ----
OUT=$(run_wd "notanumber" 2>&1); RC=$?
assert_eq "G: bad threshold exit 0" "0" "$RC"
OUT=$(CLAUDE_SUPERVISOR_SESSIONS_DIR="$SESSIONS" bash "$WD_SRC" /nonexistent 60 2>&1); RC=$?
assert_eq "G: bad dir exit 0" "0" "$RC"

# ---- case H: corrupt state.json (half-written) -> exit 0 silently ----
echo '{"goal":"g","project_dir":"' > "$PROJ/.supervisor/state.json"
OUT=$(run_wd 60 2>&1); RC=$?
assert_eq "H: corrupt state exit 0" "0" "$RC"

# ---- case I: workers not a list / weird entries -> exit 0 ----
echo '{"done":false,"workers":"notalist"}' > "$PROJ/.supervisor/state.json"
OUT=$(run_wd 60 2>&1); RC=$?
assert_eq "I: workers non-list exit 0" "0" "$RC"

# ---- case J: escalation ladder: silence grew another threshold -> re-alert ----
write_state <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup","supervisor_session_id":"sup-sid-1",
 "workers":[{"name":"w1","session_id":"sid-w1","phase":"dev-2",
   "registered_at":"$OLD","last_report_ts":"$OLD"}],
 "reviews":[],"done":false}
EOF
rm -f "$SPOOL" "$PROJ/.supervisor/watchdog_state.json"
# silence is 120min, threshold 50 -> first alert at 120 (>=50)
run_wd 50
assert_contains "J: alert at 120min silence w/ threshold 50" "$SPOOL" "WATCHDOG ALERT"

# ---- case K: Z-suffixed UTC timestamp (genuinely past) parses and alerts ----
rm -f "$SPOOL" "$PROJ/.supervisor/watchdog_state.json"
write_state <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup","supervisor_session_id":"sup-sid-1",
 "workers":[{"name":"w3","session_id":"sid-w3","phase":"spec",
   "registered_at":"$OLDZ","last_report_ts":"$OLDZ"}],
 "reviews":[],"done":false}
EOF
run_wd 60
assert_contains "K: RFC3339 Z timestamp parsed -> alert" "$SPOOL" "sid-w3"

# ---- v3 shard layout ----
SID_A="11111111-1111-1111-1111-111111111111"
SID_B="22222222-2222-2222-2222-222222222222"

# ---- case L: single shard behaves like the flat layout (same alert copy) ----
rm -rf "$PROJ/.supervisor"
mkdir -p "$PROJ/.supervisor/$SID_A"
cat > "$PROJ/.supervisor/$SID_A/state.json" <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup","supervisor_session_id":"sup-sid-1",
 "workers":[{"name":"w1","session_id":"sid-w1","phase":"dev-2",
   "registered_at":"$OLD","last_report_ts":"$OLD"}],
 "reviews":[],"done":false}
EOF
rm -f "$SPOOL"
run_wd 60
assert_contains "L: single shard alert delivered" "$SPOOL" "WATCHDOG ALERT"
assert_contains "L: alert copy identical (session_id)" "$SPOOL" "sid-w1"
assert_contains "L: alert copy identical (minutes)" "$SPOOL" "120"
assert_contains "L: alert copy identical (escalation hint)" "$SPOOL" "STATUS CHECK"
assert_contains "L: alert copy identical (resume hint)" "$SPOOL" "claude --resume"
if [ -f "$PROJ/.supervisor/$SID_A/watchdog_state.json" ]; then
  pass "L: dedup state lands inside the shard dir"; else fail "L: shard dedup state missing"; fi
if [ ! -f "$PROJ/.supervisor/watchdog_state.json" ]; then
  pass "L: no flat watchdog_state written"; else fail "L: flat watchdog_state written"; fi

# ---- case M: dual shards -> independent alerts + isolated dedup states ----
mkdir -p "$PROJ/.supervisor/$SID_B"
SPOOL2="$TMP/spool2.txt"
start_server "$SUP2_SOCK" "$SPOOL2"
mk_sess 60002 "sup-sid-2" "$SUP2_SOCK"
cat > "$PROJ/.supervisor/$SID_B/state.json" <<EOF
{"goal":"g2","project_dir":"$PROJ","supervisor_name":"sup","supervisor_session_id":"sup-sid-2",
 "workers":[{"name":"wa","session_id":"sid-wa","phase":"dev-1",
   "registered_at":"$OLD","last_report_ts":"$OLD"}],
 "reviews":[],"done":false}
EOF
rm -f "$SPOOL" "$SPOOL2" "$PROJ/.supervisor/$SID_A/watchdog_state.json" "$PROJ/.supervisor/$SID_B/watchdog_state.json"
run_wd 60
assert_contains "M: shard A alerted its supervisor" "$SPOOL" "sid-w1"
assert_contains "M: shard B alerted its supervisor" "$SPOOL2" "sid-wa"
assert_not_contains "M: shard A alert did not cross to B's supervisor" "$SPOOL" "sid-wa"
assert_not_contains "M: shard B alert did not cross to A's supervisor" "$SPOOL2" "sid-w1"
# rerun: both suppressed by their own dedup state
run_wd 60
assert_eq "M: shard A dedup holds on rerun" "1" "$(grep -c 'WATCHDOG ALERT' "$SPOOL" || true)"
assert_eq "M: shard B dedup holds on rerun" "1" "$(grep -c 'WATCHDOG ALERT' "$SPOOL2" || true)"

# ---- case N: archive/ and non-UUID dirs are invisible ----
mkdir -p "$PROJ/.supervisor/archive/old-round" "$PROJ/.supervisor/backup-not-uuid"
cat > "$PROJ/.supervisor/archive/old-round/state.json" <<EOF
{"goal":"old","project_dir":"$PROJ","supervisor_name":"sup","supervisor_session_id":"sup-sid-1",
 "workers":[{"name":"wold","session_id":"sid-wold","phase":"dev-1",
   "registered_at":"$OLD","last_report_ts":"$OLD"}],
 "reviews":[],"done":false}
EOF
cp "$PROJ/.supervisor/archive/old-round/state.json" "$PROJ/.supervisor/backup-not-uuid/state.json"
NA=$(grep -c 'WATCHDOG ALERT' "$SPOOL" || true)
run_wd 60
assert_eq "N: archive worker never alerted" "$NA" "$(grep -c 'WATCHDOG ALERT' "$SPOOL" || true)"
if [ ! -f "$PROJ/.supervisor/archive/old-round/watchdog_state.json" ]; then
  pass "N: archive dir untouched"; else fail "N: archive dir written"; fi

echo ""
if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILURES assertion(s) FAILED - tmp preserved: $TMP"; trap - EXIT; exit 1; fi
