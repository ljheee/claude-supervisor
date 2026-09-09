# ch4 · 平台评测与选型（Q7/Q8）

> 时点 2026-09-09（ch3 双种子死亡的教训：本章所有判定带时点前提）。
> 7b 判定门槛（最高纪律）：判"满足"必须 A 级完整流程实测 或 官方文档原文（C 级）显式表述；二缺一降"部分/不满足"+ D 级说明。
> 渠道状态：WebSearch 当日双方（worker+supervisor）故障——口碑面缺失，HN/Reddit 盲区维持 ch3 声明；本判定不依赖口碑。

## 1. 平台 × 4 列需求矩阵（Q7）

### 1.1 7a 在线维护待办（web/移动端增删改查）

| 平台 | 判定 | 机制 | 分级 |
|------|------|------|------|
| claude.ai/code web | **满足** | 云端会话即任务容器：浏览器/手机 App 创建、查看、归档会话；任务列表原生 | **A**（本会话体系即跨设备同步的活证据）+C |
| Vibe Kanban | **满足** | 本地 Web 看板：issue 增删改查、子任务、自动流转（agent 开工/PR 创建/合并时状态更新）| **A**（npx 实测起看板服务，test-log M2）|
| c9watch | 部分 | 只读为主（tasks/status 查询）；待办维护非其功能重心 | **A**（CLI tasks 实测——TodoWrite 快照只读）|
| Claude Squad | 部分 | TUI 内会话管理，非"待办清单"形态 | **B**（README：tmux+worktree 会话管理）|
| Conductor | 部分 | 工作区/agent 并行管理，待办即"派给 agent 的活" | **C**（官网：parallel agents in isolated workspaces）|
| Nimbalyst | 满足 | 官网定位含"track tasks"+任务看板 | **C**（repo desc：session/task kanban）|
| Linear | **满足** | 专业 issue 管理平台，web+移动 App 原生 | **C**（linear.app）+ 用户已订阅前提 |

### 1.2 7b-同步：agent 阻塞时从 web/手机回复，同一运行中会话立即继续

| 平台 | 判定 | 机制 | 分级 |
|------|------|------|------|
| claude.ai/code web（Remote Control） | **满足** | 手机/浏览器接管本机运行中会话；"Approve tool calls from your phone"（重复权限提示时弹通知）；断网排队重连 | **C**（文档原文，ch1 固化）+ **A-**（本机 Remote Control 基础设施实测在场：`claude --help` 实测 `--teleport`/remote-control 入口；注：未做手机端到端复演，按门槛 C 级文档原文+机制本机在场判满足） |
| c9watch | 部分 | needsPermission 抓"哪个会话在等什么"（A 级实测抓到 AskUserQuestion/Bash 挂起）+ 原生 macOS 通知 + 手机/浏览器 WebSocket 监控；**但手机端只能看，回复路径未实测、README 未明示手机可回复** | **A**（status needsPermission 实测）+ **B**（README 手机客户端原文未含"回复"表述）|
| Conductor | 部分 | Mac app 内审查/合并即"确认"；手机 remote 是 Pro 计划 coming soon | **C**（pricing 页：mobile app "coming very soon"）|
| Nimbalyst | 部分 | iOS/Android 伴侣 app——但"伴侣"能做什么未在抓取面内获得明确文档表述 | **D**（移动 app 存在 B 级（repo desc），能力边界未获 C 级文档）|
| Vibe Kanban | 不满足 | 本机浏览器看板；无移动端确认通道 | **A**（实测形态=本地 server）|
| Claude Squad | 不满足 | TUI 本机 | **B** |
| Linear | 不满足 | MCP 是数据集成（读改 issue），不接管 Claude Code 会话 | **C**（MCP 文档：find/create/update issues——无会话通道）|

**7b-同步真正支持的平台子集**：{claude.ai/code web + Remote Control}。其余全部"部分/不满足"。
**最接近的替代机制**（对不满足者）：c9watch 的"通知+监控"半闭环（看见但回复需回到本机）；Conductor 的 app 内确认（非手机）。

### 1.3 7b-异步：回复在线持久化，agent 下次唤醒/resume 时消费

| 平台 | 判定 | 机制 | 分级 |
|------|------|------|------|
| claude.ai/code web | **满足** | 云会话本身：会话死不了（云托管），任意设备发消息，会话继续时消费；本地会话 resume 后 goal/定时任务恢复（C 级）；Remote Control 断网排队语义也是异步缓冲 | **C**（多文档拼合：web 会话/remote-control 排队/resume 恢复）|
| Vibe Kanban | 部分 | issue 评论/状态在线持久（云版），但无"自动送达 agent"通道——agent 不在跑就无人消费 | **B** |
| Linear | 部分 | 同上：issue 持久，Claude 经 MCP 可读——但需要会话主动来拉 | **C** |
| 其余（c9watch/Claude Squad/Conductor/Nimbalyst） | 不满足 | 本机工具，会话死了消息无处消费 | **A/B** |

**7b-异步真正支持的平台子集**：{claude.ai/code web}（且本仓库 supervisor 的 QUESTIONS 机制是本地异步形态的活样本，D 级对照）。

### 1.4 7c 查看任务进度（实时日志/阶段/产物）

