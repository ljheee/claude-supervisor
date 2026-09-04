#!/usr/bin/env bash
# Install claude-supervisor slash commands for Claude Code (requires v2.1.224+ for
# cross-session messaging: ListAgents + SendMessage; StopFailure hook needs
# 2.1.259+ -- no official API to detect this, verify with `claude --version`).
#
#   /supervisor  - initialize the current session as the project supervisor
#   /worker      - register the current session as a supervised worker
#   watchdog     - external overdue-worker detector (installed to ~/.agent-mail)
#   StopFailure  - auto-report interrupted workers (hook, installed to
#                  ~/.claude/hooks/claude-supervisor/ and registered in settings.json)
#
# Safety rules:
#   - existing target files are backed up (timestamped suffix) before overwrite
#   - an unreadable ~/.claude/settings.json ABORTS the install (after backing
#     it up); it is never silently reset
#   - settings.json update is locked, atomic, and preserves file permissions
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/commands"
MAIL_HOME="${AGENT_MAIL_HOME:-$HOME/.agent-mail}"
HOOK_DIR="$HOME/.claude/hooks/claude-supervisor"
SETTINGS="$HOME/.claude/settings.json"

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

echo "==> Installing slash commands to $DEST"
mkdir -p "$DEST"
install_backup "$SRC/commands/supervisor.md" "$DEST/supervisor.md"
install_backup "$SRC/commands/worker.md" "$DEST/worker.md"

echo "==> Installing watchdog to $MAIL_HOME/supervisor-watchdog"
mkdir -p "$MAIL_HOME"
if [ -f "$MAIL_HOME/supervisor-watchdog" ] && \
   ! cmp -s "$SRC/watchdog.sh" "$MAIL_HOME/supervisor-watchdog"; then
  cp "$MAIL_HOME/supervisor-watchdog" "$MAIL_HOME/supervisor-watchdog.bak-${STAMP}"
  echo "  backed up existing supervisor-watchdog"
fi
install -m 755 "$SRC/watchdog.sh" "$MAIL_HOME/supervisor-watchdog"

echo "==> Installing StopFailure hook to $HOOK_DIR"
mkdir -p "$HOOK_DIR"
install_backup "$SRC/hooks/worker-stopfailure.py" "$HOOK_DIR/worker-stopfailure.py"

echo "==> Registering StopFailure hook in $SETTINGS"
python3 - "$SETTINGS" "$HOOK_DIR/worker-stopfailure.py" <<'PYEOF'
import fcntl
import json
import os
import shlex
import shutil
import stat
import sys

settings, script = sys.argv[1], sys.argv[2]
command = "python3 %s" % shlex.quote(script)


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

    hooks = cfg.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        print("  ERROR: hooks section of %s is not an object; aborting."
              % settings, file=sys.stderr)
        sys.exit(1)
    entries = hooks.setdefault("StopFailure", [])
    if not isinstance(entries, list):
        print("  ERROR: hooks.StopFailure of %s is not an array; aborting."
              % settings, file=sys.stderr)
        sys.exit(1)
    for group in entries:
        if not isinstance(group, dict):
            continue
        for h in group.get("hooks", []):
            if isinstance(h, dict) and same_command(h.get("command") or "", command):
                print("  StopFailure hook already registered; nothing to do")
                sys.exit(0)

    entries.append({"hooks": [{"type": "command", "command": command}]})

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
    print("  registered hooks.StopFailure -> %s" % command)
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
PYEOF

echo ""
echo "Done. 快速开始（三个终端窗口）："
echo ""
echo "  终端A（项目目录，先固定名字）:   /rename supervisor"
echo "                                 /supervisor 做一个XXX功能"
echo "  终端B（同一项目目录）:           /worker"
echo "  （可开更多终端重复 /worker，多 worker 并行受监工）"
echo ""
echo "流程: 监工督促需求澄清→向你对齐→spec审查→plan审查→逐Phase开发(先自CR再受审)→总结报告"
echo "依赖: Claude Code >= 2.1.224（ListAgents + SendMessage；StopFailure hook 需 >= 2.1.259，"
echo "      官方无检测接口，请自行 claude --version 确认）"
echo ""
echo "中断防御（可选）: cron 定时跑 watchdog，worker 失联时投递告警（路径含空格请加引号）："
echo "  */10 * * * * $MAIL_HOME/supervisor-watchdog '/path/to/repo' 60"
echo ""
echo "中断防御（已自动安装）: StopFailure hook——worker 回合因 429/网络/API 错误被掐断时，"
echo "自动向 supervisor 的 UDS 通道直投 WORKER INTERRUPTED，并落盘 .supervisor/interrupts.jsonl。"
echo "仅对被监工项目里已注册（session_id 匹配）的 worker 会话生效，其他会话零干扰。"
