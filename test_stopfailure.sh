#!/usr/bin/env bash
# Assertion-based regression test for the StopFailure hook.
# Uses a fully sandboxed fake environment (sessions dir, project state, UDS
# server); never touches real ~/.claude or real projects.
#
# Any failed assertion exits non-zero and PRESERVES the tmp dir for triage.
set -uo pipefail

HOOK="${1:-$HOME/.claude/hooks/claude-supervisor/worker-stopfailure.py}"
FAILURES=0
TMP=""

cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES+1))
}

pass() { echo "ok:   $1"; }

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi
}

assert_contains() { # desc haystack_file needle
  if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (needle '$3' not found)"; fi
}

json_field() { # file python-expr
  python3 -c "
import json,sys
objs=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
d=eval(sys.argv[2])
print(d)
" "$1" "$2"
}

# ---------- sandbox setup ----------
TMP=$(mktemp -d /tmp/sftest.XXXX)
PROJ="$TMP/proj"; SUB="$PROJ/src/deep"
SUP_SOCK="$TMP/sup.sock"
mkdir -p "$PROJ/.supervisor" "$SUB" "$TMP/sessions"

# fake supervisor session + published peerToken (procStart must match)
python3 - "$TMP/sessions" "$SUP_SOCK" <<'EOF'
import json, sys
d, sock = sys.argv[1], sys.argv[2]
json.dump({"pid": 99999, "sessionId": "sup-session-1", "cwd": d.replace("/sessions","/proj"),
           "messagingSocketPath": sock, "name": "supervisor",
           "updatedAt": 9999999999999,
           "procStart": "Mon Sep  1 00:00:00 2026"},
          open(d + "/99999.json", "w"))
json.dump({"peerToken": "fake-token-123",
           "procStart": "Mon Sep  1 00:00:00 2026"},
          open(d + "/99999.abc.key", "w"))
json.dump({"pid": 88888, "sessionId": "worker-session-1", "cwd": "/nowhere",
           "messagingSocketPath": "/nonexistent.sock", "name": "worker-1",
           "updatedAt": 1, "procStart": "Mon Sep  1 00:00:00 2026"},
          open(d + "/88888.json", "w"))
# decoy: same NAME as supervisor, different project -> must never be picked
json.dump({"pid": 77777, "sessionId": "sup-session-2", "cwd": "/other/project",
           "messagingSocketPath": "/nonexistent.sock", "name": "supervisor",
           "updatedAt": 8888888888888,
           "procStart": "Mon Sep  1 00:00:00 2026"},
          open(d + "/77777.json", "w"))
EOF

# project state at repo root; note supervisor cwd == project dir
cat > "$PROJ/.supervisor/state.json" <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"supervisor","supervisor_session_id":"sup-session-1",
 "workers":[{"name":"worker-1","session_id":"worker-session-1","phase":"dev-2","registered_at":"2026-09-04T20:00:00"}],
 "reviews":[],"done":false}
EOF

# UDS server: poll for bind readiness instead of fixed sleep
start_server() { # sock outfile
  python3 - "$1" "$2" <<'EOF' &
import socket, sys, os
sock_path, out = sys.argv[1], sys.argv[2]
try: os.unlink(sock_path)
except OSError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path); s.listen(1); s.settimeout(10)
open(out + ".ready", "w").write("1")
try:
    conn, _ = s.accept()
    data = b""
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk: break
            data += chunk
    except OSError:
        pass
    open(out, "wb").write(data)
    conn.close()
except OSError:
    open(out, "wb").write(b"")
s.close()
EOF
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    [ -f "$2.ready" ] && break
    sleep 0.1
  done
}

fire_hook() { # payload-json [extra-env]
  echo "$1" | CLAUDE_SUPERVISOR_SESSIONS_DIR="$TMP/sessions" python3 "$HOOK"
}

interrupts="$PROJ/.supervisor/interrupts.jsonl"

