# Spec: claude-supervisor rework 模式 — 老项目修补/重构监工

> 分支：`feat/rework-mode`（基于 `feat/v2-scheduled-supervision`，v2 合并前先行开发，合并顺序：v2 先、rework 后）
> 依据：2026-09-05 walk-tracer 绿地实验结论 + 模式泛化讨论
> 状态：待评审

## 1. 背景与问题

walk-tracer 实验验证了 v2 协议在**绿地项目**（从零开发）下全流程运转达标（14 reviews / 15 decisions / 收尾清理全绿）。但 /supervisor 的阶段状态机（clarify → spec → plan → dev）隐含"从零开始"假设。对**老项目修补/重构**这类高频真实场景，直接套用会暴露四个缺口：

1. **无基线锚定**：REFINE/APPROVE verdict 失去参照系——"改好了"还是"改坏了"无从判定；
2. **无回归安全网**：改造前没有锁住现状的测试层，行为变更不可归因；
3. **考古缺失**：存量代码的"bug vs 有意为之"没有裁决机制，worker 按直觉清理会炸出隐性契约事故；
4. **顺手重构失控**：重构最经典的死法——每个 phase 都"顺便"多改一点，最终 diff 无法评审。

同时 v2 的核心资产（四层中断防御、定时巡检、账本、三层回答防火墙、被动守卫、commit 纪律）**全部是模式无关的**，应完整复用而非重写。

## 2. 目标

1. 新增 `/rework` 命令（老项目修补/重构模式），完整复用 v2 核心机制；
2. 核心协议与模式层**物理拆分**（`_core-supervisor.md`），单点维护、模式互不污染；
3. rework 特有机制：考古阶段（bug/feature 裁决）、安全网阶段（行为锁定）、不改清单（frozen_behaviors）、小步回滚、顺手重构硬红线；
4. 绿地模式**零行为回归**——拆分必须是纯重构，语义条款一条不减不弱化。

## 3. 非目标

- 不做 research 模式（调研/探索任务另立 spec，本 spec 不预留其接口）；
- 不改 worker.md（worker 协议是模式无关的：干活、上报、中断恢复不随 supervisor 审查语义变化）；
- 不改 hook/watchdog（零代码改动边界沿用；**例外：install.sh 本 spec 必须改**——拼接逻辑是本 spec 的交付物）;
- 不做任务类型自动判定——模式由用户显式选命令（`/supervisor` 或 `/rework`），不做 LLM 软判定；
- 不引入覆盖率工具链/静态分析依赖——安全网=特征/快照测试（有测试框架用框架，无框架允许脚本级断言）；
- 不解决"巨型 monorepo 全量考古"的超大场景（考古范围以本次改造目标面为中心扩散）。

## 4. 架构定位

```
仓库源文件                          install.sh 拼接            安装产物
commands/_core-supervisor.md  ─┐
commands/supervisor.md(绿地层) ─┼──→ cat(模式层+core) ──→ ~/.claude/commands/supervisor.md
commands/rework.md(rework层)  ─┘                        ~/.claude/commands/rework.md
```

**组合机制决策：install 时拼接（方案 B），非运行时 @ 引用（方案 A）**。理由：确定性优先——本套件一贯哲学是"能硬不软"（DESIGN §9.5 对冲策略的第一条），拼接发生在安装期、可 grep 断言、可 diff 审查；@ 引用机制未实测，不做关键路径依赖。方案 A 若后续实测可用可再切换，本 spec 不锁死。

**core 抽取原则**：模式无关者进 core（身份/守卫/账本/OODA/四层防御/三层回答/dev-N 流转骨架/红线），阶段质询留模式层（绿地的 clarify/spec/plan 三件套 vs rework 的考古/安全网/改造特化）。

**rework 状态机**（对齐漏斗框架延续，挖掘对象换成考古/锁定/改造）：

```
archaeology（考古与基线）→ safety-net（回归安全网）→ spec（改造规格）→ plan → dev-1..N → done
```

## 5. 功能需求

### F1 核心协议抽取（纯重构，绿地零回归）

抽取清单（从现 supervisor.md 197 行中）：

