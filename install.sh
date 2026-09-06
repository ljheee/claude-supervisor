#!/usr/bin/env bash
# Install claude-supervisor slash commands for Claude Code (requires
# v2.1.259+ for cross-session messaging AND the StopFailure/SessionStart/
# PreToolUse hooks used by v3 -- no official API to detect this, verify
# with `claude --version`).
#
#   /supervisor  - initialize the current session as the greenfield-mode supervisor
#   /rework      - initialize the current session as the rework/refactor supervisor
#   /worker      - register the current session as a supervised worker
#   registry.py  - v3 discovery-layer helper (installed to ~/.agent-mail, next
#                  to watchdog; all registry.json writes go through it)
#   watchdog     - external overdue-worker detector (installed to ~/.agent-mail)
#   StopFailure  - auto-report interrupted workers (hook, installed to
#                  ~/.claude/hooks/claude-supervisor/ and registered in settings.json)
#   SessionStart - v3 identity injector: prints "SESSION_ID <uuid> <source>"
#                  into every session's context (user-level registration)
#   PreToolUse   - v3 shard guard for Write|Edit: blocks cross-shard writes
#                  and direct registry.json edits (user-level registration)
#
# Command files are ASSEMBLED at install time: mode layer (frontmatter +
# mode-specific sections) + commands/_core-supervisor.md (shared core protocol).
# The core file itself is NEVER installed into ~/.claude/commands/ (it would be
# registered as a broken slash command -- underscore prefix does NOT prevent
# registration, verified in real testing); it is copied to the hooks dir as a
# reference copy only.
#
# Safety rules:
#   - existing target files are backed up (timestamped suffix) before overwrite
#   - an unreadable ~/.claude/settings.json ABORTS the install (after backing
#     it up); it is never silently reset
#   - settings.json update is locked, atomic, and preserves file permissions
#   - spliced commands failing structural assertions ABORT the install
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/commands"
MAIL_HOME="${AGENT_MAIL_HOME:-$HOME/.agent-mail}"
HOOK_DIR="$HOME/.claude/hooks/claude-supervisor"
SETTINGS="$HOME/.claude/settings.json"
CORE="$SRC/commands/_core-supervisor.md"

STAMP="$(date +%Y%m%d-%H%M%S)"

install_backup() {
  # install_backup <src> <dst>: back up existing dst (content-differs) then copy
  local src="$1" dst="$2"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    local bak="${dst}.bak-${STAMP}"
    cp "$dst" "$bak"
    echo "  backed up existing $(basename "$dst") -> $bak"
  fi
  install -m 644 "$src" "$dst"
}

