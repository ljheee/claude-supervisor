# ch2 · 自研技术路线：给 Claude Code 加用户级任务管理器（Q3/Q4/Q5）

> 承接 ch1：G1 跨会话待办黑洞（全机 82 pending 不可见）/ G2 待确认点无人值守积压 / G3 任务无跨会话身份。
> 硬约束（ch1 结论带回）：**持久层自带 schema，不得寄生官方未稳定存储**（tasks/ 目录 UUID→session- 双命名变更是 A 级前车之鉴）。
> 证据分级：A=探针实测 / B=本仓库源码定位 / C=官方文档 / E=推测（显式标注）。

## 0. 路线设计空间（三维正交）

- **持久层**：自定义用户级文件（如 `~/.claude/user-todos.json`）｜ MCP server 数据面 ｜ 与 claude-supervisor 融合的 ledger
- **交互面**：SessionStart hook 注入 ｜ skill/command ｜ CLAUDE.md/rules ｜ statusline ｜ 跨会话消息（SendMessage）
- **提醒机制**：会话内 cron（7 天限）｜ Desktop scheduled tasks（无需开 session）｜ 外部 watchdog cron ｜ 云 Routines

四条路线 = 三维的不同组合，不是四个孤立方案。

## 路线 A：纯文件 + hook 注入 + skill 管理（本地轻量）

**架构**：`~/.claude/user-todos.json`（自带 schema：id/subject/status/created/session_ref/confirmations）+ SessionStart hook 启动注入提醒 + `/todo` skill 管理增删改查 + Notification hook 完成回写。

| 组件 | 机制 | 扩展点证据 |
|------|------|-----------|
| 持久层 | 用户级 JSON 文件，官方不触碰的自有 schema | **A**（探针1：文件读写通；约束满足"不寄生官方存储"） |
| 提醒 | SessionStart hook → additionalContext 注入 | **A**（探针1 v2：注入链路实测通，含真实集成成本记录——手拼 JSON 裸换行陷阱） |
| 管理 | `/todo` skill（~/.claude/skills/todo/SKILL.md） | **A**（探针4：本机已有两个用户级 skill 活样本） |
| 进度 | 每会话启动时看注入的 pending 列表 | 同上 |
| 确认 | 无专门机制（依赖会话内交互） | — |

- **覆盖缺口**：G1 ✅（82 pending 聚合可见+每会话提醒）；G2 ❌；G3 △（session_ref 字段可记来源会话，但无消费方）
- **优点**：零依赖、半小时可落地、格式自控、随 git/备份走
- **缺点**：单向提醒（只在会话启动时注入，长会话中途新待办不触发）；无跨设备；确认点无队列

## 路线 B：MCP server 中心化（数据+工具面统一）

**架构**：一个 stdio MCP server（如 user-todo-mcp）持有 SQLite/JSON 数据，暴露 `list_todos/create_todo/complete_todo/queue_confirmation/reply_confirmation` 工具，`claude mcp add --scope user` 注册后**所有项目的所有会话**共享同一数据面。

| 组件 | 机制 | 扩展点证据 |
|------|------|-----------|
| 持久层+管理 | MCP tools（跨项目全局可达） | **A**（探针3：initialize/tools/list/tools/call 三请求骨架实测通）+ **C**（官方 MCP 文档：user scope 全项目生效） |
| 确认 | `queue_confirmation` 工具写入待确认队列 + `reply_confirmation` 消费 | **A**（同探针3 骨架可承载；语义为自定义协议） |
| 提醒 | MCP 无事件推送——仍需路线 A 的 hook 或外部定时 | **C**（MCP 为拉模型） |
| 进度 | 任意会话调 list_todos | 同上 |

- **覆盖缺口**：G1 ✅；G2 △（队列有了，但消费仍需会话主动来拉——除非加 hook/定时）；G3 ✅（server 侧任务带全局 id，天然跨会话身份）
- **优点**：数据面一等公民、跨项目、工具语义清晰、可加鉴权/同步
- **缺点**：需常驻进程或按需拉起；提醒仍缺推送通道；纯 MCP 无 UI（要配 ch4 平台才补齐"在线"面）

## 路线 C：与 claude-supervisor 融合（ledger 复用）

**架构**：把用户级任务层做进本仓库体系——`.supervisor/` 账本模式推广为 `~/.agent-mail/` 全局 ledger，Supervisor 会话成为"任务监工"：用户级待办由它督促（cron 巡检已内建）、待确认点走 QUESTIONS 协议（异步队列已有）、跨会话身份用 session_id 主键体系。

| 组件 | 机制 | 扩展点证据 |
|------|------|-----------|
| 持久层 | 全局 ledger（分片目录+原子写纪律） | **B**（DESIGN.md:100,176 单写者原子写；`~/.agent-mail/registry.py` 已是全局注册表实现） |
| 确认 | QUESTIONS 协议（分级打包→监工分流→回传） | **B**（worker.md QUESTIONS 格式；本调研即活运行样本） |
| 提醒 | watchdog cron + 巡检 + ScheduleWakeup | **B**（DESIGN.md:230-234 告警去重梯度；DESIGN.md:157 巡检唤醒链） |
| 进度 | supervisor 终端即聚合视图（STATUS CHECK 机制） | **B**（本仓库协议全链） |
| 中断防御 | StopFailure/stop-anomaly 已内建 | **B**（DESIGN.md §5；用户级任务层白捡的中断恢复） |

- **覆盖缺口**：G1 ✅；G2 ✅（QUESTIONS 就是异步确认队列的本地实现，ch1 已认定）；G3 ✅（session_id 主键+分片账本）
- **优点**：复用度最高、三缺口全覆盖、有中断防御与唤醒链、已有三模式框架可加第四模式 `/tasks`
- **缺点**：绑定单 supervisor 会话在线（它死了需 watchdog 兜底，DESIGN.md:128 进程死亡原理性无解）；无跨设备面；改造成本高（协议层扩展，需走 spec 流程）；单人单机场景重

