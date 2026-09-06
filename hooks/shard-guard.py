#!/usr/bin/env python3
"""
Claude Code PreToolUse hook (matcher: Write|Edit): shard guard.

Mechanically blocks the two ways an LLM can mis-write the v3 supervisor
storage layer with the Write/Edit tools:

  1. writing into another supervisor's shard directory
     ( .supervisor/<uuid>/... ): allowed only when the path's uuid equals
     THIS session's session_id; anything else -> exit 2 with a stderr
     correction message (stderr is shown to the model and works as the
     fix-it channel);
  2. writing .supervisor/registry.json directly: ALWAYS denied - it is the
     single multi-writer core file; every legal write goes through
     ~/.agent-mail/registry.py (which the model invokes via Bash).

Everything else is allowed, including archive/ dirs and the legacy flat
state.json (they simply don't match the .supervisor/<uuid>/ pattern).

Cheap short-circuit: the raw stdin text is checked for the substring
".supervisor/" BEFORE any JSON parsing - the overwhelmingly common case
(an ordinary business file write) pays one string check, zero parsing.
This guard is a tripwire, not a wall: Bash can still write anywhere, and
that is covered by the protocol's own red lines.

Writes nothing to disk (stderr messages only). Any failure path exits 0
silently - a guard that crashes must never block legit work.

Settings registration (done by install.sh, user-level):
  hooks.PreToolUse (matcher "Write|Edit") -> python3 <this file>
"""
import json
import re
import sys

UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def deny(msg):
    sys.stderr.write("DENIED_BY_GUARD: %s\n" % msg)
    sys.exit(2)


def main():
    raw = sys.stdin.read()

    # cheap short-circuit: nothing supervisor-related in the payload at all
    if ".supervisor/" not in raw:
        return

    try:
        data = json.loads(raw)
    except Exception:
        return  # can't judge reliably -> never block on garbage input
    if not isinstance(data, dict):
        return

    ti = data.get("tool_input")
    if not isinstance(ti, dict):
        return
    fp = ti.get("file_path")
    if not isinstance(fp, str) or not fp or ".supervisor/" not in fp:
        return

    # path relative to the .supervisor/ root
    rest = fp[fp.find(".supervisor/") + len(".supervisor/"):]
    head = rest.split("/")[0]

    # rule 2: registry.json direct write -> always denied
    if head == "registry.json":
        deny(".supervisor/registry.json 是多写者核心文件（fcntl 并发锁在"
             " ~/.agent-mail/registry.py 内）——Write/Edit 直编会击穿并发安全。"
             "合法写操作一律经 registry.py 子命令（Bash 调用）。")

    # rule 1: shard write -> path uuid must equal this session's session_id
    if UUID_RE.fullmatch(head):
        sid = data.get("session_id")
        if not isinstance(sid, str):
            sid = ""
        if sid == head:
            return  # own shard
        deny("写错分片——目标 .supervisor/%s/ 属于 session_id=%s 的"
             " supervisor，与你的 session_id=%s 不符。若你就是该 supervisor："
             "你的分片目录是 .supervisor/%s/。若你是 worker：registry.json 与"
             "一切分片内容对你只读。" % (head, head, sid, sid))

    # non-UUID head (archive/, legacy flat files, tmp files) -> allow
    return


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        pass
    sys.exit(0)