# splice_command <mode-layer> <dst>: assemble mode layer + core, verify, install.
#   Structural assertions (failure aborts the install, no half-written output):
#     1. output starts with '---' (frontmatter) and the SECOND '---' line ends
#        it; no other standalone '---' line is treated as frontmatter (P2-10:
#        legal horizontal rules in the body are fine)
#     2. required core section headings are present
#     3. no duplicated '## ' headings (mode layer must not collide with core)
splice_command() {
  local mode_layer="$1" dst="$2" tmp="${2}.splice-tmp-$$"
  cat "$mode_layer" "$CORE" > "$tmp" || { rm -f "$tmp"; echo "  ERROR: cannot read splice inputs for $dst" >&2; exit 1; }
  if ! python3 - "$tmp" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().split('\n')
errors = []
if not lines or lines[0] != '---':
    errors.append('first line is not frontmatter "---"')
else:
    # frontmatter must close within the first 10 lines; a '---' later in the
    # body is a horizontal rule, NOT a frontmatter closer (P2-2: an unclosed
    # frontmatter whose body contains '---' must not pass)
    close = [i for i, l in enumerate(lines[1:10], 1) if l == '---']
    if not close:
        errors.append('frontmatter is not closed by a second "---" line within the first 10 lines')
required = ['## 你的身份与核心原则', '## 启动步骤', '## 中断与失联处理', '## 行为红线',
            '## 阶段状态机']
body = '\n'.join(lines)
for sec in required:
    if sec not in body:
        errors.append('missing core section: %s' % sec)
h2 = [l for l in lines if l.startswith('## ')]
dups = sorted(set(t for t in h2 if h2.count(t) > 1))
if dups:
    errors.append('duplicated section headings: %s' % ', '.join(dups))
if errors:
    print('  SPLICE ASSERTION FAILED for %s:' % path, file=sys.stderr)
    for e in errors:
        print('    - %s' % e, file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    rm -f "$tmp"
    echo "  ERROR: spliced $dst failed structural assertions; aborting install." >&2
    exit 1
  fi
  if [ -f "$dst" ]; then
    if ! cmp -s "$tmp" "$dst"; then
      cp "$dst" "${dst}.bak-${STAMP}"
      echo "  backed up existing $(basename "$dst") -> ${dst}.bak-${STAMP}"
    fi
  fi
  install -m 644 "$tmp" "$dst"
  rm -f "$tmp"
  echo "  installed $(basename "$dst") (spliced: $(basename "$mode_layer") + _core-supervisor.md)"
}

echo "==> Installing slash commands to $DEST (mode layer + core splice)"
mkdir -p "$DEST"
splice_command "$SRC/commands/supervisor.md" "$DEST/supervisor.md"
splice_command "$SRC/commands/rework.md" "$DEST/rework.md"
install_backup "$SRC/commands/worker.md" "$DEST/worker.md"

# core file: reference copy in hooks dir ONLY (never into ~/.claude/commands/ --
# underscore prefix does NOT prevent slash-command registration, see dev-0 test)
echo "==> Installing core protocol reference copy to $HOOK_DIR/_core-supervisor.md"
mkdir -p "$HOOK_DIR"
install_backup "$CORE" "$HOOK_DIR/_core-supervisor.md"

echo "==> Installing watchdog to $MAIL_HOME/supervisor-watchdog"
mkdir -p "$MAIL_HOME"
if [ -f "$MAIL_HOME/supervisor-watchdog" ] && \
   ! cmp -s "$SRC/watchdog.sh" "$MAIL_HOME/supervisor-watchdog"; then
  cp "$MAIL_HOME/supervisor-watchdog" "$MAIL_HOME/supervisor-watchdog.bak-${STAMP}"
  echo "  backed up existing supervisor-watchdog"
fi
install -m 755 "$SRC/watchdog.sh" "$MAIL_HOME/supervisor-watchdog"

echo "==> Installing registry.py to $MAIL_HOME/registry.py"
if [ -f "$MAIL_HOME/registry.py" ] && \
   ! cmp -s "$SRC/hooks/registry.py" "$MAIL_HOME/registry.py"; then
  cp "$MAIL_HOME/registry.py" "$MAIL_HOME/registry.py.bak-${STAMP}"
  echo "  backed up existing registry.py"
fi
# 755: core protocol invokes it as a bare executable path
# (~/.agent-mail/registry.py register ...)
install -m 755 "$SRC/hooks/registry.py" "$MAIL_HOME/registry.py"

echo "==> Installing hooks to $HOOK_DIR"
mkdir -p "$HOOK_DIR"
install_backup "$SRC/hooks/worker-stopfailure.py" "$HOOK_DIR/worker-stopfailure.py"
install_backup "$SRC/hooks/session-start-injector.py" "$HOOK_DIR/session-start-injector.py"
install_backup "$SRC/hooks/shard-guard.py" "$HOOK_DIR/shard-guard.py"

echo "==> Registering hooks in $SETTINGS (user-level)"
python3 - "$SETTINGS" "$HOOK_DIR/worker-stopfailure.py" "$HOOK_DIR/session-start-injector.py" "$HOOK_DIR/shard-guard.py" <<'PYEOF'
import fcntl
import json
import os
import shlex
import shutil
import stat
import sys

settings = sys.argv[1]
hook_scripts = sys.argv[2:]
# (event, matcher, script-index) -- None matcher means no matcher field
HOOK_REGISTRATIONS = [
    ("StopFailure", None, 0),
    ("SessionStart", None, 1),
    ("PreToolUse", "Write|Edit", 2),
]


def same_command(a, b):
    """Compare commands ignoring shell-quoting differences."""
    if a == b:
        return True
    try:
        return shlex.split(a) == shlex.split(b)
    except ValueError:
        return False

lock_path = settings + ".lock"
lock_fd = os.open(lock_path, os.O_CREAT | os.O_WRONLY, 0o644)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    cfg = None
    if os.path.exists(settings):
        try:
            with open(settings) as f:
                cfg = json.load(f)
        except Exception:
            backup = "%s.bak-%d" % (settings, os.getpid())
            shutil.copy2(settings, backup)
            print("  ERROR: %s is unreadable; backed up to %s" %
                  (settings, backup), file=sys.stderr)
            print("  ERROR: refusing to reset your global Claude settings. "
                  "Fix or remove the file, then re-run install.sh.",
                  file=sys.stderr)
            sys.exit(1)
    if cfg is None:
        cfg = {}
    if not isinstance(cfg, dict):
        print("  ERROR: %s is not a JSON object; aborting." % settings,
              file=sys.stderr)
        sys.exit(1)

    already = {}
    if "hooks" in cfg and not isinstance(cfg["hooks"], dict):
        print("  ERROR: hooks section of %s is not an object; aborting."
              % settings, file=sys.stderr)
        sys.exit(1)
    for event, matcher, idx in HOOK_REGISTRATIONS:
        script = hook_scripts[idx]
        command = "python3 %s" % shlex.quote(script)
        entries = cfg.setdefault("hooks", {}).setdefault(event, [])
        if not isinstance(entries, list):
            print("  ERROR: hooks.%s of %s is not an array; aborting."
                  % (event, settings), file=sys.stderr)
            sys.exit(1)
        found = False
        for group in entries:
            if not isinstance(group, dict):
                continue
            if matcher is not None and group.get("matcher") != matcher:
                continue
            for h in group.get("hooks", []):
                if isinstance(h, dict) and same_command(
                        h.get("command") or "", command):
                    found = True
                    break
            if found:
                break
        already[(event, matcher)] = (entries, command, found)

    for (event, matcher), (entries, command, found) in already.items():
        if found:
            label = event + (" (matcher %s)" % matcher if matcher else "")
            print("  %s hook already registered; nothing to do" % label)
            continue
        group = {"hooks": [{"type": "command", "command": command}]}
        if matcher is not None:
            group["matcher"] = matcher
        entries.append(group)
        label = event + (" (matcher %s)" % matcher if matcher else "")
        print("  registered hooks.%s -> %s" % (label, command))

    # atomic replace: unique tmp file, preserve original mode, fsync
    old_mode = None
    try:
        old_mode = stat.S_IMODE(os.stat(settings).st_mode)
    except OSError:
        pass
    import tempfile
    fd, tmp = tempfile.mkstemp(
        dir=os.path.dirname(settings) or ".",
        prefix=".settings-", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    if old_mode is not None:
        os.chmod(tmp, old_mode)
    os.replace(tmp, settings)
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
PYEOF

echo ""
echo "Done. 快速开始（多终端）："
echo ""
echo "  绿地新项目（三个终端窗口）："
echo "  终端A（项目目录，先固定名字）:   /rename supervisor"
echo "                                 /supervisor 做一个XXX功能"
echo "  终端B（同一项目目录）:           /worker"
echo ""
echo "  老项目修补/重构（同一姿势，换命令）："
echo "  终端A（项目目录）:               /rework 修复XX模块的YY问题 [--baseline <git-ref>]"
echo "  终端B（同一项目目录）:           /worker"
echo ""
echo "  （可开更多终端重复 /worker，多 worker 并行受监工）"
echo ""
echo "流程: 监工督促需求澄清→向你对齐→spec审查→plan审查→逐Phase开发(先自CR再受审)→总结报告（绿地）；rework 模式为 考古→安全网→改造规格→计划→逐Phase开发"
echo "多 supervisor 并存（v3）：同一项目可同时跑多个监工（如 /supervisor 开新模块 + /rework 改存量），"
echo "各用唯一会话名（建议 /rename supervisor-gf / supervisor-rw，含项目后缀更稳）+ 各自分支/worktree 隔离；"
echo "账本按 session_id 分片互不污染，worker 启动时从 .supervisor/registry.json 自选监工。"
echo "依赖: Claude Code >= 2.1.259（ListAgents + SendMessage + StopFailure/SessionStart/PreToolUse"
echo "      hooks；官方无检测接口，请自行 claude --version 确认）"
echo ""
echo "中断防御（可选）: cron 定时跑 watchdog，worker 失联时投递告警（路径含空格请加引号）："
echo "  */10 * * * * \"$HOME/.agent-mail/supervisor-watchdog\" '/path/to/repo' 60"
echo ""
echo "中断防御（已自动安装）: StopFailure hook——worker 回合因 429/网络/API 错误被掐断时，"
echo "自动向 supervisor 的 UDS 通道直投 WORKER INTERRUPTED，并落盘 .supervisor/<sid>/interrupts.jsonl"
echo "（v3 分片路径，<sid> 是该 supervisor 的 session_id；旧平铺布局自动兼容）。"
echo "仅对被监工项目里已注册（session_id 匹配）的 worker 会话生效，其他会话零干扰。"
echo ""
echo "v3 机械保障（已自动安装）: SessionStart 注入器——每个会话开局自动注入自身 SESSION_ID；"
echo "PreToolUse 分片守卫——Write|Edit 写错分片或直编 registry.json 时机械拦截并给出正确分片键。"
