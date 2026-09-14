#!/usr/bin/env python3
"""
Claude Code SessionStart hook: inject this session's identity into the
model's context as a single stdout line.

    SESSION_ID <36-char-uuid> <source>

Everyone (supervisor / worker) then knows their own session_id from turn
one, mechanically - no LLM registry scanning, no guessing.

Dumb by design:
  - reads stdin JSON only (session_id / source / cwd);
  - writes NOTHING to disk (zero file I/O - only an isdir() existence
    check for the resume hint gating);
  - on source=resume AND <cwd>/.supervisor/ existing, appends ONE extra
    line telling a resumed supervisor to re-check its registry entry
    (mechanical trigger for the resume-recovery flow; the existence gate
    keeps unrelated projects noise-free);
  - any failure path: silent exit 0 (a missing injection line is covered
    by the sessions-registry scan fallback in the protocol, never blocks
    the session).

Settings registration (done by install.sh, user-level):
  hooks.SessionStart -> python3 <this file>
"""
import json
import os
import sys


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(data, dict):
        return

    sid = data.get("session_id")
    source = data.get("source")
    cwd = data.get("cwd")
    if not isinstance(sid, str) or not sid:
        return
    if not isinstance(source, str):
        source = ""
    if not isinstance(cwd, str):
        cwd = ""

    print("SESSION_ID %s %s" % (sid, source))

    if source == "resume" and cwd \
            and os.path.isdir(os.path.join(cwd, ".supervisor")):
        print("若你是 supervisor：读 %s/.supervisor/registry.json 核对本方条目"
              "（name 与自身当前名不符 / stale=true / 条目缺失 → 立即走 resume"
              " 恢复流程）" % cwd)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
