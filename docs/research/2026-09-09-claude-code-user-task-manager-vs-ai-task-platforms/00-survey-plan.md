# 00 · 调研方案（survey plan）

> Phase: survey ｜ 对应 scope 清单（3 必改修订版）｜ 生成: 2026-09-09
> 本文件 = dev 阶段执行蓝图。章节、信息源、检索策略、pre-mortem 见下；scope 问题编号可追溯。

## 1. 章节划分 = dev 单元

| 章 | 文件 | 覆盖问题 | DoD（结论+证据形态） | 时间盒 |
|----|------|---------|---------------------|--------|
| dev-1 | ch1-baseline.md | Q1, Q2 | 能力矩阵表（能力×级别/持久性/触发/覆盖环节），每格证据分级+版本号；「官方已覆盖/空白环节」两清单；≥3 个缺口场景（指向矩阵空格+痛点排序） | 90 min |
| dev-2 | ch2-routes.md | Q3, Q4, Q5 | 3-4 条路线（持久层×交互面×生命周期），每组件 B/C 级扩展点证据；≥1 关键机制 A 级探针（脚本+输出落 evidence/）；优缺点对比表；与 claude-supervisor 融合判断（复用/不受影响清单）；推荐+置信度+敏感性 | 90 min |
| dev-3 | ch3-platforms.md | Q6 | ≥8 家候选全景表（定位/部署形态/开源/定价/集成方式+证据分级）；三类扫描各列检索已用渠道；检索穷尽性声明 | 90 min |
| dev-4 | ch4-evaluation.md | Q7, Q8 | 平台×4列矩阵（7a/7b-同步/7b-异步/7c，各列独立判定+机制+分级）；7b 两形态支持子集显式化（QUESTIONS 机制作异步基线锚）；Q8 参数化评分表（默认参数：单人/免费优先/移动端加分/SaaS 可接受——用户已确认保持默认）；Top2-3 推荐+组合方案；README.md(TL;DR+导航+决策建议) 同章交付 | 90 min |

**ch3/ch4 拆分结论**（scope REFINE 时承诺的评估）：**拆**。理由：Q6 是"发现"工作（检索广度优先，产出候选池），Q7/Q8 是"评测"工作（实测深度优先，产出判定矩阵）；证据形态不同（Q6 重 C/D 级网络证据，Q7 重 A 级实测）、失败模式不同（Q6 死于漏检，Q7 死于误判）、时间盒各 90 min 才装得下。合并会让单章同时背两种风险。

## 2. 信息源清单（按章）

**dev-1 ch1（本地为主）**：
- A 级：本地探针——`claude --version`、`claude --help` 全量、`~/.claude/` 目录结构实测、`~/.claude/sessions/` 注册表、TodoWrite/后台任务/CronCreate/hook 实际触发行为
- B 级：本仓库 DESIGN.md §2「底层能力考古（逆向 2.1.259 二进制所得）」——会话注册表/跨会话消息/hook 事件全集的现成逆向产物，注明逆向基线版本
- C 级：官方文档（code.claude.com/docs / docs.anthropic.com）、GitHub anthropics/claude-code CHANGELOG.md

**dev-2 ch2（本地探针为主）**：
- A 级：关键机制探针——候选：SessionStart hook 注入待办清单（最小 hook + 临时目录读入）、MCP server 最小骨架（stdio）注册、文件持久化+skill 读取链路；探针脚本与输出落 evidence/
- C 级：hooks/MCP/skills/commands 官方规范文档
- B 级：本仓库 hooks/、install.sh 现成实现（claude-supervisor 自身就是 hook+registry 方案的活样本）

**dev-3 ch3（网络检索为主）**：
- C 级：官方文档、CHANGELOG、GitHub README/releases、各平台官网定价页
- D 级：HN/Reddit 讨论、awesome-claude-code 类列表、各平台互链对比页——仅作**发现渠道**与交叉验证，不作证据主体
- A 级（计划注册实测，进 ch3 只做存在性/形态确认，深测留 dev-4）：claude.ai/code web（用户已有账号）、Vibe Kanban（开源可本地跑）、Conductor、Crystal、Claude Squad（TUI）