# ---------- case 1: registered worker, 429, delivered via UDS ----------
start_server "$SUP_SOCK" "$TMP/received1.txt"
PAYLOAD='{"hook_event_name":"StopFailure","session_id":"worker-session-1","cwd":"'"$PROJ"'","transcript_path":"/tmp/none.jsonl","error":"429 rate limited: too many requests, retries exhausted"}'
fire_hook "$PAYLOAD"
wait $SERVER_PID 2>/dev/null || true

assert_contains "case1 auth frame written" "$TMP/received1.txt" '"type": "auth", "token": "fake-token-123"'
assert_contains "case1 user frame written" "$TMP/received1.txt" '"type": "user"'
assert_contains "case1 body has WORKER INTERRUPTED" "$TMP/received1.txt" 'WORKER INTERRUPTED'
assert_contains "case1 kind=rate-limit" "$TMP/received1.txt" 'kind: rate-limit'
assert_contains "case1 phase=dev-2" "$TMP/received1.txt" 'phase: dev-2'
D1=$(json_field "$interrupts" "objs[-1]['delivered']")
assert_eq "case1 delivered=true" "True" "$D1"
H1=$(json_field "$interrupts" "objs[-1]['handled']")
assert_eq "case1 handled=false" "False" "$H1"
I1=$(json_field "$interrupts" "objs[-1]['worker_session_id']")
assert_eq "case1 ledger has session_id" "worker-session-1" "$I1"

# ---------- case 2: unregistered session in same dir -> zero write ----------
N_BEFORE=$(grep -c . "$interrupts" || true)
fire_hook '{"hook_event_name":"StopFailure","session_id":"some-random-session","cwd":"'"$PROJ"'","error":"429"}'
N_AFTER=$(grep -c . "$interrupts" || true)
assert_eq "case2 no ledger write for stranger session" "$N_BEFORE" "$N_AFTER"

# ---------- case 3: empty workers[] -> zero write (strict gate) ----------
python3 - "$PROJ/.supervisor/state.json" <<'EOF'
import json, sys
p = sys.argv[1]
st = json.load(open(p)); st["workers"] = []
json.dump(st, open(p, "w"))
EOF
fire_hook "$PAYLOAD"
N2=$(grep -c . "$interrupts" || true)
assert_eq "case3 empty workers ledger -> no write" "$N_AFTER" "$N2"
python3 - "$PROJ/.supervisor/state.json" <<'EOF'
import json, sys
p = sys.argv[1]
st = json.load(open(p))
st["workers"] = [{"name":"worker-1","session_id":"worker-session-1","phase":"dev-2","registered_at":"2026-09-04T20:00:00"}]
json.dump(st, open(p, "w"))
EOF

# ---------- case 4: subdirectory cwd (state found by walking up) ----------
fire_hook '{"hook_event_name":"StopFailure","session_id":"worker-session-1","cwd":"'"$SUB"'","error":"ETIMEDOUT connection timed out"}'
N3=$(grep -c . "$interrupts" || true)
assert_eq "case4 subdir cwd found state (ledger grew)" "$((N2+1))" "$N3"
K4=$(json_field "$interrupts" "objs[-1]['kind']")
assert_eq "case4 kind=network" "network" "$K4"

# ---------- case 5: project done -> zero write ----------
python3 - "$PROJ/.supervisor/state.json" <<'EOF'
import json, sys
p = sys.argv[1]
st = json.load(open(p)); st["done"] = True
json.dump(st, open(p, "w"))
EOF
fire_hook "$PAYLOAD"
N4=$(grep -c . "$interrupts" || true)
assert_eq "case5 done project -> no write" "$N3" "$N4"
python3 - "$PROJ/.supervisor/state.json" <<'EOF'
import json, sys
p = sys.argv[1]
st = json.load(open(p)); st["done"] = False
json.dump(st, open(p, "w"))
EOF

