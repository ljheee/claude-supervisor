#!/usr/bin/env python3
"""
claude-supervisor v3: registry.json concurrency-safe helper.

The registry (.supervisor/registry.json) is the ONLY multi-writer file in
the v3 layout. Every mutation goes through this script so the whole
read-modify-write is serialized by an exclusive fcntl lock (timeout 5s;
failure escalates to a non-zero exit, never a half-written file).

Protocol contract (spec F1):
  - register  : idempotent upsert keyed by session_id. Two-phase CLI:
                  no --isolation-confirmed + other ACTIVE supervisors
                    -> print their list, exit 2, write NOTHING
                  name collision with another ACTIVE entry
                    -> print explanation, exit 3, write NOTHING
                  --isolation-confirmed re-reads and verifies the set of
                  OTHER active entries has not GROWN, then writes.
                Upsert refreshes name and clears the entry's own stale
                flag (resume self-heals).
  - heartbeat : touch heartbeat_ts on own entry only (creates it if
                missing, with the provided name -- recovery convenience).
  - unregister: delete own entry only. Never touches anyone else's.
  - mark-stale: set stale=true on a given session_id (never deletes).

All writes are tmp-file + os.replace atomic. Exit codes:
  0 success / 2 isolation confirmation needed / 3 name collision /
  4 lock timeout (escalate to user) / 1 bad usage or entry not found.
"""
import argparse
import fcntl
import json
import os
import sys
import tempfile
import time

LOCK_TIMEOUT = 5.0
STALE_AFTER_MINUTES = 30  # informational; enforcement lives in the protocol


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime())


def die(code, msg):
    print(msg, file=sys.stderr)
    sys.exit(code)


def acquire_lock(registry_path):
    lock_path = registry_path + ".lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    deadline = time.monotonic() + LOCK_TIMEOUT
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.monotonic() >= deadline:
                os.close(fd)
                die(4, "registry lock timeout (%.0fs): another registry.py "
                       "is stuck; escalate to the user." % LOCK_TIMEOUT)
            time.sleep(0.05)


def write_txn(registry_path, mutate):
    """Hold the lock, read-modify-write the registry, atomic replace."""
    lock_fd = acquire_lock(registry_path)
    try:
        data = {"supervisors": []}
        if os.path.isfile(registry_path):
            try:
                with open(registry_path) as f:
                    data = json.load(f)
            except Exception:
                # half-written/corrupt file under lock: reset rather than die
                data = {"supervisors": []}
        if not isinstance(data, dict) or \
                not isinstance(data.get("supervisors"), list):
            data = {"supervisors": []}
        result = mutate(data["supervisors"])
        if result is not None:  # None = no write requested
            d = os.path.dirname(registry_path) or "."
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".registry.",
                                       suffix=".tmp")
            try:
                with os.fdopen(fd, "w") as f:
                    json.dump({"supervisors": data["supervisors"]},
                              f, ensure_ascii=False, indent=2)
                    f.write("\n")
                os.replace(tmp, registry_path)
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
        return result
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)


def active_others(supervisors, my_sid):
    return [s for s in supervisors
            if isinstance(s, dict) and s.get("session_id") != my_sid
            and not s.get("stale")]


def entry_line(s):
    return ("  - %s  sid=%s  mode=%s  branch=%s  goal=%s" % (
        s.get("name"), (s.get("session_id") or "")[:8],
        s.get("mode"), s.get("branch"), s.get("goal_brief")))


def read_registry(registry_path):
    if not os.path.isfile(registry_path):
        return {"supervisors": []}
    try:
        with open(registry_path) as f:
            data = json.load(f)
        if isinstance(data, dict) and \
                isinstance(data.get("supervisors"), list):
            return data
    except Exception:
        pass
    return {"supervisors": []}


# ---------------------------------------------------------------- commands

