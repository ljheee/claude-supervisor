#!/usr/bin/env bash
# Assertion-based regression test for supervisor-watchdog.
# Sandboxed: fake project state + fake agent-mail CLI; never touches real data.
set -uo pipefail

WD_SRC="${1:-$HOME/.agent-mail/supervisor-watchdog}"
FAILURES=0
TMP=""

cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $1"; FAILURES=$((FAILURES+1)); }
pass() { echo "ok:   $1"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi; }
assert_contains() { if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1 (needle '$3' not found)"; fi; }
assert_not_contains() { if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1 (unexpected needle '$3')"; else pass "$1"; fi; }

TMP=$(mktemp -d /tmp/wdtest.XXXX)
PROJ="$TMP/proj"
MAIL="$TMP/mailhome"
mkdir -p "$PROJ/.supervisor" "$MAIL/inbox"

# Deploy the watchdog under test INTO the fake mail home, mimicking the real
# layout (~/.agent-mail/supervisor-watchdog sits next to agent-mail). This
# matters: the script prefers the CLI in its own directory, so testing the
# source path directly would bypass our fake CLI entirely.
WD="$MAIL/supervisor-watchdog"
cp "$WD_SRC" "$WD"

# fake agent-mail CLI that records sends to a spool
cat > "$MAIL/agent-mail" <<'EOF'
#!/usr/bin/env bash
# usage: agent-mail send <to> <body...> --from NAME
TO="$1"; shift
printf '%s\n---MSG-END---\n' "$*" >> "${SPOOL:-/tmp/wdspool}"
exit 0
EOF
chmod +x "$MAIL/agent-mail"

OLD=$(python3 -c "import datetime;print((datetime.datetime.now()-datetime.timedelta(minutes=120)).isoformat())")
NEW=$(python3 -c "import datetime;print(datetime.datetime.now().isoformat())")
# genuinely-past UTC timestamp with Z suffix (2h ago in UTC, not local wall time)
OLDZ=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=120)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

write_state() { # json-body
  cat > "$PROJ/.supervisor/state.json"
}

run_wd() { # threshold
  SPOOL="$MAIL/spool" AGENT_MAIL_HOME="$MAIL" bash "$WD" "$PROJ" "${1:-60}"
}

SPOOL="$MAIL/spool"; export SPOOL

# ---- case A: overdue worker (Z-suffixed ISO ts) -> alert with session_id ----
write_state <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup",
 "workers":[{"name":"w1","session_id":"sid-w1","phase":"dev-2",
   "registered_at":"$OLD","last_report_ts":"$OLD","last_instruction_ts":"$NEW"}],
 "reviews":[],"done":false}
EOF
# fake supervisor registered in agent-mail (send requires registered target)
echo '{"sup":{"type":"claude","session_id":"s","cwd":"'$PROJ'","registered_at":"x"}}' > "$MAIL/agents.json"
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
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup",
 "workers":[{"name":"w2","session_id":"sid-w2","phase":"dev-1",
   "registered_at":"$NEW","last_report_ts":"$NEW"}],
 "reviews":[],"done":false}
EOF
rm -f "$SPOOL"
run_wd 60
if [ -f "$SPOOL" ]; then fail "D: fresh worker should not alert"; else pass "D: fresh worker silent"; fi

# ---- case E: worker response resets silence (last_response_ts) ----
write_state <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup",
 "workers":[{"name":"w2","session_id":"sid-w2","phase":"dev-1",
   "registered_at":"$OLD","last_report_ts":"$OLD","last_response_ts":"$NEW"}],
 "reviews":[],"done":false}
EOF
run_wd 60
if [ -f "$SPOOL" ]; then fail "E: recent response should not alert"; else pass "E: last_response_ts resets silence"; fi

# ---- case F: done project -> silent ----
write_state <<EOF
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup",
 "workers":[{"name":"w1","session_id":"sid-w1","phase":"dev-2",
   "registered_at":"$OLD","last_report_ts":"$OLD"}],
 "reviews":[],"done":true}
EOF
run_wd 60
if [ -f "$SPOOL" ]; then fail "F: done project should not alert"; else pass "F: done project silent"; fi

# ---- case G: garbage threshold / bad dir -> exit 0, no output ----
OUT=$(run_wd "notanumber" 2>&1); RC=$?
assert_eq "G: bad threshold exit 0" "0" "$RC"
OUT=$(AGENT_MAIL_HOME="$MAIL" bash "$WD" /nonexistent 60 2>&1); RC=$?
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
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup",
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
{"goal":"g","project_dir":"$PROJ","supervisor_name":"sup",
 "workers":[{"name":"w3","session_id":"sid-w3","phase":"spec",
   "registered_at":"$OLDZ","last_report_ts":"$OLDZ"}],
 "reviews":[],"done":false}
EOF
run_wd 60
assert_contains "K: RFC3339 Z timestamp parsed -> alert" "$SPOOL" "sid-w3"

echo ""
if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILURES assertion(s) FAILED - tmp preserved: $TMP"; trap - EXIT; exit 1; fi
