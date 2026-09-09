# ch1 · 现状盘点：Claude Code 任务管理能力基线（Q1/Q2）

> 术语约定：**"用户级"= 跨项目跨会话的个人任务层**（对应 `~/.claude/` 用户级配置语义），与会话级 TodoWrite 形成层级对比。scope 裁决口径。
> 验证时点：2026-09-09，Claude Code **2.1.259**（`claude --version` 实测，evidence/ch1/probe-log.md P1）。
> 证据分级：A=一手实测（命令输出/探针，可重放）/ B=源码定位（文件:行号）/ C=官方文档（链接+引文）/ D=二手转述 / E=推测（显式标"假设"）。

## 1. 能力矩阵（Q1）

生命周期五环节定义：**创建**（登记待办）→ **提醒**（到点/条件触发唤醒）→ **确认**（agent 阻塞等用户输入）→ **进度**（查看进行到哪）→ **核销**（标记完成/归档）。

| # | 能力 | 级别 | 持久性 | 触发/查看 | 创建 | 提醒 | 确认 | 进度 | 核销 | 主证据 |
|---|------|------|--------|-----------|------|------|------|------|------|--------|
| 1 | TodoWrite（会话 todo 工具） | 会话级 | 会话目录持久（`~/.claude/tasks/<sessionId>/`，进程退出不删、resume 沿用） | 模型自主调用；UI 渲染 | ✅ | ❌ | ❌ | △(单会话内) | ✅ | **A**（探针 P8：924 个任务 json / 261 会话目录；TodoWrite input schema `[content,Active-Form,status]`） |
| 2 | 后台会话 `--bg` + Agent View（`claude agents`） | 用户级（跨目录聚合所有运行中/后台会话） | 进程存活期 | `claude agents` TUI；peek(Space) 看最近输出+回复；attach(Enter) 接管 | ✅(prompt 即任务) | △(Needs input 置顶黄标) | ✅(peek 回复/编号选项/`!`命令) | ✅(Haiku 15s 摘要行、状态分组) | ✅(Completed/Failed 终态) | **A**（探针 P4：本机 9 会话列表实测）+ **C**（agent-view 文档引文） |
| 3 | Remote Control（`claude remote-control` / `--rc` / `/rc`） | 用户级（手机/浏览器接管本机会话） | 会话存活期（server 停后 4h 可拉回） | claude.ai/code、iOS/Android App、QR | ✅(手机发消息即任务) | △(长回合 Still working 通知) | ✅(**手机批准权限提示**/发消息驱动运行中会话) | ✅(同步 diff/subagent 进度) | △(会话归档) | **C**（remote-control 文档引文，判定门槛已满足"文档原文"级） |
| 4 | Dispatch（Cowork 手机下发） | 用户级（cloud 侧持久对话） | 持久对话 | 手机 Claude App → Cowork | ✅(手机消息 Dispatch) | ✅(**推送通知**：完成/需审批) | △(推送→回 App 审批；Code 会话审批 30min 过期) | △(App 内查看) | △ | **C**（desktop 文档 §Sessions from Dispatch 引文） |
| 5 | `/resume` 会话恢复（`--continue`/`--resume <id|name>`/`/from-pr`） | 用户级（跨项目查找恢复） | transcript 本地持久（30 天清理期） | CLI/picker；可按名直达 | ✅ | ❌ | △(恢复后继续答) | △(picker 显示摘要/分支/大小) | △ | **A**（`claude --help` 实测）+ **C**（sessions 文档引文） |
| 6 | `/goal` 完成条件 | 会话级 | **resume 持久**（active goal 跨 resume 恢复，计数重置） | `/goal <条件>`；状态 `/goal` | ✅ | ✅(idle check-in 最多 3 次) | ❌(条件内自定) | ✅(状态视图：运行时长/轮数/token) | ✅(Met/Impossible 自动清除) | **C**（goal 文档引文） |
| 7 | `/loop` + CronCreate（会话内定时） | 会话级 | resume 恢复未过期项；**7 天硬过期** | `/loop 5m <prompt>`；CronList | ✅ | ✅(cron 触发新 turn) | ❌ | △(任务列表可见) | ✅(CronDelete/自停) | **A**（本会话 deferred tools 列表实测含 CronCreate/CronDelete/CronList/ScheduleWakeup）+ **C** |
| 8 | Routines（云定时） | 用户级（云端，机器关机也跑） | 持久 | `/schedule` CLI 创建；web/Desktop 管理 | ✅ | ✅ | ❌(autonomous) | △(web 查看) | △ | **C**（overview/scheduled-tasks 文档） |
| 9 | Desktop scheduled tasks（本机定时，无需开 session） | 用户级（本机） | 持久 | Desktop App 设置 | ✅ | ✅ | △(configurable per task) | △ | △ | **C**（scheduled-tasks 对比表） |
| 10 | hooks 事件体系（SessionStart/Stop/StopFailure/Notification…33 事件） | 用户级安装（`~/.claude/settings.json` 用户级 hook 全项目生效） | 配置持久 | 事件驱动；TaskCreated/TaskCompleted 事件在列 | △(脚本可写任务文件) | ✅(SessionStart 注入/Notification 推) | △(PermissionRequest hook) | △(hook 写状态文件) | △ | **A**（本机 settings.json 实测 5 事件已装 claude-supervisor hooks）+ **B**（DESIGN.md §2.3 逆向事件表） |
| 11 | skills/commands（`~/.claude/skills/`、`~/.claude/commands/`） | 用户级 | 文件持久 | `/skill-name` 或模型自调 | ✅ | △(loop.md 用户级定制) | ❌ | ❌ | ❌ | **A**（本机 `~/.claude/commands/` 实测 4 命令装在用户级） |
| 12 | CLAUDE.md / Auto memory | 用户级（`~/.claude/CLAUDE.md`）+ 项目级（`projects/<p>/memory/`） | 文件持久（memory 免清理） | 每会话启动载入（memory 首 200 行/25KB） | ✅(写文件) | △(每次启动可见) | ❌ | ❌ | ❌ | **A**（本机 `~/.claude/CLAUDE.md` 存在实测）+ **C**（memory 文档引文） |
| 13 | MCP（外部工具接入） | 用户级（`claude mcp add --scope user`） | 配置持久 | 模型调用 tool | △ | △ | △ | △ | △ | **C**（overview/MCP 文档；机制开放故全 △ 可编程） |
| 14 | 跨会话消息（ListAgents/SendMessage + UDS） | 用户级（本机所有运行中会话） | 进程存活期 | 会话间点对点 | ✅ | △ | ✅(消息直达等待中的会话) | △(receiver 自报) | ❌ | **A**（本会话即靠此与 supervisor 通信运行中）+ **B**（DESIGN.md §2.2） |
| 15 | history.jsonl（用户输入历史） | 用户级 | 3090 行跨全部项目 | `~/.claude/history.jsonl`（非 UI） | ✅ | ❌ | ❌ | ❌ | ❌ | **A**（探针 P9） |
| 16 | web 版 claude.ai/code 会话 | 云端 | 持久（云 session list） | 浏览器/手机 App | ✅ | △ | ✅(云会话内) | ✅(App 查看) | △ | **C**（overview/web 文档） |

