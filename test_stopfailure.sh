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

# ---------- v3 shard layout: sandbox ----------
HOOK_DIR=$(dirname "$HOOK")
INJ="$HOOK_DIR/session-start-injector.py"
GUARD="$HOOK_DIR/shard-guard.py"

P3="$TMP/proj3"
SUPA_SOCK="$TMP/supa.sock"
SID_A="11111111-1111-1111-1111-111111111111"
SID_B="22222222-2222-2222-2222-222222222222"
mkdir -p "$P3/.supervisor/$SID_A" "$P3/.supervisor/$SID_B" "$P3/src"

# sessions: supervisor-a live with socket + peerToken
python3 - "$TMP/sessions" "$SUPA_SOCK" "$SID_A" "$P3" <<'EOF'
import json, sys
d, sock, sid, proj = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
json.dump({"pid": 55555, "sessionId": sid, "cwd": proj,
           "messagingSocketPath": sock, "name": "supervisor-a",
           "updatedAt": 9999999999999,
           "procStart": "Mon Sep  1 00:00:00 2026"},
          open(d + "/55555.json", "w"))
json.dump({"peerToken": "token-a",
           "procStart": "Mon Sep  1 00:00:00 2026"},
          open(d + "/55555.xyz.key", "w"))
EOF

mkstate() { # file project_dir sup_name sup_sid worker_sid registered_at
  python3 - "$@" <<'EOF'
import json, sys
p, proj, name, ssid, wsid, reg = sys.argv[1:7]
json.dump({"goal": "g", "project_dir": proj, "supervisor_name": name,
           "supervisor_session_id": ssid,
           "workers": [{"name": "w1", "session_id": wsid,
                        "phase": "dev-1", "registered_at": reg}],
           "reviews": [], "done": False}, open(p, "w"))
EOF
}

addworker() { # state_file worker_sid registered_at
  python3 - "$@" <<'EOF'
import json, sys
p, wsid, reg = sys.argv[1], sys.argv[2], sys.argv[3]
st = json.load(open(p))
st.setdefault("workers", []).append(
    {"name": "w2", "session_id": wsid, "phase": "dev-2",
     "registered_at": reg})
json.dump(st, open(p, "w"))
EOF
}

mkstate "$P3/.supervisor/$SID_A/state.json" "$P3" "supervisor-a" "$SID_A" "w-sid-1" "2026-09-04T10:00:00"
mkstate "$P3/.supervisor/$SID_B/state.json" "$P3" "supervisor-b" "$SID_B" "w-sid-9" "2026-09-04T10:00:00"

# ---------- case 12: multi-shard targeted delivery ----------
start_server "$SUPA_SOCK" "$TMP/recv12.txt"
fire_hook '{"hook_event_name":"StopFailure","session_id":"w-sid-1","cwd":"'"$P3"'","error":"429 rate limited"}'
wait $SERVER_PID 2>/dev/null || true
assert_contains "case12 delivered to supervisor-a via pass-1" "$TMP/recv12.txt" 'WORKER INTERRUPTED'
D12=$(json_field "$P3/.supervisor/$SID_A/interrupts.jsonl" "objs[-1]['delivered']")
assert_eq "case12 shard A ledger delivered=true" "True" "$D12"
if [ ! -f "$P3/.supervisor/$SID_B/interrupts.jsonl" ]; then
  pass "case12 shard B untouched"; else fail "case12 shard B written"; fi
if [ ! -f "$P3/.supervisor/interrupts.jsonl" ]; then
  pass "case12 no flat write"; else fail "case12 flat written"; fi

# ---------- case 13: no shard match + double-hit ambiguity ----------
N13=$(grep -c . "$P3/.supervisor/$SID_A/interrupts.jsonl" || true)
fire_hook '{"hook_event_name":"StopFailure","session_id":"stranger-sid","cwd":"'"$P3"'","error":"429"}'
N13B=$(grep -c . "$P3/.supervisor/$SID_A/interrupts.jsonl" || true)
assert_eq "case13a stranger sid -> no shard write" "$N13" "$N13B"
if [ ! -f "$P3/.supervisor/$SID_B/interrupts.jsonl" ]; then
  pass "case13a shard B still untouched"; else fail "case13a shard B written"; fi

# same worker sid in BOTH shards with equal registered_at -> ambiguity
addworker "$P3/.supervisor/$SID_A/state.json" "w-sid-2" "2026-09-04T12:00:00"
addworker "$P3/.supervisor/$SID_B/state.json" "w-sid-2" "2026-09-04T12:00:00"
ERR13=$(fire_hook '{"hook_event_name":"StopFailure","session_id":"w-sid-2","cwd":"'"$P3"'","error":"429"}' 2>&1 1>/dev/null)
RC13=$?
assert_eq "case13b ambiguous double-hit exit 0" "0" "$RC13"
case "$ERR13" in
  *matches*) pass "case13b ambiguity logged to stderr" ;;
  *) fail "case13b ambiguity stderr missing (got: $ERR13)" ;;
