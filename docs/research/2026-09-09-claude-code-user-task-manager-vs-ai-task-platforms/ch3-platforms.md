# ch3 · AI task 在线管理平台全景（Q6）

> goal 子题② 候选池。三类扫描：a 多 agent 会话管理器 / b 官方云端 / c 通用任务平台+AI 集成。
> 时点 2026-09-09；stars/最近 push 均为当日 gh api 快照（evidence/ch3/search-log.md 可复现）。
> 证据分级：B=仓库 README/API 元数据一手 / C=官网页面引文 / D=转述或 JS 渲染受限页。

## 候选全景表（12 家）

| 平台 | 类 | 定位 | 部署形态 | 开源 | 定价 | Claude Code 集成 | 活跃度 | 分级 | 可实测性 |
|------|----|------|---------|------|------|------------------|--------|------|---------|
| **claude.ai/code web** | b 官方 | 云端 Claude Code：长任务/多任务并行 + Routines 云定时 + Remote Control 接管本机会话 | 云 SaaS | ✗ | 随 Pro/Max 订阅（$20/$100 档，D 级：定价页 JS） | 原生（就是 Claude Code 的云面） | 官方持续 | **C** | ✅（已有订阅，dev-4 实测） |
| **Conductor** | a 管理器 | Mac app：并行 Claude Code/Codex/Cursor 隔离工作区，审查合并 | 本地 Mac app（Pro 含云工作区） | ✗（闭源） | Free $0 / Pro $50/mo / Teams $60/mo/user（**C** 级 pricing 页原文） | 原生 spawn 隔离工作区 agent | v0.84.2（C 级官网） | **C** | ✅（Free 档可注册实测） |
| **Vibe Kanban** | a 管理器 | 看板式 issue→agent 工作区编排，diff 审查 | 本地 `npx vibe-kanban` + 团队云版 + Docker self-host 指南 | ✓ Apache-2.0（28.0k★） | 免费开源 + 云版另计 | 原生（支持列表含 Claude；issue 状态自动流转） | **⚠ sunsetting**（官网横幅"continue as open source and community maintained"；末次 release 2026-04-24，4.5 月无更新，B+C 级） | **B** | ✅（本地可跑） |
| **Nimbalyst**（原 Crystal） | a 管理器 | 可视化工作区：与 agent 共编 markdown/原型/图表，红绿 WYSIWYG diff + 任务看板 + iOS/Android 伴侣 app | 桌面 app（macOS/Win/Linux） | ✓ MIT（1.7k★） | 官网定位 Free（desc 原文"Free, MIT-licensed"） | 原生（Claude Code/Codex/OpenCode 并行 worktrees） | 当日仍在 push（B 级） | **B** | ✅（开源桌面可装） |
| **Claude Squad** | a 管理器 | TUI 多 agent 终端管理 | 本地 CLI（tmux+worktrees） | ✓ AGPL-3.0（8.5k★） | 免费开源 | 原生（管理 Claude Code/Codex/OpenCode/Amp 终端） | 活跃（2026-08-20 push） | **B** | ✅（CLI 可装） |
| **VibeTunnel** | a 管理器 | 浏览器变终端："command your agents on the go" | 本地服务 + 任意浏览器/手机访问 | ✓ MIT（4.7k★） | 免费开源（vt.sh） | 透传（把终端会话暴露到浏览器，agent 无关） | 活跃 | **B** | ✅ |
| **Vibeyard** | a 管理器 | 跨平台桌面 IDE：Claude Code 会话 swarm 网格 + 实时会话检查器 + 看板 + P2P 共享 | 桌面 app | ✓ MIT（1.4k★） | 未披露 | 原生包裹（wrap Claude Code 会话） | 活跃 | **B** | ✅ |
| **c9watch** | a 管理器 | macOS 菜单栏：扫 OS 进程发现全部 Claude Code 会话，Working/Need Attention/Idle 分组；**macOS 原生通知 + token-gated 手机/浏览器 WebSocket 客户端** | 本地 Mac（Rust/Tauri） | ✓ MIT（128★） | 免费开源 | 原生发现（进程扫描+hooks） | 活跃（当日 push） | **B** | ✅ |
| **Claude Code Agent Monitor** | a 管理器 | 自托管实时 dashboard：hooks 采集会话/子代理树/工具时间线 + Kanban 状态板 | 本地自托管 Web（Node+SQLite） | ✓ MIT（984★） | 免费开源 | 原生（经 hooks） | 活跃 | **B** | ✅ |
| **Linear** | c 通用 | 项目/issue 管理 + AI（Asks/Agent/Loops）；**官方远程 MCP**（"Connect natively in Claude"；find/create/update issues） | 云 SaaS | ✗ | $0 Free / Basic / Business $16（pricing 页 JS 渲染受限 → D 级） | MCP（Claude Code `claude mcp add` 即接） | 活跃（HTTP 200 实测） | **C** | ✅（Free 档+MCP 实测） |
| **open-sunsama** | c 通用 | "AI-native 开源任务管理器"：MCP server for Claude/Cursor + REST API + 时间块 + 看板，Sunsama 自托管替代 | 本地自托管 | ✓（51★，license NOASSERTION 待核） | 免费开源 | MCP | 活跃 | **B** | ✅ |
| ~~Height~~ | c 通用 | （对照项）AI 原生项目管理 | 云 | ✗ | — | — | **关停中**（HTTP 000 + 生态工具"Height.app is shutting down"佐证）→ 移出推荐池 | **D** | ✗ |
| ~~Terminate~~ | a 管理器 | 种子名单项 | — | — | — | — | 域名售卖页（$12,988 GoDaddy）→ 已死/名字失效，核验在案 | **D** | ✗ |