## 路线 D：Desktop scheduled tasks + statusline（官方能力拼装）

**架构**：不开自己的常驻层，Desktop scheduled task（无需开 session、持久、可配权限提示）定时跑"巡检用户级 todo 文件并产出摘要/通知"，statusline 实时显示 pending 数。

| 组件 | 机制 | 扩展点证据 |
|------|------|-----------|
| 提醒 | Desktop scheduled tasks（本机、持久、无需会话） | **C**（scheduled-tasks 对比表：Requires open session=No、Persistent=Yes、最小间隔 1min） |
| 进度 | statusline 显示（如 "⧗ 3 pending"） | **C**（statusline 文档：可读 git/context/成本，自定义脚本） |
| 持久层 | 仍是自有文件 | **A**（同路线 A） |
| 确认 | 无 | — |

- **覆盖缺口**：G1 ✅（定时巡检+常驻可见）；G2 ❌；G3 ❌
- **优点**：全部官方机制、无自研常驻、升级跟随官方
- **缺点**：Desktop App 依赖（无头服务器场景失效）；确认与身份两缺口裸奔；拼装件间无一致性保证

## Q4 融合判断：路线 C 与 claude-supervisor 的关系

**结论：互补 + 可演进，非重叠。**

- **互补**：supervisor 管"会话间协作流程"（谁监工谁干活），用户级任务层管"跨会话个人待办"（我有什么事没做完）。前者是组织层，后者是清单层；QUESTIONS/registry/分片账本三者可复用为清单层地基，但清单层不依赖 supervisor 存活才有意义（用户不开 supervisor 也要看待办）。
- **可复用清单**（改动即可用）：`~/.agent-mail/registry.py` 全局注册表写接口；分片目录+单写者原子写纪律（DESIGN.md:100）；QUESTIONS 异步确认协议；watchdog 告警去重（DESIGN.md:230）；StopFailure/stop-anomaly 中断上报（DESIGN.md §5，用户级任务层白捡）；安装期拼接的分发模式（install.sh + commands/，路线扩展可沿此安装）。
- **不受影响清单**：三模式状态机（scope→survey→dev-N 等为会话内流程，与用户级清单正交）；`.supervisor/` 项目级账本语义（保持 worker 只读不变）；hooks 注册面（SessionStart 身份注入器职责单一，不动）。
- **重叠风险点**：若用户级任务层做成第四模式 `/tasks`，其"任务"概念与 supervisor 的 phase/milestone 术语需显式区分（清单项 ≠ 里程碑）——E 级假设：命名上用 todo/task-item 区分即可避免混淆，实施 spec 时定案。

## Q5 推荐路线

**推荐：A+B 组合起步，C 作为演进方向。**

1. **第一步（路线 A，半天）**：自有 schema 文件 + SessionStart hook 注入 + /todo skill。G1 立即闭环——每个新会话看到"你有 82 条用户级 pending"（数字即来自 ch1 A 级实测，回链 G1）。探针1 已验证全链路成本：一个 40 行脚本（含 JSON 转义陷阱的修复记录）。
2. **第二步（路线 B，2-3 天）**：MCP server 承载数据面（探针3 骨架 50 行已通），G3 闭环（全局任务 id）；hook 保留为"推送面"（启动注入），MCP 做"工具面"（任意会话增删查）。两者共享同一存储。
3. **远期（路线 C 演进）**：确认队列需求变大（G2 高频化）时，把数据面交给 supervisor ledger 体系，白捡中断防御与唤醒链；短期内 G2 用 Remote Control（手机批准权限，ch1 矩阵第 3 行 C 级达标）兜底。

**依据链**：①G1 是最高痛点（ch1 排序），A 的性价比最高（探针1 成本实测）；②G3 需要全局身份，纯文件方案演进不到，B 的 MCP 数据面是自然下一步（探针3 已验证骨架）；③G2 已有官方兜底（Remote Control）+ 本仓库 QUESTIONS 活样本，不需要第一步就上重武器；④C 的完整价值（中断防御/巡检）依赖 supervisor 在线，作为常驻演进而非起步。

**置信度：0.85**。A/B 两步的机制均有 A 级探针；C 的复用面为 B 级源码定位（本仓库）；主要不确定性在"用户实际使用强度"——若确认点高频，B→C 的演进提前。

**敏感性**：
- 若官方后续版本推出原生跨会话 todo 聚合（tasks/ 命名活跃迭代是信号，ch1），路线 A/B 的 hook+MCP 层可整体退役，只损失过渡期投入——选 A 起步正是为把沉没成本压到最小。
- 若用户主要在手机上管理任务（移动优先），本推荐失效，应直接跳 ch4 平台选型（"在线"三需求都在平台上）。
- 若单机多 supervisor 场景普及（v3 多 supervisor 已是本仓库方向），C 的账本并发语义需重审，演进成本上升。

## 证据清单
- evidence/ch2/probe-log.md（A 级四探针总记录）
- evidence/ch2/probe1-sessionstart-hook.sh + probe1-output.txt（A 级：hook 注入全链路，v1 裸换行 bug 发现与 v2 修复）
- evidence/ch2/probe3-mcp-server-skeleton.py + probe3-output.jsonl（A 级：MCP stdio 三请求）
- B 级：install.sh:168-169,33-35；DESIGN.md:100,128,157,176,230-234
- C 级：ch1/official-docs-quotes.md（scheduled-tasks 对比表/MCP/statusline）
