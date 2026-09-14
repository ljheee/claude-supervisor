#!/usr/bin/env python3
"""探针3: MCP server 最小骨架（stdio JSON-RPC）——验证 task 管理工具可经 MCP 暴露。
不注册进真实配置；本地自测 initialize/tools/list/tools/call 三请求。"""
import json, sys

TOOLS = [{
    "name": "list_user_todos",
    "description": "列出用户级待办（跨会话聚合）",
    "inputSchema": {"type": "object", "properties": {"status": {"type": "string", "enum": ["pending", "completed"]}}}
}]

def respond(id_, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": id_, "result": result}) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    try:
        req = json.loads(line)
    except Exception:
        continue
    method, id_ = req.get("method"), req.get("id")
    if method == "initialize":
        respond(id_, {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                     "serverInfo": {"name": "user-todo-mcp", "version": "0.1.0"}})
    elif method == "tools/list":
        respond(id_, {"tools": TOOLS})
    elif method == "tools/call":
        respond(id_, {"content": [{"type": "text", "text": "[模拟] 2 条 pending: 调研任务管理器 / 回滚生产配置"}]})
    elif method == "notifications/initialized":
        pass