# ---------- case 6: socket file EXISTS but nobody listening -> connect refused ----------
DEAD_SOCK="$TMP/dead.sock"
python3 - "$DEAD_SOCK" <<'EOF'
import socket, sys
# create then abandon: socket file exists, no listener
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1]); s.close()
EOF
python3 - "$TMP/sessions/99999.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["messagingSocketPath"] = p.replace("99999.json","") + "dead.sock"
json.dump(d, open(p, "w"))
EOF
T0=$(python3 -c "import time; print(time.time())")
fire_hook "$PAYLOAD"
T1=$(python3 -c "import time; print(time.time())")
ELAPSED=$(python3 -c "print(int($T1-$T0))")
D6=$(json_field "$interrupts" "objs[-1]['delivered']")
assert_eq "case6 refused socket -> delivered=false (persisted)" "False" "$D6"
python3 - "$TMP/sessions/99999.json" "$SUP_SOCK" <<'EOF'
import json, sys
p, sock = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["messagingSocketPath"] = sock
json.dump(d, open(p, "w"))
EOF
if [ "$ELAPSED" -le 5 ]; then pass "case6 bounded time (${ELAPSED}s)"; else fail "case6 too slow: ${ELAPSED}s"; fi

# ---------- case 7: key file missing -> no auth frame, still delivered ----------
rm "$TMP/sessions/99999.abc.key"
start_server "$SUP_SOCK" "$TMP/received7.txt"
fire_hook "$PAYLOAD"
wait $SERVER_PID 2>/dev/null || true
if grep -qF '"type": "auth"' "$TMP/received7.txt"; then
  fail "case7 auth frame absent when key missing"
else pass "case7 no auth frame without key"; fi
assert_contains "case7 user frame still delivered" "$TMP/received7.txt" 'WORKER INTERRUPTED'
D7=$(json_field "$interrupts" "objs[-1]['delivered']")
assert_eq "case7 delivered=true (auth optional)" "True" "$D7"

# ---------- case 8: malformed stdin -> exit 0 ----------
echo 'not json' | CLAUDE_SUPERVISOR_SESSIONS_DIR="$TMP/sessions" python3 "$HOOK"
assert_eq "case8 malformed stdin exit 0" "0" "$?"

# ---------- case 9: unsupervised dir -> exit 0, no file ----------
mkdir -p "$TMP/bare"
echo '{"hook_event_name":"StopFailure","session_id":"worker-session-1","cwd":"'"$TMP/bare"'","error":"429"}' \
  | CLAUDE_SUPERVISOR_SESSIONS_DIR="$TMP/sessions" python3 "$HOOK"
assert_eq "case9 unsupervised exit 0" "0" "$?"
if [ ! -f "$TMP/bare/.supervisor/interrupts.jsonl" ]; then pass "case9 no file created"; else fail "case9 file created in bare dir"; fi

# ---------- case 10: non-string error_details object doesn't crash ----------
N10_BEFORE=$(grep -c . "$interrupts" || true)
fire_hook '{"hook_event_name":"StopFailure","session_id":"worker-session-1","cwd":"'"$PROJ"'","error":"","error_details":{"status":429,"retry":3}}'
N10=$(grep -c . "$interrupts" || true)
assert_eq "case10 object error_details persisted" "$((N10_BEFORE+1))" "$N10"

# ---------- case 11: supervisor unresolvable (no name match w/ project cwd) -> persisted only ----------
python3 - "$PROJ/.supervisor/state.json" <<'EOF'
import json, sys
p = sys.argv[1]
st = json.load(open(p)); st["supervisor_name"] = "nonexistent-sup"
json.dump(st, open(p, "w"))
EOF
fire_hook "$PAYLOAD"
D11=$(json_field "$interrupts" "objs[-1]['delivered']")
assert_eq "case11 unresolvable supervisor -> delivered=false" "False" "$D11"

# ---------- summary ----------
echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES assertion(s) FAILED - tmp dir preserved: $TMP"
  trap - EXIT
  exit 1
fi