**注**：矩阵 2/3/4/5 的"确认"能力构成 7b-同步判定的本地基座（scope 必改 2 要求覆盖的 resume/continue 与 web 接管面）。

## 2. 官方已覆盖 vs 空白（Q1 收口）

**官方已覆盖环节**：
- 单会话内任务跟踪（TodoWrite + /goal + /loop）——创建/进度/核销全有
- 多会话聚合视图（Agent View：状态分组、Haiku 摘要、peek 回复、Needs input 置顶）
- 移动端接管（Remote Control：手机批准权限/发消息驱动本机运行中会话；Dispatch：推送通知+手机下发任务）
- 定时与保活（/loop、Routines 云定时、Desktop scheduled、/goal 条件保活、Stop hook）
- 恢复（--resume/--continue 跨项目、goal 跨 resume、未过期 cron 任务跨 resume）

**空白环节**（逐条指向矩阵空格）：
- **跨会话待办聚合视图：空**。TodoWrite 数据在 `~/.claude/tasks/` 分会话目录持久（A 级实测 924 条），但无任何官方 UI/命令把"我所有会话的 pending/in_progress"聚合展示；`~/.claude/tasks` 的 82 条 pending + 12 条 in_progress（A 级统计）对用户不可见。矩阵第 1 行与第 2 行之间的鸿沟：TodoWrite 持久但不跨会话聚合，Agent View 聚合但只覆盖存活进程会话。
- **用户级"提醒"闭环：半空**。定时能力全是"会话内 cron（7 天过期）/云 Routines/Desktop 定时"，没有一个能"跨会话存在、到点唤醒**某个** Claude 会话来跟进我的待办"。Routines 最接近但跑在云且 autonomous（无确认交互）。
- **任务→会话的关联模型：空**。任务是任务（tasks/ 目录）、会话是会话（transcripts），没有"这个待办属于哪个会话/在哪个会话里继续"的链接结构；`--from-pr` 有 PR→会话关联先例（C 级），但无 todo→会话。
- **待确认点的跨设备队列：半空**。Remote Control/Dispatch 覆盖"会话正活着时"的手机确认；但会话死了/用户离开几小时，"待确认点"没有持久队列形态（本仓库 supervisor 的 QUESTIONS 机制正是补此缺的本地异步实现——D 级：本仓库 README/DESIGN.md）。

