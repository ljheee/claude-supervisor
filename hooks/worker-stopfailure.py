#!/usr/bin/env python3
"""
Claude Code StopFailure hook: automatically report an interrupted worker
session to its supervisor over the official cross-session UDS channel.

Fires when a turn ends in failure (429 rate limit exhausted, network error,
API error, ...). The worker model itself never gets a chance to send
anything in those cases - this hook is the machine-level voice it lacks.

Identity model (strict, to guarantee zero collateral damage):
  - The hook's own session_id (from stdin) MUST be listed in the selected
    ledger's workers[].session_id. Anything else (the user's own sessions,
    the supervisor itself, not-yet-registered workers, empty ledgers) is
    silently ignored.

Ledger discovery (v3 shard layout, with v2 flat fallback):
  1. Walk UP from the hook's cwd looking for a .supervisor/ directory
     (worker may have been started in a subdirectory). If the walk-up
     finds nothing and the cwd is inside a git repository, locate the
     main worktree via `git rev-parse --git-common-dir` and look there
     (linked-worktree support).
  2. Inside .supervisor/, scan SHARDS ONLY: directories whose name is a
     36-char UUID (whitelist). archive/ and any non-UUID directory are
     invisible by construction.
  3. The shard whose workers[].session_id equals the hook's session_id
     is selected. Multiple hits -> newest registered_at wins; still
     ambiguous -> no delivery, no ledger write (never mis-deliver).
  4. Zero shard hits but shards exist -> one flat state.json workers[]
     check (v2 upgrade-window compatibility: a legacy round keeps its
     interrupt delivery after the first v3 shard appears).
  5. Zero shards -> flat .supervisor/state.json (pure v2 behavior).

Supervisor resolution (never name-only):
  1. state.supervisor_session_id matches a live session -> use it
  2. state.supervisor_name matches AND the session's cwd equals
     state.project_dir -> use it (freshest by updatedAt).
     DISABLED as soon as ANY shard exists (n_shards >= 1, see case18b for
     the exactly-one-shard upgrade window): a dead target must not
     fall through to a same-name stranger in the same directory.
  3. otherwise: no delivery; the interrupt is still persisted for catch-up.

Delivery semantics: `delivered` only means "bytes written into the UDS".
Every entry starts with handled=false; the supervisor acknowledges by id in
the selected ledger's acknowledged.jsonl (its single-writer ledger). Catch-up
= interrupts whose id is not acknowledged.

Timing budget: connect+send bounded to ~1s each, no waiting recv, no fsync.
Any failure path exits 0 silently.

Settings registration (done by install.sh):
  hooks.StopFailure -> python3 <this file>
"""
import glob
import json
import os
import re
import socket
import subprocess
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

RATE_LIMIT_MARKERS = ("429", "rate limit", "ratelimit", "overloaded", "529",
                      "too many requests", "quota")
NETWORK_MARKERS = ("econnreset", "econnrefused", "timeout", "timed out",
                   "fetch failed", "network", "connection", "socket hang up")

UDS_CONNECT_TIMEOUT = 1.0
UDS_SEND_TIMEOUT = 1.0


def classify_error(err):
    e = (err or "").lower()
    if any(m in e for m in RATE_LIMIT_MARKERS):
        return "rate-limit"
    if any(m in e for m in NETWORK_MARKERS):
        return "network"
    return "api-error"


def as_text(v, fallback=""):
    """Coerce arbitrary JSON values to a short display string, safely."""
    if v is None:
        return fallback
    if isinstance(v, str):
        return v
    try:
        return json.dumps(v, ensure_ascii=False)
    except Exception:
        return fallback


def load_sessions():
    """Return list of parsed ~/.claude/sessions/<pid>.json entries."""
    out = []
    for p in glob.glob(os.path.join(SESSIONS_DIR, "*.json")):
        try:
            with open(p) as f:
                o = json.load(f)
            if not isinstance(o, dict):
                continue
            out.append(o)
        except Exception:
            continue
    return out


def find_peer_token(pid, proc_start):
    """Locate the published peerToken file for a session pid."""
    if not isinstance(pid, int):
        return None
    for p in glob.glob(os.path.join(SESSIONS_DIR, "%d.*.key" % pid)):
        try:
            with open(p) as f:
                o = json.load(f)
            if not isinstance(o, dict):
                continue
            # sanity: match procStart so a recycled pid can't fool us
            if proc_start and o.get("procStart") != proc_start:
                continue
            tok = o.get("peerToken")
            return tok if isinstance(tok, str) else None
        except Exception:
            continue
    return None


