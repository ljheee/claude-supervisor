#!/usr/bin/env python3
"""
Claude Code Stop hook: detect model-layer anomalies that end a turn looking
"normal" and report the worker to its supervisor over the UDS channel.

Design: stop-anomaly.md (k3 degradation incident 2026-09-06/07). Three fault
shapes were replay-verified on the incident transcripts; this hook
implements the two mechanical, replay-proven criteria:

  kind model-error      last assistant record has model == "error"
                        (API error wrapped as a normal assistant message;
                        replay 3/3 hits, zero false positives)
  kind empty-turn       last assistant record has zero tool_use AND its text
                        is empty or a bare "..."  (severity full = whole turn
                        produced nothing; severity tail = turn did real work
                        then died before its closing report -- replay: SUP
                        6 full + 8 tail, WORKER 3 tail, zero false positives)

Delivery ladder (replay-verified, stop-anomaly.md §二):
  model-error / empty-turn:full / empty-turn:tail  -> deliver on FIRST hit?
    model-error  : yes (turn-level failure, unambiguous)
    full         : only on >=2 consecutive hits (single dip self-heals;
                   replay showed single-shot recovery in the incident)
    tail         : yes, single hit (all 3 worker tails in the incident were
                   isolated single hits -- a >=2 rule would have detected
                   NOTHING; the 12:53 single-hit rule would have alerted
                   133 minutes before the human did)

State: consecutive-hit counters live in
  .supervisor/<supervisor-shard>/anomaly_state.json  (NEVER watchdog_state.json
-- that file has a second writer and the v3 design made registry writes
exclusive precisely to kill such races). Keyed by worker session_id; a
healthy turn resets the counter to zero.

Identity model: identical to worker-stopfailure.py -- the hook's own
session_id MUST be a registered worker in the selected ledger. Supervisor
sessions, user sessions, unregistered workers: silently ignored (the
supervisor's own degradation is the watchdog's job, layer five).

Cost on healthy unsupervised sessions: one stdin read, one directory
walk-up that finds no .supervisor/, and one bounded tail scan (seek to
last 64KB, milliseconds) -> exit with zero git spawn, zero state writes,
zero delivery. (The tail scan itself cannot be skipped: classifying the
 turn is what decides whether the rare git fallback is worth paying.)
Cost on healthy supervised worker turns: the same bounded tail scan of
the transcript (find the turn boundary, aggregate) -- no fsync, no
network, UDS bounded to ~1s. The git rev-parse fallback is
paid ONLY on anomaly turns in worktrees (rare path).

Settings registration (done by install.sh):
  hooks.Stop -> python3 <this file>
"""
import json
import os
import re
import socket
import sys
import time
import uuid

# overridable for testing
SESSIONS_DIR = os.environ.get(
    "CLAUDE_SUPERVISOR_SESSIONS_DIR",
    os.path.expanduser("~/.claude/sessions"))

SHARD_NAME_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

UDS_CONNECT_TIMEOUT = 1.0
UDS_SEND_TIMEOUT = 1.0

# how many bytes of the transcript tail we scan for the turn boundary; a
# pathological turn with a >64KB single tool_result would still be handled
# because the boundary is a USER record (non-tool_result) and we grow the
# window until we find one (bounded by 4 growth steps = 1MB, then give up)
TAIL_WINDOW = 65536
TAIL_MAX = 1048576

# texts that count as "empty" for the last-assistant check
EMPTY_TEXTS = ("", "...", "\u2026", ". . .")


# ---------------- transcript reading (bounded tail scan) ----------------

