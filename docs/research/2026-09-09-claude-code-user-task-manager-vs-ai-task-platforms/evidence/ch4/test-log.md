# ch4 实测记录（2026-09-09，2.1.259 / macOS arm64）

## M1: c9watch CLI（v0.9.0 release 直装，A 级）
- `$ /tmp/c9w/c9watch list --pretty` → 列出本机 8 个 Claude Code 会话（含 WaitingForInput/NeedsAttention 状态、firstPrompt、messageCount、projectPath）
- `$ /tmp/c9w/c9watch status --pretty` → byProject 聚合 + **needsPermission 数组：抓到 economy-strategy 的 AskUserQuestion 挂起与本会话 f11e1dc6 的 Bash 权限请求（pendingToolName 字段）**——7b 视角的 A 级证据：它读出了"哪个会话在等什么"
- `$ /tmp/c9w/c9watch tasks <sid> --pretty` → 读会话 TodoWrite 快照（活跃会话实时；0c19f7c5 历史会话不在其列表范围，报 No session found）——7c 的 A 级证据
- `$ /tmp/c9w/c9watch history/search/cost/view/stop/self --help` → 会话考古全套
- 能力面结论：本机聚合监控 ✓；README 称 mobile/web 客户端走 WebSocket+QR（B 级，未实测手机端）

## M2: Vibe Kanban 0.1.44（npx 启动实测，A 级）
- `$ npx -y vibe-kanban@latest` → 下载 45.8MB 二进制 → 起本地 web server（日志原文：`Main server on :64742, Preview proxy on :64743; Opening browser...`）——本地浏览器形态确认
- 子命令：`review`（审查 CLI）/ `mcp`（MCP server 模式——vibe-kanban mcp 可把看板暴露给 Claude）
- sunsetting 现状：0.1.44 为 2026-04-24 最后 release，npx 拉的即此版

## M3: claude.ai web / Remote Control（本机面 A 级 + 文档 C 级）
- 本机 8 会话（`claude agents --json` 实测，与 c9watch list 一致）
- settings.json `remoteControlAtStartup` 未设置（default）——用户当前未开启自动 Remote Control；需显式 `/rc` 或 `claude remote-control` 启动
- 7b-同步机制（C 级文档原文，ch1 已固化）：手机批准权限提示驱动本机运行中会话

## M4: Claude Squad（brew 可装性验证，B 级）
- `$ brew info claude-squad` → stable 1.0.20 bottled（可一键安装；时间盒内未做完整 TUI 实测——README B 级机制：tmux+worktrees）

## M5: Conductor / Nimbalyst（安装形态记录，C 级官网）
- Conductor: Mac app 下载（v0.84.2），Free 档；时间盒内未装
- Nimbalyst: 桌面 app（MIT，当日 push 活跃）；时间盒内未装

## M6: Linear MCP（前提：用户已订阅官方远程 MCP——supervisor 会话工具列表为证，C 级）
- linear.app/docs/mcp 原文：Streamable HTTP 远程 MCP，find/create/update issues，"Connect to our MCP server natively in Claude"

## 渠道状态（supervisor 代跑结论转达）
- WebSearch 双方（worker+supervisor 会话）当日均故障复现——口碑面（HN/Reddit）缺失维持 ch3 显式声明，7b 判定门槛不依赖口碑（门槛=A 级实测或 C 级文档原文）