- 身份与核心原则（被动守卫、用户唯一权威、session_id 主键）；
- 启动步骤 1–7 全部（含巡检 cron 创建、session_id UUID 自检）；
- 全局状态 schema（含 decisions 字段）与原子写纪律、身份主键规则、多 worker 规则、Loop Guard；
- 四层防御全部（StopFailure 处理四步、STALLED/RESUME/STATUS/idle 通知、巡检三步、watchdog）；
- OODA 循环、WORKER QUESTIONS 三层回答；
- dev-N 状态机骨架（自 CR → 补 CR → APPROVE/REFINE、total_phases 锁定、CronDelete 收尾、总结报告）；
- 行为红线。

留模式层：前置阶段（clarify/spec/plan 或 archaeology/safety-net）的阶段定义与质询清单、模式声明节、模式特化参数（如 rework 的 --baseline）。

约束：
- core 文件头部声明："本文件是核心协议片段，由 install.sh 拼接进模式命令，不是独立 slash command，不要直接执行"；
- 【零回归硬约束】拼接（绿地模式层 + core）与拆分前 supervisor.md 的 diff **仅允许**：模式声明节新增、章节顺序重排——语义条款一条不减、不弱化、不改措辞（纯搬运）；
- core 不含 frontmatter（拼接时追加在模式层之后）。

### F2 rework 状态机与各阶段质询

**archaeology（考古与基线）**——对应绿地 clarify 的位置，产出四件：架构地图（改造目标面的模块/数据流）、债务清单、bug/feature 疑点清单、依赖暗网（上下游）。质询条款（命令式）：

- 对改造目标涉及的每个模块：**当前对外行为逐条显式列出**，含未写进文档的隐性契约（"谁在依赖这个行为"给证据）；
- 每处疑似 bug 的诡异代码：**先 git blame / git log 考古意图**，commit message 说不清的标"待用户裁决"，禁止 worker 自行判定 bug vs feature；
- 依赖暗网三问必答且给证据：谁调用它（grep 反查）、它调用谁、改动会波及谁；
- 反向问："这次改造**最不能破坏的三个行为**是什么"——答案汇总成不改清单初稿。

疑点裁决走三层回答：bug/feature 判定默认**"需用户"级**（涉及目标语义本身），裁决记入 decisions（考古裁决的存档价值高于绿地——不落账就会有人再犯）。

**safety-net（回归安全网）**——产出=锁定当前行为的特征/快照测试（**含待改行为**——只有先锁住现状，改造前后的 diff 才可归因）。质询条款：

- 每条测试**锁行为不锁实现**：断言输出/状态/接口契约，不 assert 内部结构与私有函数——锁了实现，重构必然假红；
- 覆盖面=改造目标面+不改清单面，**不追求全库覆盖率**；
- 每条测试注明锁定的是行为清单的哪一条（可追溯到 archaeology 产出）。

**spec/plan 阶段**：复用绿地质询框架（边界/错误路径/DoD 客观性/pre-mortem），叠加 rework 特化：

- spec 的"场景拷问"对象改为**改造规格与现状的差集**：每条变更显式声明"旧行为 X → 新行为 Y"，不允许"优化XX"这类无基线表述；
- plan 的每个 phase DoD 必含二者之一：**"安全网前后输出一致"断言**（行为不变类改动）或**"预期行为 diff 清单"**（行为变更类——实际 diff 与声明逐条对应，多出的即顺手重构）；
- phase 粒度约束：单 phase = 一次可独立回滚的改动单元（建议 ≤ 一次 revert 可干净撤销的范围），显著小于绿地默认粒度；
- pre-mortem 一问换成："假设这次重构上线后出了生产事故，最可能炸的是哪条隐性契约"。

**dev-N**：supervisor APPROVE 前**必须亲自跑一次安全网对比**（不只信 worker 摘要——延续机械回放纪律）；每 phase commit 即回滚锚点。

### F3 不改清单（frozen_behaviors）

- state.json 新增**可选**顶层字段：`"frozen_behaviors": [{"id", "desc", "evidence", "locked_by", "ts"}]`（hook/watchdog 不读该字段，无兼容风险；绿地模式不写该字段）；
- 流转：archaeology 产出初稿 → 用户确认后锁定（locked_by=用户）→ dev 阶段任何 commit 触碰 frozen 行为且无用户授权 → REFINE + 升级用户；
- 变更通道：frozen 行为确需变更时走 QUESTIONS 的"需用户"级申请，获准后先改 frozen_behaviors 条目（记 decisions）再动手；
- 总结报告披露：保留的 frozen 行为、经授权变更的条目及理由。