def cmd_register(args, registry_path):
    my_sid = args.session_id

    def txn(supervisors, confirmed=False):
        others = active_others(supervisors, my_sid)
        # resume short-circuit: my own entry already exists -> plain upsert
        # (isolation was confirmed at first registration; name check kept)
        mine = [s for s in supervisors
                if isinstance(s, dict) and s.get("session_id") == my_sid]
        # name uniqueness assertion (SendMessage routes by name only)
        for s in others:
            if s.get("name") == args.name:
                print("NAME COLLISION: active supervisor sid=%s already uses "
                      "name '%s'. /rename to a unique name first."
                      % (s.get("session_id")[:8], args.name))
                return "name-collision"
        if others and not confirmed and not mine:
            print("ACTIVE SUPERVISORS in this project:")
            for s in others:
                print(entry_line(s))
            print("Re-run with --isolation-confirmed after the user has "
                  "confirmed branch/worktree isolation.")
            return "need-confirm"
        if confirmed:
            # verify the other-active set has not GROWN since first attempt
            try:
                known = set(json.loads(args.known_others or "[]"))
            except Exception:
                die(1, "--known-others must be a JSON array of session_ids")
            known = {s for s in known if isinstance(s, str)}
            grown = [s for s in others
                     if s.get("session_id") not in known]
            if grown:
                print("ABORT: new active supervisors appeared during "
                      "confirmation:")
                for s in grown:
                    print(entry_line(s))
                return "grown"
        # idempotent upsert keyed by sid: field-level merge (unspecified
        # args keep their existing values; name/stale/heartbeat refresh)
        updated = False
        entry = None
        for i, s in enumerate(supervisors):
            if isinstance(s, dict) and s.get("session_id") == my_sid:
                entry = dict(s)
                entry["session_id"] = my_sid
                entry["name"] = args.name
                for key, val in (("mode", args.mode), ("goal_brief", args.goal),
                                 ("project_dir", args.project_dir),
                                 ("branch", args.branch)):
                    if val:
                        entry[key] = val
                entry["heartbeat_ts"] = now_iso()
                entry["stale"] = False
                entry.setdefault("started_at", now_iso())
                supervisors[i] = entry
                updated = True
                break
        if not updated:
            supervisors.append({
                "session_id": my_sid,
                "name": args.name,
                "mode": args.mode or "",
                "goal_brief": args.goal or "",
                "project_dir": args.project_dir or "",
                "branch": args.branch or "",
                "started_at": now_iso(),
                "heartbeat_ts": now_iso(),
                "stale": False,
            })
        return "ok"

    if args.isolation_confirmed:
        if not args.known_others:
            die(1, "--isolation-confirmed requires --known-others (the "
                   "session_id list from the first attempt's output).")
        r = write_txn(registry_path,
                      lambda sup: txn(sup, confirmed=True))
    else:
        r = write_txn(registry_path, lambda sup: txn(sup))
    if r == "need-confirm":
        sys.exit(2)
    if r == "name-collision":
        sys.exit(3)
    if r == "grown":
        sys.exit(2)
    print("registered: %s (sid=%s)" % (args.name, my_sid))


def cmd_heartbeat(args, registry_path):
    def txn(supervisors):
        for s in supervisors:
            if isinstance(s, dict) and s.get("session_id") == args.session_id:
                s["heartbeat_ts"] = now_iso()
                s["stale"] = False
                return "ok"
        # convenience: entry vanished (crash cleanup) -> recreate minimal
        supervisors.append({
            "session_id": args.session_id,
            "name": args.name or "supervisor",
            "mode": "", "goal_brief": "", "project_dir": "",
            "branch": "",
            "started_at": now_iso(),
            "heartbeat_ts": now_iso(),
            "stale": False,
        })
        return "ok"
    write_txn(registry_path, txn)
    print("heartbeat ok")


def cmd_unregister(args, registry_path):
    def txn(supervisors):
        n = len(supervisors)
        supervisors[:] = [s for s in supervisors
                          if not (isinstance(s, dict)
                                  and s.get("session_id")
                                  == args.session_id)]
        return "ok" if len(supervisors) < n else "absent"
    r = write_txn(registry_path, txn)
    if r == "absent":
        die(1, "no registry entry for sid %s (nothing to remove)"
            % args.session_id)
    print("unregistered: sid %s" % args.session_id)


def cmd_mark_stale(args, registry_path):
    def txn(supervisors):
        for s in supervisors:
            if isinstance(s, dict) and s.get("session_id") == args.session_id:
                s["stale"] = True
                return "ok"
        return "absent"
    r = write_txn(registry_path, txn)
    if r == "absent":
        die(1, "no registry entry for sid %s" % args.session_id)
    print("marked stale: sid %s" % args.session_id)


def cmd_list(registry_path):
    data = read_registry(registry_path)
    rows = [s for s in data.get("supervisors", []) if isinstance(s, dict)]
    if not rows:
        print("(no supervisors registered)")
        return
    print("registry: %d supervisor(s)" % len(rows))
    for s in rows:
        flag = " STALE" if s.get("stale") else ""
        print(entry_line(s) + flag)


def main():
    # env override for testing (install path: ~/.agent-mail/registry.py)
    base = os.environ.get("CLAUDE_SUPERVISOR_DIR")
    if base:
        default_registry = os.path.join(base, "registry.json")
    else:
        default_registry = ".supervisor/registry.json"

    p = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("register")
    pr.add_argument("--session-id", required=True)
    pr.add_argument("--name", required=True)
    pr.add_argument("--mode")
    pr.add_argument("--goal")
    pr.add_argument("--project-dir")
    pr.add_argument("--branch")
    pr.add_argument("--isolation-confirmed", action="store_true")
    pr.add_argument("--known-others",
                    help="JSON array of other active session_ids, from the "
                         "first attempt's exit-2 output")

    ph = sub.add_parser("heartbeat")
    ph.add_argument("--session-id", required=True)
    ph.add_argument("--name")

    pu = sub.add_parser("unregister")
    pu.add_argument("--session-id", required=True)

    ps = sub.add_parser("mark-stale")
    ps.add_argument("--session-id", required=True)

    sub.add_parser("list")

    args = p.parse_args()
    registry_path = os.path.abspath(default_registry)

    if args.cmd == "register":
        cmd_register(args, registry_path)
    elif args.cmd == "heartbeat":
        cmd_heartbeat(args, registry_path)
    elif args.cmd == "unregister":
        cmd_unregister(args, registry_path)
    elif args.cmd == "mark-stale":
        cmd_mark_stale(args, registry_path)
    else:
        cmd_list(registry_path)


if __name__ == "__main__":
    main()
