# Claude Code 用户级任务管理器 vs AI task 在线管理平台 —— 调研报告

> 2026-09-09 ｜ Claude Code 2.1.259 ｜ research 模式产出（调研，非实施）
> scope：①如何给 Claude Code 加用户级任务管理器；②AI task online 平台选型（在线维护待办/回复待确认点/查看进度）。
> "用户级" = 跨项目跨会话的个人任务层（~/.claude 语义），非团队级。

## TL;DR（三句话答案）

1. **加任务管理器**：推荐"自有 schema 文件 + SessionStart hook 注入 + /todo skill"起步（半天），演进到 MCP server 数据面——官方已有会话内与会话存活期两端的完整覆盖，唯独缺"用户级跨会话层"，而这层数据其实已经存在（本机实测 82 条 pending 待办散落 261 个会话目录，无任何官方入口可见）。
2. **平台选型**：claude.ai/code web + Remote Control 是 7b"手机回复确认点、运行中会话立即继续"的**唯一满足者**（文档原文级）；第三方管理器赛道拥挤（12 家入表）但全聚焦本机并行会话，无跨设备在线任务平台。
3. **最终决策：组合**——官方平台（已有订阅，管会话中心视角）+ c9watch（本地聚合监控，可选）+ 轻量自研层（管跨会话个人待办，平台都不管的那块）。不自建平台、不单靠平台。

## 报告导航

| 章 | 文件 | 回答什么 |
|----|------|---------|
| ch1 基线 | ch1-baseline.md | Q1/Q2：官方 16 项能力矩阵、已覆盖/空白、3 个缺口场景 |
| ch2 路线 | ch2-routes.md | Q3/Q4/Q5：四条自研路线、与 claude-supervisor 融合判断、A+B 起步推荐 |
| ch3 全景 | ch3-platforms.md | Q6：12 家平台全景（含 2 家种子死亡核验、Vibe Kanban sunsetting） |
| ch4 评测 | ch4-evaluation.md | Q7/Q8：平台×4 需求矩阵、评分表、Top3+组合方案 |
| 证据 | evidence/ | 四章全部探针/引文/检索日志（A/B/C/D 分级标注） |

## 决策建议展开

### 如果只做一件事
开 Remote Control：`claude remote-control` 或会话内 `/rc`，配 `remoteControlAtStartup: true`（用户 settings.json）。goal 的"回复待确认点"立刻有解（手机批准权限/回复，本机运行中会话继续），零新成本。

### 如果愿意投入半天
自研层 v1（ch2 路线 A）：`~/.claude/user-todos.json`（自有 schema）+ SessionStart hook 注入提醒 + `/todo` skill。每个新会话启动即见"你有 N 条用户级待办"——G1（跨会话待办黑洞）闭环。hook 机制已有 A 级探针验证（evidence/ch2/probe1，含真实集成陷阱记录：additionalContext 必须 json.dumps）。

### 如果确认点高频/要正式化
自研层 v2（ch2 路线 B）：MCP server 数据面（探针骨架 50 行已验证），全局任务 id + 确认队列；远期与 claude-supervisor 账本体系融合（ch2 Q4 融合判断：互补非重叠，可复用六件套）。

### 平台侧不建议
- Vibe Kanban：功能最全的开源看板但 **sunsetting**（社区维护，末版 2026-04-24）
- Conductor：$50/mo 才有移动端，Free 档价值有限
- Linear+MCP：专业 PM 强但 7b 零分——与 Claude Code 是两个世界（数据集成非会话接管）
- 已死勿念：Terminate（域名售卖）、Height（关停中）

## 重要限制（引用必读）

- **时点敏感**：2026-09-09 快照。本期调研当场核验死亡 2 家（Terminate/Height）+ 半死 1 家（Vibe Kanban）——此领域月度级淘汰，引用本报告请核对最新状态。
- **WebSearch 双会话故障**：口碑面（HN/Reddit）缺失，所有判定基于 A/B/C 级硬证据（探针/repo/官网），无口碑加成。
- 7b-同步对 claude.ai web 的"满足"判定 = C 级文档原文（"Approve tool calls from your phone"）+ 本机基础设施 A 级在场；未做手机端到端复演（门槛二选一满足即判，已在 ch4 披露）。
- 每章上报均经 Supervisor 抽查复现（A-C 级关键证据）与结论对账；本报告 trailer 链：`worker: research-worker-r1, phase: dev-1..4`。