### F4 顺手重构检测（rework 硬红线）

- 每个 dev commit 的 **diff 文件集必须 ⊆ 该 phase 声明范围**；超出即 REFINE，无论改动多"合理"；
- 免责通道：确需扩大范围时 worker 先停下走 QUESTIONS（"需用户"级——范围变更即目标变更），获准后 supervisor 更新声明范围、worker 才能动手；
- 与绿地"scope 隔离"的关系：共用同一机制，但 rework 中越界即 REFINE（绿地下主要是多 worker 协调问题）；
- 措辞入 rework 模式层红线节，命令式、无例外条款。

### F5 install.sh 拼接

- 拼接规则：模式层文件（含 frontmatter）在前 + `_core-supervisor.md`（去 frontmatter，含分隔标题）在后；
- 备份/幂等/损坏中止逻辑全部沿用现行为（P0-1/P0-2 修复不回归）；
- `_core-supervisor.md` **不安装为独立命令**（拼接原料，不进 `~/.claude/commands/`——放 `~/.claude/commands/` 会有被注册为命令的风险，实际安装为 `~/.claude/hooks/claude-supervisor/_core-supervisor.md` 原料副本，便于用户对照已装命令的构成）；
- rework.md 的 argument-hint：`<改造目标> [--project-dir DIR] [--baseline <git-ref>]`；--baseline 语义：用户已知的"行为正常"锚点 commit（缺省 HEAD），archaeology 与 safety-net 以它为基线；
- 卸载说明同步（README 卸载节补 rework.md 与原料文件）。

### F6 文档同步

- README：命令列表加 `/rework`、快速开始补老项目场景（三行示例）、文件清单更新（含 `_core-supervisor.md`）、卸载节更新；
- DESIGN.md：新增**第 12 节"模式分层与 rework 模式"**——拆分动机（协议膨胀 vs 泛化的矛盾、注入体积预算）、拼接方案 B 的确定性理由、考古四件套设计依据、frozen_behaviors 与顺手重构红线；§9 已知边界补一条"模式选择是用户显式决策，协议不做任务类型自动判定"；
- 本 spec 目录不留 claude_cron.md 类的独立实测文档（机制实测已完成于 v2，本 spec 的实测项在 plan dev-0 内联）。

## 6. 验收标准（DoD）

1. 拼接生成的 supervisor.md 与拆分前版本语义等价：diff 审查通过（允许项：模式声明节新增、章节顺序），零条款丢失/弱化；
2. rework.md 含 F2/F3/F4 全部条款：命令式、可执行、有失败分支、无"适当/尽量"类模糊词；
3. install.sh 装出两个命令均可用：本地实测 `/rework` 与 `/supervisor` 注入成功（含拼接产物 grep 断言：关键节齐全、单一 frontmatter、无重复标题）；
4. 两套回归测试（test_stopfailure.sh / test_watchdog.sh）零改动全绿；install 备份/幂等行为不回归；
5. 人工评审通过（用户 CR）。

## 7. 风险与对冲

| 风险 | 对冲 |
|---|---|
| 拆分导致绿地模式行为回归 | dev-1 以"拼接产物 vs 现文件"逐条 diff 审查为 DoD 硬门槛 |
| 拼接顺序/锚点错误产出畸形命令 | install 后 grep 断言（见 DoD 3），失败即中止安装 |
| safety-net 测试锁实现导致重构假红 | F2 质询条款显式"锁行为不锁实现"，plan 阶段质询复核 |
| frozen_behaviors 过宽卡死开发 | 显式变更通道（需用户级授权，先改账再动手） |
| rework 协议膨胀稀释遵循度 | rework 模式层增量预算 ≤60 行（不含 core 复用部分）；质询条款沿用"每条≤一行命令句"纪律 |
| 老项目无测试框架 | safety-net 允许脚本级断言（bash diff/快照文件对比），不强制框架 |
| --baseline 指向的 ref 在 worker 环境不可达 | archaeology 第一步校验 git ref 可解析，失败即向用户要新锚点 |
| v2 分支未合并导致 rework 基于"未来 main" | 合并顺序已在 spec 头声明（v2 先、rework 后），rework 分支基于 v2 创建，合并时无冲突面（改不同文件为主） |