esac
N13C=$(grep -c . "$P3/.supervisor/$SID_A/interrupts.jsonl" || true)
assert_eq "case13b ambiguous -> no ledger write (A)" "$N13" "$N13C"
if [ ! -f "$P3/.supervisor/$SID_B/interrupts.jsonl" ]; then
  pass "case13b ambiguous -> no ledger write (B)"; else fail "case13b shard B written"; fi

# ---------- case 14: flat-only project (zero shards) ----------
P4="$TMP/proj4"
mkdir -p "$P4/.supervisor"
mkstate "$P4/.supervisor/state.json" "$P4" "supervisor-a" "$SID_A" "w-sid-4" "2026-09-04T10:00:00"
start_server "$SUPA_SOCK" "$TMP/recv14.txt"
fire_hook '{"hook_event_name":"StopFailure","session_id":"w-sid-4","cwd":"'"$P4"'","error":"429 rate limited"}'
wait $SERVER_PID 2>/dev/null || true
assert_contains "case14 flat delivery" "$TMP/recv14.txt" 'WORKER INTERRUPTED'
D14=$(json_field "$P4/.supervisor/interrupts.jsonl" "objs[-1]['delivered']")
assert_eq "case14 flat delivered=true" "True" "$D14"

# ---------- case 15: linked worktree discovery ----------
WTMAIN="$TMP/wtmain"; WTLINK="$TMP/wtlink"
git init -q "$WTMAIN"
mkdir -p "$WTMAIN/.supervisor/$SID_A"
mkstate "$WTMAIN/.supervisor/$SID_A/state.json" "$WTMAIN" "supervisor-a" "sup-wt-dead" "w-sid-7" "2026-09-04T10:00:00"
git -C "$WTMAIN" -c user.email=t@t -c user.name=t commit --allow-empty -qm init
git -C "$WTMAIN" worktree add -q "$WTLINK" -b wt-branch
mkdir -p "$WTLINK/src"
fire_hook '{"hook_event_name":"StopFailure","session_id":"w-sid-7","cwd":"'"$WTLINK/src"'","error":"429 rate limited"}'
if [ -f "$WTMAIN/.supervisor/$SID_A/interrupts.jsonl" ]; then
  pass "case15 worktree interrupt landed in main-worktree shard"
else fail "case15 no ledger in main worktree shard"; fi
if [ ! -e "$WTLINK/.supervisor" ]; then
  pass "case15 nothing created inside worktree"; else fail "case15 .supervisor created in worktree"; fi

# ---------- case 16: archive/ invisible to shard scanning ----------
mkdir -p "$P3/.supervisor/archive/old-round"
mkstate "$P3/.supervisor/archive/old-round/state.json" "$P3" "supervisor-a" "$SID_A" "w-sid-arch" "2026-09-01T10:00:00"
N16=$(grep -c . "$P3/.supervisor/$SID_A/interrupts.jsonl" || true)
fire_hook '{"hook_event_name":"StopFailure","session_id":"w-sid-arch","cwd":"'"$P3"'","error":"429"}'
N16B=$(grep -c . "$P3/.supervisor/$SID_A/interrupts.jsonl" || true)
assert_eq "case16 archive worker -> no shard write" "$N16" "$N16B"
if [ ! -f "$P3/.supervisor/archive/old-round/interrupts.jsonl" ]; then
  pass "case16 archive dir never written"; else fail "case16 archive written"; fi

# ---------- case 17: name collision + dead target sid + shards>1 -> pass-2 disabled ----------
python3 - "$P3/.supervisor/$SID_A/state.json" <<'EOF'
import json, sys
p = sys.argv[1]
st = json.load(open(p)); st["supervisor_session_id"] = "sup-dead-sid"
json.dump(st, open(p, "w"))
EOF
# decoy: same NAME as shard A's supervisor, cwd == project_dir, REAL listener.
# Old pass-2 would deliver to it; v3 must not (n_shards=2 -> pass-2 disabled).
SUPD_SOCK="$TMP/supd.sock"
python3 - "$TMP/sessions" "$SUPD_SOCK" "$P3" <<'EOF'
import json, sys
d, sock, proj = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"pid": 44444, "sessionId": "decoy-sid", "cwd": proj,
           "messagingSocketPath": sock, "name": "supervisor-a",
           "updatedAt": 9999999999999,
           "procStart": "Mon Sep  1 00:00:00 2026"},
          open(d + "/44444.json", "w"))
EOF
start_server "$SUPD_SOCK" "$TMP/recv17.txt"
fire_hook '{"hook_event_name":"StopFailure","session_id":"w-sid-1","cwd":"'"$P3"'","error":"429 rate limited"}'
wait $SERVER_PID 2>/dev/null || true
if grep -qF 'WORKER INTERRUPTED' "$TMP/recv17.txt"; then
  fail "case17 delivered to same-name decoy (pass-2 must be disabled)"
else pass "case17 pass-2 disabled with shards>1 (no delivery)"; fi
D17=$(json_field "$P3/.supervisor/$SID_A/interrupts.jsonl" "objs[-1]['delivered']")
assert_eq "case17 delivered=false, still persisted" "False" "$D17"