## 3. 缺口场景（Q2，按痛点排序）

**场景 G1：跨会话待办黑洞（痛点最高）**。
用户一周开 20 个 Claude 会话（探针实测本机 9 个并行、tasks/ 有 261 个会话目录），TodoWrite 在每个会话里记的 pending 待办（全机 82 条 pending）散落在各会话目录里。矩阵空格：第 1 行 ×「用户级聚合」列；第 2 行（Agent View）只聚合运行中会话，已退出会话的待办即失明。用户想看"我还有哪些事没做完"，只能逐会话 resume 翻——这正是 goal 原文"用户级任务管理器"要的第一能力。

**场景 G2：待确认点无人值守时积压（痛点次高）**。
agent 在会话里等确认（77541 会话实测 `waitingFor: "input needed"` 挂了数小时，A 级），用户不在终端前。Remote Control 需会话当初显式开启（`/rc`）且要求用户主动查看；没有"所有会话的未决问题聚合成队列，手机上统一回复，答案异步送达并消费"的机制。矩阵空格：第 3/4 行 ×「离线异步队列」列。本地异步形态已有活样本（本仓库 supervisor QUESTIONS 机制）但无官方形态。

**场景 G3：任务生命周期跨会话断裂（结构性）**。
goal 原文三需求"在线维护待办、回复待确认点、查看任务进度"里的"任务"在 Claude Code 里没有一等公民对象：/goal 随会话走（resume 恢复但新会话不继承）、cron 任务 7 天过期、TodoWrite 绑死会话、Routines 是云上的另一套。没有"同一个任务，从创建到核销，中间换过 N 个会话/设备"的连续性支撑。矩阵空格：任何一行都没有「任务级持久身份」列。

## 4. ch1 结论

1. Claude Code 官方能力覆盖了任务生命周期的**会话内**与**会话存活期**两端（TodoWrite/Agent View/Remote Control/Dispatch），但**用户级跨会话层是空白**：待办数据持久存在（A 级：tasks/ 目录）却无聚合视图；确认能力依赖会话活着；任务无跨会话身份。
2. "给 Claude Code 加用户级任务管理器"的缺口是真实且结构性的——不是缺某个功能开关，而是缺一个层级：**用户级任务层**（数据结构 + 聚合视图 + 跨设备队列 + 任务↔会话关联）。
3. 恢复基座充足：resume 跨项目可用（C 级）、goal/cron 跨 resume 恢复（C 级）、tasks/ 数据全会话持久（A 级）——自研路线（ch2）的地基比预期好。

**置信度：高（0.9）**。核心论据均为 A 级（本机探针）或 C 级（官方文档原文引文，已固化 evidence/ch1/official-docs-quotes.md）。主要不确定性：`~/.claude/tasks/` 的 UUID 目录命名在 9/7 前后切换为 `session-<8位>`（A 级实测两形态并存），说明官方在活跃迭代此存储——设计上不应依赖其内部格式（官方文档明示 transcript 内部格式版本间会变，C 级同理推及）。

## 证据清单
- evidence/ch1/probe-log.md（A 级：P1-P9 探针全记录，含可重放命令）
- evidence/ch1/official-docs-quotes.md（C 级：remote-control/agent-view/desktop/memory/goal/sessions/scheduled-tasks 六页引文）
- DESIGN.md §2（B 级：2.1.259 二进制逆向，事件表/会话注册表/UDS 消息）
