# ch3 检索与核验记录（2026-09-09）

## 渠道状态
- WebSearch 渠道当日异常（多轮空返回），全程降级为：gh CLI（GitHub 搜索/API/README 抓取）+ WebFetch 官网直连 + curl 兜底
- 中文关键词轮已执行（GitHub 内 "claude code 任务管理" / "agent 看板"）：发现 dpp814/agent-dashboard（1★，中文，本地看板+浏览器处理授权）；无其他成规模中文生态产品 → 结论"英文生态主导"（README 语言抽样佐证）

## 候选池元数据快照（gh api repos/<repo>，时点 2026-09-09）
| 平台 | repo | stars | 最近 push | license | 存活状态 |
|------|------|-------|-----------|---------|----------|
| Vibe Kanban | BloopAI/vibe-kanban | 28038 | 2026-04-24 | Apache-2.0 | **sunsetting**（官网横幅："will continue as open source and community maintained"；最后 release v0.1.44 = 2026-04-24，近 4.5 个月无 release）|
| Claude Squad | smtg-ai/claude-squad | 8458 | 2026-08-20 | AGPL-3.0 | 活跃 |
| VibeTunnel | amantus-ai/vibetunnel | 4651 | 2026-08-05 | MIT | 活跃 |
| Crystal→Nimbalyst | stravu/crystal (旧) / nimbalyst/nimbalyst (新) | 3115/1682 | 旧 2026-02-26 / 新 2026-09-09 | MIT/MIT | Crystal 已改名 Nimbalyst 迁移（旧 repo desc 明示） |
| Claude Code Agent Monitor | hoangsonww/Claude-Code-Agent-Monitor | 984 | 2026-09-08 | MIT | 活跃 |
| Vibeyard | elirantutia/vibeyard | 1368 | 2026-09-03 | MIT | 活跃 |
| c9watch | minchenlee/c9watch | 128 | 2026-09-08 | MIT | 活跃 |
| Sidekick for Max | cesarandreslopez/sidekick-for-claude-max | 82 | 2026-09-06 | MIT | 活跃 |
| open-sunsama | ShadowWalker2014/open-sunsama | 51 | 2026-08-26 | NOASSERTION | 活跃 |
| agent-dashboard(中) | dpp814/agent-dashboard | 1 | 2026-08-21 | MIT | 活跃（小） |

## 官网/文档核验（WebFetch/curl，C 级）
- conductor.build：Mac app，并行 Claude Code/Codex/Cursor 隔离工作区，v0.84.2，闭源；定价 Free($0)/Pro($50/mo)/Teams($60/mo/user)/Enterprise（pricing 页原文）
- vibekanban.com：npx vibe-kanban 本地跑 + 团队云版 + self-hosting guide（docs/self-hosting/deploy-docker）；sunsetting 横幅
- linear.app/docs/mcp（HTTP 200 实测）："The Model Context Protocol (MCP) server provides a standardized interface that allows any compatible AI model or agent to access your Linear data"；"Connect to our MCP server natively in Claude, Cursor"；工具含 find/create/update issues；Streamable HTTP 远程 MCP。pricing 页价格信号 $0/$10/$16（Free/Basic/Business，JS 渲染受限标 D）
- height.app：**关停中**（curl HTTP 000 + GitHub 生态工具 "Height.app is shutting down"佐证）→ 移出推荐池
- omnara.com：Apache-2.0 开源 + 云托管，REST API/SDK/CLI/dashboard/Slack；"open-source alternative to Claude Managed Agents"；无 Claude Code 专项集成表述
- terminate.now：域名售卖页（$12,988 GoDaddy）——种子名失效/已死，核验记录在案

## 反查互链（awesome-claude-code README）
发现：Nimbalyst（=Crystal 后继）、Vibeyard、c9watch、Claude-Code-Agent-Monitor、Sidekick、ralph-orchestrator、OSS Autopilot

## c9watch 关键能力（README 原文，B 级）
- "Permission requests surface to the top so you never leave an agent stuck waiting"
- "Status notifications -- Get a native macOS notification when a session needs your attention"
- "Mobile/Web client -- Connect from any browser or mobile device via WebSocket; scan the QR code to monitor sessions remotely"（token-gated mobile web）
- macOS 菜单栏 app，Rust/Tauri 2 + Svelte 5，扫 OS 进程自动发现 Claude Code 会话

## Claude Squad 机制（README 原文，B 级）
- tmux 隔离终端会话 + git worktrees 隔离代码库（TUI 形态）
