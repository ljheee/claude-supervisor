# ch2 探针记录（A 级，2026-09-09，环境 2.1.259 / macOS）

## 探针1: SessionStart hook 注入用户级待办（脚本 probe1-sessionstart-hook.sh）
- 机制：settings.json 用户级 hooks.SessionStart 注册脚本 → 会话启动 stdin 得 {session_id, source, cwd} → 脚本读 ~/.claude/user-todos.json → stdout 输出 {"hookSpecificOutput":{...,"additionalContext":"..."}} 注入模型上下文
- v1 发现真实集成成本：手拼 JSON 的多行 additionalContext 裸换行=非法 JSON（JSONDecodeError: Invalid control character），v2 改 json.dumps 修复
- v2 输出（probe1-output.txt）：合法 JSON，2 条 pending 注入成功
- 扩展点证据：本仓库 session-start-injector.py 即此机制活样本（A 级：本会话启动时的 SESSION_ID 注入行）；settings.json 注册形态已实测（hooks.SessionStart → python3 <path>）
- 结论：G1"提醒"环节 + "每个新会话可见待办"可行，成本=1 个 bash/python 脚本

## 探针2: hook stdin 契约（复用活样本）
- echo '{"session_id":...,"source":"startup","cwd":...}' | session-start-injector.py → "SESSION_ID <uuid> startup"，退出码 0
- stdin 字段：session_id/source/cwd（resume 时 source=resume）
- 用户级注册实证：~/.claude/settings.json hooks.SessionStart（A 级）

## 探针3: MCP server 最小骨架（probe3-mcp-server-skeleton.py + probe3-output.jsonl）
- stdio JSON-RPC 三请求自测通过：initialize → tools/list（1 个工具 list_user_todos）→ tools/call 返回模拟结果
- 说明 task 管理工具可经 MCP 暴露给所有会话（claude mcp add --scope user 后全项目可用，C 级：官方文档）
- 集成成本：~50 行 Python；不装真实配置，仅验证协议骨架

## 探针4: 用户级 skill 结构（活样本）
- ~/.claude/skills/<name>/SKILL.md（frontmatter: name/description）——A 级：本机 code-repo-search、mtcurl 两个已装
- 管理入口可做成 /todo 类 skill：模型自主调用或用户 /todo 触发

## B 级扩展点行号（本仓库）
- install.sh:168-169（hook 事件注册表：StopFailure/SessionStart/PreToolUse）
- install.sh:33-35（settings.json 原子写保护——持久层配置安装的安全模式先例）
- DESIGN.md:100,176（分片单写者原子写纪律）
- DESIGN.md:230-234（watchdog cron + 告警去重梯度——用户级"提醒"的外部驱动先例）
- DESIGN.md:128（进程死亡无 in-process 机制可用——外部队列必要性的原理依据）
- commands/（_core-supervisor.md + 模式层安装期拼接——用户级命令/skill 分发先例）