def find_supervisor_root(start_dir):
    """Walk up from start_dir looking for a .supervisor DIRECTORY.

    Returns its absolute path or None. Presence of the directory stops the
    walk even when it holds no usable ledger (safer than walking past a
    foreign project's .supervisor into an outer one).
    """
    d = os.path.abspath(start_dir)
    while True:
        p = os.path.join(d, ".supervisor")
        if os.path.isdir(p):
            return p
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def find_via_git(start_dir):
    """Linked-worktree support: worker runs in a worktree, the ledger lives
    in the main worktree. `git rev-parse --git-common-dir` is the
    deterministic way to the main worktree's gitdir; its parent is the
    main worktree root. Returns a .supervisor path or None."""
    try:
        out = subprocess.run(
            ["git", "-C", start_dir, "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, timeout=5)
        if out.returncode != 0:
            return None
        gd = (out.stdout or "").strip()
        if not gd:
            return None
        root = os.path.dirname(
            os.path.abspath(os.path.join(start_dir, gd)))
        cand = os.path.join(root, ".supervisor")
        return cand if os.path.isdir(cand) else None
    except Exception:
        return None


def load_shards(sup_dir):
    """UUID-whitelisted shard states under .supervisor/.

    Returns list of (state_dict, shard_dir). archive/ and any non-UUID
    directory are invisible by construction (never parsed, never matched).
    """
    shards = []
    try:
        names = sorted(os.listdir(sup_dir))
    except OSError:
        return shards
    for name in names:
        if not SHARD_NAME_RE.match(name):
            continue
        sd = os.path.join(sup_dir, name)
        sp = os.path.join(sd, "state.json")
        if not os.path.isfile(sp):
            continue
        try:
            with open(sp) as f:
                st = json.load(f)
            if isinstance(st, dict):
                shards.append((st, sd))
        except Exception:
            continue  # half-written by its supervisor; treat as absent
    return shards


def worker_sid_in(state, session_id):
    """True if session_id appears in state's workers[]."""
    if not session_id:
        return False
    workers = state.get("workers")
    if not isinstance(workers, list):
        return False
    return any(isinstance(w, dict) and w.get("session_id") == session_id
               for w in workers)


def load_flat(sup_dir):
    """Legacy flat .supervisor/state.json, or None."""
    p = os.path.join(sup_dir, "state.json")
    if not os.path.isfile(p):
        return None
    try:
        with open(p) as f:
            st = json.load(f)
        if isinstance(st, dict):
            return st
    except Exception:
        pass
    return None


def _resolve_in(sup_dir, session_id):
    """Try to resolve the ledger inside one candidate .supervisor dir.
    Returns (state_dict, ledger_dir, n_shards) or None."""
    shards = load_shards(sup_dir)

    if not shards:
        # pure v2 layout: flat only
        st = load_flat(sup_dir)
        if st is not None:
            return st, sup_dir, 0
        return None

    # shard selection by the hook's own session_id (dev-0 settled source)
    hits = []
    for st, sd in shards:
        if worker_sid_in(st, session_id):
            reg = ""
            for w in st.get("workers") or []:
                if isinstance(w, dict) and w.get("session_id") == session_id:
                    r = w.get("registered_at")
                    if isinstance(r, str) and r > reg:
                        reg = r
            hits.append((st, sd, reg))

    if len(hits) == 1:
        st, sd, _ = hits[0]
        return st, sd, len(shards)

    if len(hits) > 1:
        latest = max(h[2] for h in hits)
        best = [h for h in hits if h[2] == latest]
        if len(best) == 1:
            return best[0][0], best[0][1], len(shards)
        # same worker registered in multiple shards with equal recency:
        # cannot tell which team owns this interrupt -> drop it entirely
        sys.stderr.write(
            "worker-stopfailure: session %s matches %d shards with equal "
            "registered_at; refusing to guess, no delivery, no ledger "
            "write\n" % (session_id, len(best)))
        return None

    # zero shard hits + shards exist: v2 upgrade-window fallback channel
    st = load_flat(sup_dir)
    if st is not None and worker_sid_in(st, session_id):
        return st, sup_dir, len(shards)
    return None


def resolve_ledger(cwd, session_id):
    """Select the ledger this interrupt belongs to.

    Returns (state_dict, ledger_dir, n_shards) or None. ledger_dir is the
    shard dir for shard flow, or the .supervisor dir itself for flat flow
    (both legacy-only and the shard-coexistence fallback channel).

    Candidate order: nearest ancestor .supervisor first; only when that
    yields NOTHING for this session do we try the git-common-dir main
    worktree -- a worktree nested under a foreign supervised project
    would otherwise have its real ledger shadowed by the foreign
    ancestor's .supervisor (CR2).
    """
    up = find_supervisor_root(cwd)
    if up is None:
        git = find_via_git(cwd)
        if git is None:
            return None  # not inside a supervised project
        return _resolve_in(git, session_id)
    r = _resolve_in(up, session_id)
    if r is not None:
        return r
    git = find_via_git(cwd)
    if git is not None and os.path.abspath(git) != os.path.abspath(up):
        return _resolve_in(git, session_id)
    return None


def resolve_supervisor(sessions, st, n_shards=0):
    """Resolve the supervisor session. Session-id match first, then
    name+cwd==project_dir. Never name-only (P1-2). Pass-2 is disabled
    once ANY shard exists (>=1): a dead target must not fall through to
    a same-name stranger in the same directory."""
    proj = st.get("project_dir")
    want_sid = st.get("supervisor_session_id")
    want_name = st.get("supervisor_name") or "supervisor"

    def live(o):
        sock = o.get("messagingSocketPath")
        return isinstance(sock, str) and sock and os.path.exists(sock)

    def info(o):
        return {
            "pid": o.get("pid"),
            "proc_start": o.get("procStart"),
            "socket": o.get("messagingSocketPath"),
            "session_id": o.get("sessionId"),
            "token": find_peer_token(o.get("pid"), o.get("procStart")),
        }

    # pass 1: exact session identity
    if want_sid:
        cands = [o for o in sessions
                 if o.get("sessionId") == want_sid and live(o)]
        if cands:
            return info(cands[0])

    # pass 2: name match AND session cwd is the supervised project dir.
    # Disabled as soon as ANY shard exists (n_shards >= 1): the v2-upgrade
    # window (flat v2 ledger + one v3 shard) is exactly the case where the
    # dead v2 supervisor's same-name same-cwd v3 successor would receive a
    # misdelivered interrupt from a v2 worker.
    if n_shards >= 1:
        return None
    cands = [o for o in sessions
             if o.get("name") == want_name and live(o)
             and isinstance(o.get("cwd"), str)
             and proj and os.path.abspath(o["cwd"]) == os.path.abspath(proj)]
    if cands:
        best = max(cands, key=lambda o: o.get("updatedAt") or 0)
        return info(best)

    return None


def send_uds(sock_path, token, body):
    """Inject auth + user frames into a peer messaging socket. Bounded time."""
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
        return True  # NOTE: write success only, not a delivery ack
    except OSError:
        return False
    finally:
        try:
            s.close()
        except OSError:
            pass


def append_interrupt(state_dir, entry):
    """Persist the interrupt for supervisor catch-up (append-only file,
    flushed but not fsynced: bounded time beats crash durability here)."""
    try:
        os.makedirs(state_dir, exist_ok=True)
        path = os.path.join(state_dir, "interrupts.jsonl")
        with open(path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
            f.flush()
    except OSError:
        pass


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
    error = as_text(data.get("error"))
    error_details = as_text(data.get("error_details"))
    transcript = data.get("transcript_path") or ""
    if not isinstance(transcript, str):
        transcript = ""

    found = resolve_ledger(cwd, session_id)
    if not found:
        return  # not inside a supervised project / ambiguous shard
    st, state_dir, n_shards = found
    if st.get("done"):
        return

    # ---- strict identity gate: this session must be a registered worker ----
    my_name = None
    my_phase = "unknown"
    registered = False
    workers = st.get("workers")
    if isinstance(workers, list):
        for w in workers:
            if isinstance(w, dict) and w.get("session_id") == session_id \
                    and session_id:
                registered = True
                my_name = w.get("name") or session_id
                my_phase = w.get("phase") or "unknown"
                break
    if not registered:
        return  # user's own session / supervisor / not-yet-registered worker

    kind = classify_error(error or error_details)
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    err_short = (error or error_details or "unknown error").strip()[:300]

    entry = {
        "id": uuid.uuid4().hex[:10],
        "ts": ts,
        "kind": kind,
        "worker": my_name,
        "worker_session_id": session_id,
        "phase": my_phase,
        "error": err_short,
        "delivered": False,
        "handled": False,
    }

    # everything below is exception-guarded so the single append at the end
    # is always reached with a valid entry (worst case: delivered=False)

    sup = None
    try:
        sup = resolve_supervisor(load_sessions(), st, n_shards)
    except Exception:
        sup = None
    if sup and sup.get("socket"):
        body = (
            "WORKER INTERRUPTED (StopFailure hook 自动上报) [id: %s]\n"
            "worker: %s (session_id: %s)\n"
            "phase: %s\n"
            "kind: %s\n"
            "error: %s\n"
            "transcript: %s\n"
            "时间: %s\n"
            "说明: worker 的回合因上述错误被掐断，进程仍在，无法自行发言。"
            "若为限流/网络类错误，建议退避约 5 分钟后 SendMessage 让它从中断点继续；"
            "多次唤醒无回应则升级用户。处理完毕请在 acknowledged.jsonl 记录 id=%s。\n"
            % (entry["id"], my_name, session_id, my_phase, kind,
               err_short, transcript, ts, entry["id"]))
        try:
            entry["delivered"] = send_uds(sup["socket"], sup.get("token"), body)
        except Exception:
            pass

    # single append, after the send attempt, so `delivered` reflects the
    # UDS write outcome (write success only -- the ack ledger is the real
    # delivery confirmation)
    append_interrupt(state_dir, entry)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