# ---------- case 18: shards exist + sid zero-hit -> flat fallback channel (P1-3) ----------
N18=$(grep -c . "$P3/.supervisor/$SID_A/interrupts.jsonl" || true)
mkstate "$P3/.supervisor/state.json" "$P3" "supervisor-a" "$SID_A" "w-sid-flat" "2026-09-04T10:00:00"
start_server "$SUPA_SOCK" "$TMP/recv18.txt"
fire_hook '{"hook_event_name":"StopFailure","session_id":"w-sid-flat","cwd":"'"$P3"'","error":"429 rate limited"}'
wait $SERVER_PID 2>/dev/null || true
assert_contains "case18 flat-channel delivery" "$TMP/recv18.txt" 'WORKER INTERRUPTED'
D18=$(json_field "$P3/.supervisor/interrupts.jsonl" "objs[-1]['delivered']")
assert_eq "case18 flat fallback delivered=true" "True" "$D18"
N18B=$(grep -c . "$P3/.supervisor/$SID_A/interrupts.jsonl" || true)
assert_eq "case18 shard A untouched by flat worker" "$N18" "$N18B"

# ---------- case 19: shard guard blocks registry.json direct write ----------
echo '{"session_id":"'"$SID_A"'","tool_name":"Write","tool_input":{"file_path":"'"$P3"'/.supervisor/registry.json"}}' \
  | python3 "$GUARD" 2>"$TMP/g19.err"
assert_eq "case19 guard registry.json exit 2" "2" "$?"
assert_contains "case19 guard stderr points to registry.py" "$TMP/g19.err" 'registry.py'

# ---------- case 20: injector startup / resume / silent-failure ----------
OUT20=$(echo '{"session_id":"inj-sid-1","source":"startup","cwd":"'"$TMP"'"}' | python3 "$INJ")
assert_eq "case20 injector startup single line" "SESSION_ID inj-sid-1 startup" "$OUT20"
OUT20B=$(echo '{"session_id":"inj-sid-1","source":"resume","cwd":"'"$TMP"'"}' | python3 "$INJ")
assert_eq "case20 injector resume without .supervisor -> no hint" "SESSION_ID inj-sid-1 resume" "$OUT20B"
echo '{"session_id":"inj-sid-2","source":"resume","cwd":"'"$P3"'"}' | python3 "$INJ" > "$TMP/inj20.txt" 2>/dev/null
assert_contains "case20 injector resume hint line" "$TMP/inj20.txt" 'registry.json'
L20=$(grep -c . "$TMP/inj20.txt" || true)
assert_eq "case20 injector resume emits exactly 2 lines" "2" "$L20"
echo 'not json' | python3 "$INJ" > "$TMP/inj20c.txt" 2>/dev/null
assert_eq "case20 injector garbage exit 0" "0" "$?"
assert_eq "case20 injector garbage no output" "0" "$(grep -c . "$TMP/inj20c.txt" || true)"

# ---------- case 21: shard guard allow/deny/short-circuit ----------
echo '{"session_id":"'"$SID_A"'","tool_name":"Write","tool_input":{"file_path":"'"$P3/.supervisor/$SID_A"'/state.json"}}' \
  | python3 "$GUARD" 2>"$TMP/g21a.err"
assert_eq "case21 own shard write allowed" "0" "$?"
assert_eq "case21 own shard no stderr" "0" "$(grep -c . "$TMP/g21a.err" || true)"
echo '{"session_id":"00000000-0000-0000-0000-000000000000","tool_name":"Write","tool_input":{"file_path":"'"$P3/.supervisor/$SID_A"'/state.json"}}' \
  | python3 "$GUARD" 2>"$TMP/g21b.err"
assert_eq "case21 wrong sid write denied (exit 2)" "2" "$?"
assert_contains "case21 deny stderr has DENIED_BY_GUARD" "$TMP/g21b.err" 'DENIED_BY_GUARD'
assert_contains "case21 deny stderr shows correct sid" "$TMP/g21b.err" "$SID_A"
echo 'not json {"file_path":"/tmp/foo.py"}' | python3 "$GUARD" 2>/dev/null
assert_eq "case21 short-circuit garbage stdin exit 0" "0" "$?"
echo '{"session_id":"x","tool_name":"Write","tool_input":{"file_path":"/tmp/foo.py"}}' | python3 "$GUARD" 2>/dev/null
assert_eq "case21 ordinary file exit 0" "0" "$?"
echo 'garbage with .supervisor/ inside {"file_path":"'"$P3/.supervisor/$SID_A"'/x"}' | python3 "$GUARD" 2>/dev/null
assert_eq "case21 unparseable-but-suspect exits 0 (never block on garbage)" "0" "$?"
echo '{"session_id":"x","tool_name":"Write","tool_input":{"file_path":"'"$P3"'/.supervisor/archive/old-round/state.json"}}' | python3 "$GUARD" 2>/dev/null
assert_eq "case21 archive write allowed" "0" "$?"
echo '{"session_id":"x","tool_name":"Write","tool_input":{"file_path":"'"$P4"'/.supervisor/state.json"}}' | python3 "$GUARD" 2>/dev/null
assert_eq "case21 flat state.json write allowed" "0" "$?"

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