**dev-4 ch4（实测为主）**：
- A 级：可注册平台逐一走 7a/7b/7c 三需求完整流程（创建→阻塞→回复→验证继续/消费）；不可实测项显式标 D 级并降置信
- C 级：官方文档对 7b-同步 的原文表述（"继续运行中会话"类措辞必须文档原文或 A 级实测，二缺一不得判"满足"）

**二手章交叉验证规则**：ch3 为纯网络证据章，执行中至少为 Top3 候选平台各取得一条一手证据（A 级实测或官方文档原文 C 级）交叉验证核心主张（已内建于 dev-3→dev-4 流程）。

## 3. 检索策略

**关键词面**：
- 英：`Claude Code task manager` / `Claude Code todo persistent` / `Claude Code background tasks monitor` / `Claude Code session management dashboard` / `AI agent task board` / `agent orchestration UI Claude` / `Claude Code approve from phone` / `Claude Code remote control session` / `claude code kanban`
- 中：`Claude Code 任务管理` / `agent 任务看板` / `AI 编排平台 待办`

**渠道清单**：
1. 官方 changelog/release notes（anthropics/claude-code CHANGELOG.md——版本时效的第一道闸）
2. 官方文档站（code.claude.com/docs、docs.anthropic.com）
3. GitHub：topic 检索、awesome-claude-code 列表、各平台仓库 README+releases
4. HN（Algolia 搜索接口）+ Reddit r/ClaudeAI——发现渠道
5. **反查互链**：已知平台（Conductor/Crystal/Vibe Kanban/Claude Squad/Terminate…）官网的 "alternatives/compare" 页、README 里 "vs X" 段——候补漏检玩家
6. npm 生态（MCP server / claude code 相关包名扫描）
7. 上游依赖：MCP 官方 registry/server 列表

**自判检索盲区与补救**：
- 盲区 1：中文生态平台（goal 用户为中文语境）→ 补一轮中文关键词检索；仍无则在边界注明"英文生态主导"结论
- 盲区 2：产品迭代快导致文档过时 → changelog 时间戳 + A 级实测双闸
- 盲区 3：太新/太小众平台检索不到 → 反查互链 + 候选池附"检索渠道清单"作穷尽性声明；报告期后发现的玩家列附录
- 盲区 4：HN/Reddit 口碑偏差（高赞≠主流）→ 仅作发现，评分只认文档/实测

## 4. Pre-mortem：Top 3 无证据死点

1. **7b-同步误判**（最可能死点）：把"能看日志/能发通知"判为"能接管运行中会话"。规避：7b-同步判"满足"的门槛 = A 级实测完整流程 或 官方文档原文（C 级）显式表述；两者皆无 → 一律"部分/不满足"+D 级说明。
2. **Q1 能力矩阵版本时效错误**：把已废弃/改名/未发布能力当现行。规避：每格标注验证时点的 `claude --version` 版本号+日期，本地实测与文档双源；changelog 交叉。
3. **平台覆盖遗漏关键玩家**：行家一眼看出"没测 X"。规避：≥8 家 + 七渠道穷尽性声明 + 反查互链；已知种子（Vibe Kanban/Conductor/Crystal/Claude Squad/Terminate/claude.ai web）全部进池，检索中发现的追加。

## 5. 用户裁决参数（已固化，dev-4 Q8 用）

- 预算：免费优先，可接受付费（付费选项保留对照，推荐时免费优先排序）
- 移动端：加分项，非过滤条件
- 部署形态：云 SaaS 可接受，无自托管硬约束
- 默认场景：个人单人、macOS、已用 claude-supervisor、任务以 Claude Code agent 为主
