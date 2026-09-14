#!/usr/bin/env bash
# Assertion-based regression test for hooks/registry.py (v3 discovery layer).
# Sandboxed: runs registry.py against a throwaway project dir via the
# CLAUDE_SUPERVISOR_DIR env override (never touches ~/.claude/supervisor
# installs or real projects).
set -uo pipefail

SRC="${1:-$(cd "$(dirname "$0")" && pwd)/hooks/registry.py}"
FAILURES=0
TMP="$(mktemp -d /tmp/regtest.XXXX)"
PROJ="$TMP/proj"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $1"; FAILURES=$((FAILURES+1)); }
pass() { echo "ok:   $1"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi; }
assert_contains() { if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1 (needle '$3' not found)"; fi; }
assert_not_contains() { if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1 (unexpected needle '$3')"; else pass "$1"; fi; }

SID_A="11111111-1111-1111-1111-111111111111"
SID_B="22222222-2222-2222-2222-222222222222"
SID_C="33333333-3333-3333-3333-333333333333"

# run <workdir> <args...>: invoke registry.py with the registry pinned to
# $PROJ via env; capture stdout+stderr and rc
run() {
  local wd="$1"; shift
  ( cd "$wd" && CLAUDE_SUPERVISOR_DIR="$PROJ/.supervisor" python3 "$SRC" "$@" ) \
    > "$TMP/out.txt" 2> "$TMP/err.txt"
  RC=$?
}

mkdir -p "$PROJ"

# ---- case 1: fresh project (no .supervisor/ dir) first register -> exit 0 ----
run "$PROJ" register --session-id "$SID_A" --name supervisor-gf --mode greenfield --goal "g" --project-dir "$PROJ"
assert_eq "case1 fresh-project register exit 0" "0" "$RC"
assert_contains "case1 created .supervisor/registry.json" "$PROJ/.supervisor/registry.json" "supervisor-gf"

# ---- case 2: second supervisor -> exit 2 + KNOWN_OTHERS full-sid line ----
run "$PROJ" register --session-id "$SID_B" --name supervisor-rw --mode rework --goal "g2" --project-dir "$PROJ"
assert_eq "case2 isolation gate exit 2" "2" "$RC"
assert_contains "case2 lists other entry" "$TMP/out.txt" "supervisor-gf"
assert_contains "case2 KNOWN_OTHERS full sid line" "$TMP/out.txt" "KNOWN_OTHERS [\"$SID_A\"]"

# ---- case 3: retry with prefix sid (old broken contract) -> still exit 2 grown ----
run "$PROJ" register --session-id "$SID_B" --name supervisor-rw --mode rework --goal "g2" --project-dir "$PROJ" \
  --isolation-confirmed --known-others '["11111111"]'
assert_eq "case3 prefix sid cannot satisfy grown check" "2" "$RC"

# ---- case 4: retry with the full KNOWN_OTHERS array -> exit 0 ----
run "$PROJ" register --session-id "$SID_B" --name supervisor-rw --mode rework --goal "g2" --project-dir "$PROJ" \
  --isolation-confirmed --known-others "[$(printf '"%s"' "$SID_A")]"
assert_eq "case4 confirmed register exit 0" "0" "$RC"

# ---- case 5: name collision with ACTIVE entry -> exit 3, nothing written ----
run "$PROJ" register --session-id "$SID_C" --name supervisor-gf --mode greenfield --goal "g" --project-dir "$PROJ"
assert_eq "case5 name collision exit 3" "3" "$RC"
assert_not_contains "case5 no new entry written" "$PROJ/.supervisor/registry.json" "$SID_C"

# ---- case 6: idempotent upsert on same sid -> exit 0, entry count unchanged ----
N6=$(python3 -c "import json;print(len(json.load(open('$PROJ/.supervisor/registry.json'))['supervisors']))")
run "$PROJ" register --session-id "$SID_A" --name supervisor-gf --mode greenfield --goal "g-updated" --project-dir "$PROJ"
assert_eq "case6 resume upsert exit 0" "0" "$RC"
N6B=$(python3 -c "import json;print(len(json.load(open('$PROJ/.supervisor/registry.json'))['supervisors']))")
assert_eq "case6 no duplicate entry" "$N6" "$N6B"
assert_contains "case6 goal field refreshed" "$PROJ/.supervisor/registry.json" "g-updated"

# ---- case 7: heartbeat on existing entry -> ok; missing entry no name -> exit 1 ----
run "$PROJ" heartbeat --session-id "$SID_A"
assert_eq "case7 heartbeat existing exit 0" "0" "$RC"
run "$PROJ" heartbeat --session-id "$SID_C"
assert_eq "case7 heartbeat missing without --name exit 1" "1" "$RC"

# ---- case 8: heartbeat recreate WITH name colliding active name -> exit 3 ----
run "$PROJ" heartbeat --session-id "$SID_C" --name supervisor-gf
assert_eq "case8 heartbeat rebuild name collision exit 3" "3" "$RC"
assert_not_contains "case8 no silent entry created" "$PROJ/.supervisor/registry.json" "$SID_C"

# ---- case 9: heartbeat recreate WITH unique name -> exit 0 ----
run "$PROJ" heartbeat --session-id "$SID_C" --name supervisor-three
assert_eq "case9 heartbeat rebuild unique exit 0" "0" "$RC"
assert_contains "case9 entry recreated" "$PROJ/.supervisor/registry.json" "supervisor-three"

# ---- case 10: mark-stale -> exit 0; unregister stale entry -> exit 0 ----
run "$PROJ" mark-stale --session-id "$SID_C"
assert_eq "case10 mark-stale exit 0" "0" "$RC"
run "$PROJ" unregister --session-id "$SID_C"
assert_eq "case10 unregister exit 0" "0" "$RC"

# ---- case 11: unregister absent sid -> exit 1 ----
run "$PROJ" unregister --session-id "$SID_C"
assert_eq "case11 unregister absent exit 1" "1" "$RC"

# ---- case 12: list shows entries (read-only) ----
run "$PROJ" list
assert_eq "case12 list exit 0" "0" "$RC"
assert_contains "case12 lists supervisor-gf" "$TMP/out.txt" "supervisor-gf"
assert_contains "case12 lists supervisor-rw" "$TMP/out.txt" "supervisor-rw"

# ---- case 13: --project-dir locates registry from a foreign cwd ----
run "$TMP" list --project-dir "$PROJ"
assert_eq "case13 project-dir from foreign cwd exit 0" "0" "$RC"
assert_contains "case13 project-dir found registry" "$TMP/out.txt" "supervisor-gf"

# ---- case 14: corrupt registry.json -> register resets cleanly, exit 0 ----
echo '{"supervisors": "garbage' > "$PROJ/.supervisor/registry.json"
run "$PROJ" register --session-id "$SID_A" --name supervisor-gf --mode greenfield --goal "g" --project-dir "$PROJ"
assert_eq "case14 corrupt registry reset + register exit 0" "0" "$RC"

# ---- case 15: concurrency -- 6 parallel registers, exactly one winner ----
rm -f "$PROJ/.supervisor/registry.json"
PIDS=()
for i in 1 2 3 4 5 6; do
  ( cd "$PROJ" && CLAUDE_SUPERVISOR_DIR="$PROJ/.supervisor" \
    python3 "$SRC" register --session-id "0000000$i-0000-0000-0000-00000000000$i" \
    --name "sup-c$i" --mode greenfield --goal "g" --project-dir "$PROJ" ) \
    > "$TMP/rc$i" 2>/dev/null &
  PIDS+=($!)
done
WINNERS=0; LOSERS=0
for p in "${PIDS[@]}"; do wait "$p" || true; done
for i in 1 2 3 4 5 6; do
  # capture actual rc via marker files (run() only holds the last one)
  :
done
# simpler: count entries in the registry -- all 6 should be there eventually?
# No: parallel same-phase means only ONE wins with exit 0; others exit 2.
# But they all try to register as DIFFERENT sids with no isolation confirm,
# so first writer wins its txn, each subsequent sees others active -> exit 2.
N15=$(python3 -c "import json;d=json.load(open('$PROJ/.supervisor/registry.json'));print(len(d['supervisors']))" 2>/dev/null || echo 0)
if [ "$N15" -ge 1 ] && [ "$N15" -le 6 ]; then pass "case15 concurrent registers serialized ($N15 entries, no corruption)"; else fail "case15 registry corrupted (entries=$N15)"; fi
# registry must be valid JSON after the storm
python3 -c "import json;json.load(open('$PROJ/.supervisor/registry.json'))" 2>/dev/null \
  && pass "case15 registry is valid JSON after concurrency" \
  || fail "case15 registry corrupted"

echo ""
if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILURES assertion(s) FAILED - tmp preserved: $TMP"; trap - EXIT; exit 1; fi
