#!/bin/bash
# 探针1(v2 修复版): SessionStart hook 注入用户级待办清单
# 发现记录: 手拼 JSON 的多行 additionalContext 产生裸换行=非法 JSON（探针首测发现），
# 必须 json.dumps 生成。这是该机制的真实集成成本之一。
TODO_FILE="$HOME/.claude/user-todos.json"
if [ -f "$TODO_FILE" ]; then
  python3 - "$TODO_FILE" << 'PYEOF'
import json, sys
try:
    todos = json.load(open(sys.argv[1]))
    pending = [t for t in todos if t.get('status') == 'pending']
    if pending:
        lines = [f'[user-todo 提醒] 你有 {len(pending)} 条用户级待办未完成:']
        lines += [f"  - {t.get('subject','?')} (创建于 {t.get('created','?')})" for t in pending[:5]]
        ctx = '\n'.join(lines)
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}))
except Exception:
    pass
PYEOF
fi
