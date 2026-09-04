#!/usr/bin/env python3
"""
Claude Code StopFailure hook: automatically report an interrupted worker
session to its supervisor over the official cross-session UDS channel.

Fires when a turn ends in failure (429 rate limit exhausted, network error,
API error, ...). The worker model itself never gets a chance to send
anything in those cases - this hook is the machine-level voice it lacks.

Identity model (strict, to guarantee zero collateral damage):
  - The hook's own session_id (from stdin) MUST be listed in
    state.json workers[].session_id. Anything else (the user's own sessions,
    the supervisor itself, not-yet-registered workers, empty ledgers) is
    silently ignored.
  - The project state file is located by walking UP from the hook's cwd
    (worker may have been started in a subdirectory), then validated via
    the session_id check above.

Supervisor resolution (never name-only):
  1. state.supervisor_session_id matches a live session -> use it
  2. state.supervisor_name matches AND the session's cwd equals
     state.project_dir -> use it (freshest by updatedAt)
  3. otherwise: no delivery; the interrupt is still persisted for catch-up.

Delivery semantics: `delivered` only means "bytes written into the UDS".
Every entry starts with handled=false; the supervisor acknowledges by id in
.supervisor/acknowledged.jsonl (its single-writer ledger). Catch-up =
interrupts whose id is not acknowledged.

Timing budget: connect+send bounded to ~1s each, no waiting recv, no fsync.
Any failure path exits 0 silently.

Settings registration (done by install.sh):
  hooks.StopFailure -> python3 <this file>
"""
import glob
import json
import os
import socket
import sys
import time
import uuid

# overridable for testing
SESSIONS_DIR = os.environ.get(
    "CLAUDE_SUPERVISOR_SESSIONS_DIR",
    os.path.expanduser("~/.claude/sessions"))

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


def find_state_upward(start_dir):
    """Walk up from start_dir looking for .supervisor/state.json.

    Returns (state_dict, project_dir_of_file) or None. The session_id check
    in main() is the real gate against foreign projects found on the way up.
    """
    d = os.path.abspath(start_dir)
    while True:
        p = os.path.join(d, ".supervisor", "state.json")
        if os.path.isfile(p):
            try:
                with open(p) as f:
                    st = json.load(f)
                if isinstance(st, dict):
                    return st, d
            except Exception:
                pass  # half-written by supervisor; treat as absent
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def resolve_supervisor(sessions, st):
    """Resolve the supervisor session. Session-id match first, then
    name+cwd==project_dir. Never name-only (P1-2)."""
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

    # pass 2: name match AND session cwd is the supervised project dir
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

    found = find_state_upward(cwd)
    if not found:
        return  # not inside a supervised project
    st, state_dir_abs = found
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
    state_dir = os.path.join(state_dir_abs, ".supervisor")

    sup = None
    try:
        sup = resolve_supervisor(load_sessions(), st)
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