def read_tail_records(path):
    """Return (records, ok). Records are parsed from the END of the file,
    stopping at the turn boundary (the first non-tool_result user record
    found scanning backwards -- everything after it is the current turn).
    Older history is never parsed.
    ok=False only for getsize failure (missing file). An OSError during
    open/read propagates to the top-level except and exits 0 -- the turn
    is then treated as healthy, which may clear a streak one turn late.
    Accepted: a transiently unreadable transcript is not an anomaly
    signal, and a persistent failure surfaces on the next turn."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return [], False
    if size == 0:
        return [], True
    window = TAIL_WINDOW
    while True:
        with open(path, "rb") as f:
            if size > window:
                f.seek(size - window)
                f.readline()  # drop the partial first line
            data = f.read()
        recs = []
        for line in data.split(b"\n"):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if isinstance(r, dict):
                recs.append(r)
        # find boundary: LAST non-tool_result user record in what we parsed
        b = None
        for i in range(len(recs) - 1, -1, -1):
            r = recs[i]
            if r.get("type") == "user" and not is_tool_result_user(r):
                b = i
                break
        if b is not None or window >= TAIL_MAX or window >= size:
            # boundary found, or we genuinely cannot find one (whole file
            # is one turn -- or transcript is not what we expect)
            return recs[b if b is not None else 0:], True
        window *= 4


def is_tool_result_user(rec):
    """user record whose content is a tool_result array (tool_result rides
    on the user role in transcripts)."""
    if rec.get("type") != "user":
        return False
    m = rec.get("message", {})
    if not isinstance(m, dict):
        return False
    c = m.get("content")
    if isinstance(c, list):
        return any(isinstance(b, dict) and b.get("type") == "tool_result"
                   for b in c)
    return False


def assistant_blocks(rec):
    m = rec.get("message", {})
    if not isinstance(m, dict):
        return []
    c = m.get("content")
    # a string content block (degenerate API form) is NOT an empty block
    # list: returning [] would make the record classify as zero-tool empty
    # text. Instead wrap it as a single text block so the criteria see it.
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return c if isinstance(c, list) else []


def assistant_text(rec):
    return "".join(b.get("text", "") for b in assistant_blocks(rec)
                   if isinstance(b, dict) and b.get("type") == "text").strip()


def assistant_tool_uses(rec):
    return [b for b in assistant_blocks(rec)
            if isinstance(b, dict) and b.get("type") == "tool_use"]


# ---------------- ledger discovery (same contract as worker-stopfailure) --

def find_supervisor_root(start_dir):
    d = start_dir
    while True:
        if os.path.isdir(os.path.join(d, ".supervisor")):
            return os.path.join(d, ".supervisor")
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def find_via_git(start_dir):
    """Locate .supervisor/ at the main worktree root. `git rev-parse
    --git-common-dir` returns the main worktree's gitdir (absolute or
    relative to start_dir); its PARENT directory is the main worktree
    root. (Without the dirname this would point at <repo>/.git/.supervisor,
    which never exists -- caught in second CR round.)"""
    try:
        out = subprocess_run(
            ["git", "-C", start_dir, "rev-parse", "--git-common-dir"])
        gd = out.strip()
        if gd:
            root = os.path.dirname(
                os.path.abspath(os.path.join(start_dir, gd)))
            cand = os.path.join(root, ".supervisor")
            if os.path.isdir(cand):
                return cand
    except Exception:
        pass
    return None


def subprocess_run(cmd):
    import subprocess
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=2)
    return r.stdout or ""


def load_json(path):
    try:
        with open(path) as f:
            v = json.load(f)
        return v if isinstance(v, dict) else None
    except Exception:
        return None


def resolve_ledger(cwd, session_id, git_fallback=True):
    """Return (state, state_dir) if this session is a REGISTERED WORKER of
    exactly one live ledger; None otherwise. Shards-first, flat fallback.
    git_fallback=False skips the `git rev-parse` spawn (used for the cheap
    every-turn gate; the caller retries git-enabled only when the transcript
    already shows an anomaly)."""
    sup_dir = find_supervisor_root(cwd)
    if sup_dir is None and git_fallback:
        sup_dir = find_via_git(cwd)
    if sup_dir is None:
        return None
    return _resolve_in(sup_dir, session_id)


def resolve_ledger_git_only(cwd, session_id):
    """Ledger resolution that ONLY uses the git-common-dir fallback (the
    walk-up already failed in the caller). Returns None cheaply when the
    cwd is not inside a git repository -- no directory walking repeated."""
    sup_dir = find_via_git(cwd)
    if sup_dir is None:
        return None
    return _resolve_in(sup_dir, session_id)


def _resolve_in(sup_dir, session_id):
    """Shared shard/flat selection logic (see module docstring for the
    precedence rules and the tie-breaking policy)."""
    try:
        names = sorted(os.listdir(sup_dir))
    except OSError:
        return None
    hits = []
    for name in names:
        if not SHARD_NAME_RE.match(name):
            continue
        sd = os.path.join(sup_dir, name)
        st = load_json(os.path.join(sd, "state.json"))
        if st is None or st.get("done"):
            continue
        if worker_sid_in(st, session_id):
            hits.append((st, sd))
    if hits:
        if len(hits) == 1:
            return hits[0]
        # multiple shards claim this worker: newest registered_at wins;
        # still tied -> refuse (never mis-deliver). Same max-not-first rule
        # as worker-stopfailure.py; refusal is logged to stderr for
        # post-hoc archaeology (the interrupt is NOT persisted in this
        # ambiguous case -- the log is the only trace).
        def reg_key(h):
            ws = [w for w in (h[0].get("workers") or [])
                  if isinstance(w, dict) and w.get("session_id") == session_id]
            return max((w.get("registered_at") or "") for w in ws) \
                if ws else ""
        hits.sort(key=reg_key)
        if reg_key(hits[-1]) and reg_key(hits[-1]) != reg_key(hits[-2]):
            return hits[-1]
        sys.stderr.write(
            "stop-anomaly-capture: ambiguous shard for session %s; "
            "refusing delivery\n" % session_id)
        return None
    # zero shard hits but shards exist -> flat fallback (v2 window)
    has_shards = any(SHARD_NAME_RE.match(n) for n in names)
    if not has_shards:
        st = load_json(os.path.join(sup_dir, "state.json"))
        if st is not None and not st.get("done") \
                and worker_sid_in(st, session_id):
            return (st, sup_dir)
    return None


def worker_sid_in(state, session_id):
    if not session_id:
        return False
    for w in state.get("workers") or []:
        if isinstance(w, dict) and w.get("session_id") == session_id:
            return True
    return False


# ---------------- supervisor resolution + UDS delivery -------------------

def load_sessions():
    out = []
    try:
        for p in os.listdir(SESSIONS_DIR):
            if not p.endswith(".json"):
                continue
            d = load_json(os.path.join(SESSIONS_DIR, p))
            if d:
                out.append(d)
    except OSError:
        pass
    return out


def find_peer_token(pid, proc_start):
    try:
        for p in os.listdir(SESSIONS_DIR):
            if p == "%s.x.key" % pid or (p.startswith("%s." % pid)
                                         and p.endswith(".key")):
                d = load_json(os.path.join(SESSIONS_DIR, p))
                if d and (d.get("procStart") == proc_start or not proc_start):
                    return d.get("peerToken")
    except OSError:
        pass
    return None


def resolve_supervisor(sessions, st):
    """sid-first (socket must exist on a same-sessionId record). Deliberately
    NO name+cwd fallback (unlike worker-stopfailure.py): a name-only hit is
    exactly the mis-delivery vector v3 guards against, and a missing sid in
    a legacy flat ledger just means no live delivery -- the interrupt is
    still persisted for supervisor catch-up."""
    want = st.get("supervisor_session_id")
    if isinstance(want, str) and want:
        best = None
        for o in sessions:
            if o.get("sessionId") != want:
                continue
            sp = o.get("messagingSocketPath")
            if isinstance(sp, str) and sp and os.path.exists(sp):
                best = (sp, find_peer_token(o.get("pid"), o.get("procStart")))
                break
        if best:
            return {"socket": best[0], "token": best[1]}
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
        return True  # write success only, not a delivery ack
    except OSError:
        return False
    finally:
        try:
            s.close()
        except OSError:
            pass


def append_interrupt(state_dir, entry):
    try:
        os.makedirs(state_dir, exist_ok=True)
        path = os.path.join(state_dir, "interrupts.jsonl")
        with open(path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
            f.flush()
    except OSError:
        pass


# ---------------- anomaly state (consecutive-hit counters) ---------------

def load_anomaly(state_dir):
    d = load_json(os.path.join(state_dir, "anomaly_state.json"))
    return d if isinstance(d, dict) else {}


def save_anomaly(state_dir, state):
    """Atomic write (mkstemp + replace): a half-written counter is worse
    than a lost one, and this file has exactly ONE writer (this hook)."""
    try:
        import tempfile
        fd, tmp = tempfile.mkstemp(
            dir=state_dir or ".", prefix=".anomaly-")
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
        os.replace(tmp, os.path.join(state_dir, "anomaly_state.json"))
    except Exception:
        pass


def bump_key(state, key):
    n = state.get(key)
    return (n + 1) if isinstance(n, int) else 1


# ---------------- main ----------------

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(data, dict):
        return

    cwd = data.get("cwd") or os.getcwd()
    if not isinstance(cwd, str) or not cwd:
        return
    session_id = data.get("session_id") or ""
    transcript = data.get("transcript_path") or ""
    if not isinstance(transcript, str) or not transcript:
        return

    # ---- cheap gate FIRST: resolve the ledger via directory walk-up only.
    # hooks.Stop fires for EVERY user session every turn. Combined with the
    # ordering below, a healthy turn -- supervised or not -- pays ZERO git
    # spawns and zero state writes: unsupervised sessions exit after one
    # walk-up plus one bounded tail scan (the scan cannot be skipped --
    # classifying the turn is what gates the git fallback below).
    found = resolve_ledger(cwd, session_id, git_fallback=False)

    # ---- criterion evaluation on the turn tail. Done BEFORE the git
    # fallback: (a) supervised workers need it anyway; (b) unsupervised
    # sessions in git repos exit on a healthy turn WITHOUT the git spawn
    # (the docstring's "git fallback is paid ONLY on anomaly turns" is
    # only true with this ordering). For the anomaly path the tail scan
    # is paid twice in the worst case -- irrelevant, it is milliseconds.
    recs, ok = read_tail_records(transcript)
    kind = None
    if ok:
        kind = classify_turn(recs)

    if not found and kind is not None:
        # anomaly turn in a linked worktree whose .supervisor/ is not
        # reachable by walking up -> pay the git spawn ONLY now (rare path)
        found = resolve_ledger_git_only(cwd, session_id)
    if not found:
        return
    st, state_dir = found

    # strict identity gate (resolve_ledger already checked registration;
    # re-extract worker metadata for the report)
    my_name, my_phase = session_id, "unknown"
    for w in st.get("workers") or []:
        if isinstance(w, dict) and w.get("session_id") == session_id:
            my_name = w.get("name") or session_id
            my_phase = w.get("phase") or "unknown"
            break

    if kind is None:
        # healthy turn: reset the consecutive-hit counter AND opportunistically
        # GC stale keys (workers no longer in the ledger -- their streak
        # entries would otherwise accumulate forever)
        a_state = load_anomaly(state_dir)
        k = "empty_streak:%s" % session_id
        changed = False
        if a_state.get(k):
            a_state.pop(k, None)
            changed = True
        live_sids = set()
        for w in st.get("workers") or []:
            if isinstance(w, dict) and isinstance(w.get("session_id"), str):
                live_sids.add(w.get("session_id"))
        for key in list(a_state.keys()):
            if key.startswith("empty_streak:") \
                    and key.split(":", 1)[1] not in live_sids:
                del a_state[key]
                changed = True
        if changed:
            save_anomaly(state_dir, a_state)
        return

    # ---- delivery ladder ----
    a_state = load_anomaly(state_dir)
    k = "empty_streak:%s" % session_id
    deliver = True
    if kind == "model-error":
        deliver = True            # unambiguous turn-level failure
    elif kind == "empty-turn:full":
        a_state[k] = bump_key(a_state, k)
        deliver = a_state[k] >= 2  # single dip self-heals (replay-verified)
    elif kind == "empty-turn:tail":
        deliver = True            # isolated single hits are the norm (replay)
    else:
        deliver = False
    if not deliver:
        save_anomaly(state_dir, a_state)
        return
    a_state.pop(k, None)
    save_anomaly(state_dir, a_state)

    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    entry = {
        "id": uuid.uuid4().hex[:10],
        "ts": ts,
        "kind": kind,
        "worker": my_name,
        "worker_session_id": session_id,
        "phase": my_phase,
        "error": "model-layer anomaly (stop-anomaly-capture)",
        "delivered": False,
        "handled": False,
    }

    sup = None
    try:
        sup = resolve_supervisor(load_sessions(), st)
    except Exception:
        sup = None
    if sup and sup.get("socket"):
        body = (
            "WORKER INTERRUPTED (Stop hook stop-anomaly-capture 自动上报)"
            " [id: %s]\n"
            "worker: %s (session_id: %s)\n"
            "phase: %s\n"
            "kind: %s\n"
            "判据: 回合看似正常结束（stop_reason=end_turn）但末条 assistant %s。\n"
            "transcript: %s\n"
            "时间: %s\n"
            "说明: 模型层故障形态（09-06/07 事故三形态之二）。worker 进程活着、"
            "可被唤醒，但被唤醒的产出可能仍是空/退化——建议先 SendMessage 探活；"
            "反复空响应则升级用户 /compact 或换模型（/compact 实测仅 ~25 分钟，"
            "换模更彻底）。处理完毕请在 acknowledged.jsonl 记录 id=%s。\n"
            % (entry["id"], my_name, session_id, my_phase, kind,
               "model 字段为 error（API 错误被包装为正常消息）"
               if kind == "model-error"
               else "零 tool_use 且文本为空/'…'（%s）" %
               ("整轮空" if kind.endswith("full") else "尾部退化——工具效果已"
                "发生但收尾回执未发出"),
               transcript, ts, entry["id"]))
        try:
            entry["delivered"] = send_uds(sup["socket"], sup.get("token"), body)
        except Exception:
            pass

    append_interrupt(state_dir, entry)


def classify_turn(recs):
    """Return the anomaly kind for the turn in recs, or None if healthy.
    recs = records from the turn boundary (inclusive) to the file end."""
    asst = [r for r in recs if r.get("type") == "assistant"]
    if not asst:
        return None  # no assistant output at all (e.g. pure user echo turn)
    last = asst[-1]

    # criterion 1: model error (guard against non-dict message blocks;
    # a malformed record must not crash the classifier -- the top-level
    # except would swallow it and leave the streak neither bumped nor
    # cleared, silently skipping the turn)
    m = last.get("message")
    if isinstance(m, dict) and m.get("model") == "error":
        return "model-error"

    # criterion 2: last assistant has zero tool_use and empty/"..." text
    last_txt = assistant_text(last)
    last_tools = len(assistant_tool_uses(last))
    if last_tools == 0 and last_txt in EMPTY_TEXTS:
        all_tools = sum(len(assistant_tool_uses(a)) for a in asst)
        all_txts = [assistant_text(a) for a in asst]
        if all_tools == 0 and all(t in EMPTY_TEXTS for t in all_txts):
            return "empty-turn:full"
        return "empty-turn:tail"
    return None


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