**中文生态**：中文关键词轮（GitHub 内"claude code 任务管理"/"agent 看板"）仅发现 dpp814/agent-dashboard（1★，本地看板+浏览器处理 Claude/Grok 授权，MIT，2026-08-21 活跃）——无成规模中文生态独立产品，**结论：英文生态主导**（README 语言抽样佐证）。

## 三类扫描的检索渠道清单（穷尽性声明）

- **a 类（管理器）**：gh search（"claude code"/"vibe-kanban"/"claude-squad"/"agent orchestration terminal" 等 8 组关键词）+ 反查互链（awesome-claude-code README 全文扫描：Nimbalyst/Vibeyard/c9watch/Agent-Monitor/Sidekick 均由此发现）+ 官网核验（conductor.build/vibekanban.com/nimbalyst.com）
- **b 类（官方）**：code.claude.com/docs（ch1 已引六页）+ claude.ai/code web
- **c 类（通用）**：linear.app/docs/mcp（HTTP 200 实测+引文）/ height.app（实测关停）/ gh search "task manager MCP"（发现 open-sunsama 等 6 个 MCP 任务管理器，取星数最高者）
- **失效渠道**：WebSearch 当日异常（多轮空返回），全程降级 gh+WebFetch+curl——检索面因此偏 GitHub 生态，纯官网不进 GitHub 的 SaaS 可能漏检（如更多 c 类平台）；此为已知盲区，已在 ch4 建议敏感性中标注
- **中文轮**：已执行（见上），结论"英文生态主导"

**穷尽性结论**：≥8 家目标达成（12 家入表），三类各有 6/1/2 家，种子全进池（Vibe Kanban ✓/Conductor ✓/Crystal→Nimbalyst ✓/Claude Squad ✓/Terminate→已死核验 ✓/claude.ai web ✓）。已知盲区：WebSearch 失效导致的"无 GitHub 仓库的纯 SaaS"覆盖不足；HN/Reddit 渠道因同一故障未覆盖——口碑面留待 ch4 若有疑点再补。

## 死链与口碑项标注
- Terminate：种子名指向域名售卖页——**非死链而是产品已死**（D 级判定，核验过程在案）
- Height：HTTP 000 不可达 + 第三方工具自述"shutting down"——判关停（D 级，未获官方公告原文）
- Linear 定价 $10/$16 档：JS 渲染受限，价格数字为 D 级（Free 档存在为 C 级确认）
- Vibe Kanban sunsetting：官网横幅原文（C 级）+ 末次 release 时间（B 级 api）双源
- 其余各家均有可核查来源（repo 或官网，见 evidence/ch3/search-log.md）

## ch4 实测名单预选（按"推荐相关幸存者"）
1. **claude.ai/code web**（官方云端基准，7b-同步原生候选）
2. **Conductor**（Free 档闭源 Mac app，商业形态代表）
3. **Vibe Kanban**（开源可本地跑，但 sunsetting 风险需实测确认现状）
4. **Claude Squad**（TUI 开源代表）
5. **c9watch**（小而美：手机 WebSocket 监控 + 需注意仅 macOS）
6. **Nimbalyst**（Crystal 后继，含移动伴侣 app）
7. **Linear + MCP**（c 类集成形态代表，Free 档）
（survey 绑定修正条款：此名单随本章结论自适应，dev-4 开工上报时注明与本章的对应关系——上表"可实测性"列即依据）

## 本章结论
1. a 类管理器生态**拥挤且活跃**（6 家全开源、5 家千星级），但**全部聚焦"开发者本机的并行会话管理"**，无一家是 goal 意义上的"在线任务平台"（跨设备任务清单+确认队列）——与 ch2 的判断互证：这块空白是真实的。
2. "手机可用"光谱：c9watch（WebSocket 手机监控+通知）> Nimbalyst（iOS/Android 伴侣）> Conductor（Pro 才有 mobile coming soon）> 其余本机。7b-同步的第三方候选以 c9watch/Nimbalyst 最值得 dev-4 实测。
3. c 类通用平台走 MCP 集成路线（Linear 官方 MCP 可直连 Claude），但"待办平台"与"agent 会话"是两个世界，goal 三需求中 7b/7c 基本指望不上 c 类。
4. **两个种子已死**（Terminate 域名售卖、Height 关停）——快照时点敏感性高，ch4 评分将显式标注"2026-09 时点"。