| 平台 | 判定 | 机制 | 分级 |
|------|------|------|------|
| claude.ai/code web | **满足** | 会话实时同步（diff 面板/subagent 进度/15s 摘要）| **C**（remote-control 文档原文：diff of your changes/progress of subagents stay in sync）|
| c9watch | **满足** | Working/NeedsAttention/Idle 分组 + tasks 查询 + cost 数据 + watch 流（NDJSON）| **A**（status/tasks 实测）|
| Conductor | 满足 | dashboard 监控各 agent 干什么 + 审查合并 | **C** |
| Vibe Kanban | 满足 | 看板状态自动流转（agent 开工/PR/合并）+ diff 审查 | **A**（机制在 README B 级 + 本地实测服务形态）|
| Nimbalyst | 满足 | 会话/任务看板 + 实时检查器（Vibeyard 同类）| **C** |
| Claude Squad | 满足 | TUI 多会话实时面板 | **B** |
| Linear | 部分 | issue 状态/评论是代理进度，非实时日志 | **C** |

## 2. Q8 参数化评分与推荐

### 2.1 评分维度（默认参数：个人单人/免费优先/移动端加分/SaaS 可接受——用户确认保持默认）

权重：7b-同步 30%（goal 原文"回复待确认点"最稀缺）/ 7a 25% / 7c 20% / 7b-异步 15% / 成本（免费优先）10%。移动端与 SaaS 形态为加分项不加分基。
（敏感性：若权重挪向 7a，Linear 类专业 PM 平台排名升；7b 权重再升则官方组合优势再扩大。）

### 2.2 得分表（0-5 分制）

| 平台 | 7b同步(30%) | 7a(25%) | 7c(20%) | 7b异步(15%) | 免费(10%) | 加权 | 移动端/SaaS 备注 |
|------|------------|---------|---------|------------|----------|------|------------------|
| **claude.ai/code web + Remote Control** | 5 | 4 | 5 | 5 | 5(已订阅) | **4.75** | 移动原生（App）；SaaS ✓ |
| c9watch | 3 | 2 | 5 | 0 | 5 | **2.85** | 手机 WebSocket 监控（只读）；本地 |
| Vibe Kanban | 1 | 5 | 4 | 2 | 5 | **2.85** | 本地 web；⚠ sunsetting |
| Nimbalyst | 2 | 4 | 4 | 0 | 5 | **2.75** | iOS/Android 伴侣（能力边界 D 级）|
| Conductor | 2 | 3 | 4 | 0 | 3(Free档) | **2.45** | 移动 Pro $50/mo coming soon；闭源 |
| Claude Squad | 1 | 2 | 4 | 0 | 5 | **2.15** | 纯 TUI |
| Linear+MCP | 0 | 5 | 2 | 2 | 4(Free档) | **2.30** | 专业 PM 但 7b 零分 |

### 2.3 推荐与组合方案

**Top 1：claude.ai/code web + Remote Control（官方组合）**——7b-同步/异步双满足的唯一平台，且用户已订阅。限制：远程接管需会话以 `/rc` 启动（本机 settings 实测未开 auto-connect）；`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` 等环境变量会禁用它。

**Top 2：c9watch（本地监控层）**——needsPermission 聚合 + 原生通知 + 手机只读监控，免费开源，与官方组合正交互补（官方管"远程接管"，c9watch 管"本机总览+谁在等什么"）。128★ 小项目风险：bus factor 低，但 MIT 可 fork。

**Top 3：Vibe Kanban（备选，带 sunsetting 前提）**——7a/7c 最完整的开源看板，但 sunsetting 后社区维护不确定；若采用需接受"自持 fork"心理预期。

**最终组合方案（对应 goal 三需求）**：
1. **在线维护待办 + 查看进度** → claude.ai/code web（已有订阅，零成本）+ 可选 c9watch 本机聚合
2. **回复待确认点** → Remote Control（手机批准权限/回复，`/rc` 启动习惯化；auto-connect 配置项 `remoteControlAtStartup: true` 一劳永逸）
3. **用户级待办聚合（平台都不管的那块）** → ch2 推荐的 A+B 自研路线（hook 注入+MCP 数据面）填缝——平台们聚焦"会话管理"，没有一家做"跨会话个人待办层"，这正是 G1 空白

### 2.4 决策建议（README 详述）

**三选一答案：组合（自研轻量层 + 官方平台），不自建平台、不单靠平台。**
- 平台已覆盖 7a/7b/7c 的"会话中心"视角（官方 web 全满足）
- 但 goal 的"用户级"三字指向的跨会话任务层无平台覆盖（ch3 结构性发现）
- 自研部分按 ch2 的 A+B 起步（半天+2-3 天），成本可控且不与平台冲突

## 3. 结论对账（逐问核对）

- Q7：矩阵四列全覆盖，7b 双形态各列出真支持子集（同步={官方 web}；异步={官方 web}；均非零，显式给出）✓
- Q8：参数化评分表+权重+敏感性+Top3+组合方案 ✓
- 监工裁决带回：Vibe Kanban 结论带 sunsetting 前提 ✓；Linear 注明已订阅前提 ✓；实测名单与 dev-3 对应关系：7 家全测（含 4 家 A/B 级实测、3 家 C 级安装形态+文档），Conductor/Nimbalyst 未做完整安装实测已显式披露 ✓

## 4. 证据清单
- evidence/ch4/test-log.md（A 级：c9watch 六命令实测/Vibe Kanban npx 启动/本机 Remote Control 基础设施；B 级：brew claude-squad；C 级：Conductor/Nimbalyst/Linear 文档）
- evidence/ch1/official-docs-quotes.md（7b-同步判定的文档原文根基）
- evidence/ch3/search-log.md（候选池元数据+死亡核验）
