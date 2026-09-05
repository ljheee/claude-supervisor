# Plan: claude-supervisor rework 模式实施

> 依据：`spec.md`（同目录）
> 原则：核心机制零改动（hook/watchdog 不动，两套回归零改动必须全绿）；唯一代码改动是 install.sh（拼接逻辑）；协议文本改动全部走"纯重构 + 模式层新增"。

## Phase 划分总览

| Phase | 内容 | 改动文件 | 依赖 |
|---|---|---|---|
| dev-0 | 前置实测：拼接产物能否被 Claude Code 正常加载为 slash command | 无产物（实测记录写回本 plan） | 无 |
| dev-1 | core 抽取 + 绿地模式层拆分（纯重构） | commands/_core-supervisor.md, commands/supervisor.md | dev-0 |
| dev-2 | rework 模式层编写（F2/F3/F4） | commands/rework.md | dev-1 |
| dev-3 | install.sh 拼接改造 + 安装回归 | install.sh | dev-1（dev-2 可并行） |
| dev-4 | README/DESIGN 同步 | README.md, DESIGN.md | dev-1~3 |
| dev-5 | 回归验证 + 注入实测 + 自检 + commit | 全部 | dev-0~4 |

每 Phase 完成即 commit（沿用 `worker: claude-supervisor, phase: dev-N` 习惯格式），commit 前跑该 Phase 的 DoD 验证。

---

## dev-0 前置实测：拼接产物可用性

对应 spec §4 组合机制决策的验证义务（不做未实测机制的关键路径依赖）。

### 步骤

1. 【CR P1-7：两步解耦】先用普通命令名验证拼接可加载：手动构造样本 `{frontmatter + 模式声明两行} + {现 supervisor.md 去掉 frontmatter 的前 20 行}`，放到 `~/.claude/commands/test-splice.md`。
2. 启动一个临时 Claude Code 会话（用完即退出），输入 `/test-splice`（或列表确认命令出现），验证：命令被注册、frontmatter 的 description 正常显示、正文完整注入。
3. 【CR P1-7：独立验证下划线前缀】另建一个仅文件名不同的 `_test-splice.md` 副本，确认下划线前缀文件是否被注册为命令（若被注册，确认 F5 的"原料不放 commands 目录"决策正确且必须；若不被注册，该决策降级为风格约定）——此步与拼接加载验证互不干扰，任一失败不影响另一个结论。
4. 实测完删除两个样本文件，结论（通过/不通过 + 发现）追加写入本 plan 的"dev-0 实测记录"小节。

### DoD

- [ ] 拼接样本（普通名）被 Claude Code 正常加载为命令，注入内容完整
- [ ] 下划线前缀注册行为有独立实测结论并记录
- [ ] 样本文件已清理

---

## dev-1 core 抽取 + 绿地拆分（纯重构）

对应 spec F1。

### 步骤

1. 新建 `commands/_core-supervisor.md`：按 spec F1 抽取清单从现 supervisor.md 搬运模式无关章节。头部加片段声明："本文件是核心协议片段，由 install.sh 拼接进模式命令，不是独立 slash command，不要直接执行。"搬运纪律：**逐字搬运，不改措辞**（含"见启动步骤第 6 步"等交叉引用——引用目标在 core 内部，拼接后仍然成立）；【CR P0-1】例外仅三处绿地特化措辞的参数化改写（首阶段名/phase 枚举/schema 示例，见 spec F1，改写后语义等价）；【CR P1-5】total_phases 锁定句从绿地 plan 节提炼为 core 通用条款。
2. 改写 `commands/supervisor.md` 为绿地模式层：保留 frontmatter；新增"模式声明"节（一句话：本命令为绿地开发模式，前置阶段为 clarify→spec→plan，核心协议见下方拼接部分——拼接后此话术自然成立）；【CR P1-3】模式声明节同时声明本模式的 phase 枚举与首阶段（初始指令下发时以此覆盖 worker.md 的绿地默认枚举）；保留 clarify/spec/plan 三节质询清单（这三节从原文搬出但**留在模式层**，且 plan 节删除已提炼入 core 的 total_phases 锁定句）；【CR P0-2】模式层不得使用与 core 同名的二级标题；其余引用 core 的章节删除（拼接时由 core 补齐）。
3. 临时拼接验证（正式拼接逻辑 dev-3 才写，此处手工 cat）：`cat supervisor.md _core-supervisor.md > /tmp/splice-check.md`。
4. **diff 审查（本 Phase 核心门禁）**：`diff` 拼接产物与 git HEAD 的 supervisor.md，允许差异仅限：新增模式声明节、章节顺序重排、frontmatter 后的分隔标题、【CR P0-1】三处参数化改写。逐条核对语义条款零丢失零弱化。
5. 记录拆分后行数：绿地模式层 + core 行数（供 dev-5 汇总注入体积预算）。

### DoD

- [ ] `/tmp/splice-check.md` 与拆分前 supervisor.md 的 diff 全部落在允许项内（逐条列出 diff 摘要）
- [ ] core 文件含片段声明头，无 frontmatter
- [ ] 交叉引用（"见启动步骤第 X 步"类）逐条核对在拼接产物中仍成立
- [ ] 两文件行数已记录

---

## dev-2 rework 模式层编写

对应 spec F2/F3/F4。

### 步骤

1. 新建 `commands/rework.md`：frontmatter（description + `argument-hint: <改造目标> [--project-dir DIR] [--baseline <git-ref>]`）。
2. 模式声明节：本命令为老项目修补/重构模式，前置阶段为 archaeology→safety-net→spec→plan，核心协议见下方拼接部分；--baseline 参数语义（缺省 HEAD，不可解析时向用户要新锚点）。
3. **archaeology 节**：阶段定义 + 产出四件（架构地图/债务清单/疑点清单/依赖暗网）+ spec F2 的四条质询（每条≤一行命令句）+ 疑点裁决默认"需用户"级条款。
4. **safety-net 节**：阶段定义（锁定当前行为，含待改行为）+ 三条质询（锁行为不锁实现/覆盖面口径/可追溯性）+ 无框架时允许脚本级断言。
5. **spec/plan 特化节**：变更差集声明格式（旧行为 X → 新行为 Y，禁"优化XX"）、phase DoD 二选一断言（安全网一致 / 预期 diff 清单）、单 phase = 一次可回滚单元、pre-mortem 换问法（隐性契约版）。
6. **dev-N 特化节**：supervisor APPROVE 前必须亲自跑安全网对比（机械回放纪律的 rework 形态）；【CR P1-9】范围比对命令式条款（git diff --name-only vs phase 声明范围，超出即 REFINE）；【CR P1-8】dev-1 进入前工作区 clean 前置断言。
7. **frozen_behaviors 节**：schema 定义、锁定时点（safety-net APPROVE 时用户确认锁定）、锁定前初稿状态语义（触碰不判违规但 spec 审查核验覆盖）、告知机制（锁定后首个 dev 指令下发全文）、触碰机械信号（evidence 关联文件与 diff 求交）、变更通道（先改账再动手）、总结披露。
8. **rework 专属纪律节**【CR P0-2：标题不与 core "行为红线"同名】：diff 文件集 ⊆ phase 声明范围（越界即 REFINE）；免责通道（范围变更走"需用户"级 QUESTIONS）。
9. 质询计数纪律沿用 core 的 Loop Guard 与 v1 两轮上限声明（在模式层声明一次：与绿地同规）。
10. 【CR P2-14】模式声明节含长阶段时限：archaeology/safety-net 默认失联时限 120 分钟（下发指令时约定）。

### DoD

- [ ] 质询条款全部命令式，无"适当/尽量"类模糊词（grep 自查）
- [ ] frozen_behaviors schema 与 spec F3 逐字段一致，含锁定时点与告知机制条款
- [ ] rework 模式层 ≤80 行（wc -l，不含拼接的 core 部分）【CR P1-6 放宽自 60】
- [ ] 分级定义引用 core 原文不新造措辞；模式声明含 phase 枚举覆盖与 120 分钟时限声明【CR P1-3/P2-14】
- [ ] --baseline 失败分支存在（不可解析 → 问用户）
- [ ] 模式层无与 core 同名二级标题（grep 校验）

---

## dev-3 install.sh 拼接改造

对应 spec F5。

### 步骤

1. install.sh 新增拼接逻辑：对 supervisor/rework 两命令，`cat 模式层 _core-supervisor.md`（core 前加分隔标题）→ 写 `~/.claude/commands/<name>.md`；拼接后 grep 断言【CR P2-10 修正 frontmatter 断言】：文件首行为 `---` 且第二个 `---` 之后正文无以 `---` 为整行的水平线（不误杀正文合法分隔线）、关键节标题齐全（"你的身份与核心原则"/"中断与失联处理"/"行为红线"）、无重复的 `## ` 标题——断言失败则备份中止安装，不产出半成品。
2. `_core-supervisor.md` 安装为原料副本：`~/.claude/hooks/claude-supervisor/_core-supervisor.md`（与 hook 同目录，不在 commands 目录）。
3. 备份/幂等/损坏中止路径复用现有函数，不为拼接新写一套。
4. 卸载路径检查（README 卸载节在 dev-4 同步，此处只保证 install 幂等重跑行为不变）。

### DoD

- [ ] 全新目录模拟安装：两命令生成、grep 断言通过
- [ ] 幂等重跑：二次安装不产生重复拼接（产物 diff 为空）
- [ ] 断言失败注入测试（构造畸形 core）：备份中止，无半成品残留
- [ ] `_core-supervisor.md` 未出现在 `~/.claude/commands/`

---

## dev-4 README + DESIGN 同步

对应 spec F6。

### 步骤

1. README：命令节加 `/rework` 条目、快速开始补老项目三行示例、文件清单加 `_core-supervisor.md` 与 `commands/rework.md`、卸载节更新。
2. DESIGN 新增第 12 节"模式分层与 rework 模式"：拆分动机（协议膨胀 vs 泛化）、方案 B 确定性理由、考古四件套依据、frozen_behaviors、顺手重构红线、注入体积预算数据（dev-1/dev-2 行数）。
3. DESIGN §9 已知边界补"模式选择是用户显式决策"条目。
4. 版本要求不变（2.1.259）；README"常见问题"补一条：绿地/重构拿不准用哪个 → 有存量代码要改就用 /rework。

### DoD

- [ ] README 四处更新齐全，命令列表与实际安装产物一致
- [ ] DESIGN 第 12 节含六个要素（动机/方案B/四件套/frozen/红线/体积预算）
- [ ] grep 无"v2 起唯一命令是 /supervisor"类过时表述

---

## dev-5 回归验证 + 注入实测 + 收尾

对应 spec DoD 全项。

### 步骤

1. 跑 `bash test_stopfailure.sh` 与 `bash test_watchdog.sh`：零改动全绿。
2. 本地真实安装（bash install.sh），然后注入实测：新开 Claude Code 会话分别执行 `/supervisor` 与 `/rework`（可用极小目标，验证协议注入与启动步骤执行到"等待注册"即可退出，不做完整项目）。
3. DoD 逐条勾验（spec §6 五项）。
4. 汇总挂账清单（无法主动安排的实测项），提交最终 commit。

### dev-0 实测记录

（待 dev-0 执行时回填）

### DoD

- [ ] 两套回归零改动全绿
- [ ] /supervisor 与 /rework 真实注入均成功（协议头到"等待 WORKER REGISTER"即算通过）
- [ ] spec §6 五项 DoD 全部勾验
- [ ] 挂账清单（预期至少一条：rework 全流程真实项目实战，类似 walk-tracer 之于 v2）

---

## 明确不做清单

- 不动 worker.md、hook、watchdog；
- 不做 research 模式的任何预留接口；
- 不做模式自动判定；
- 不在本轮实测老项目全流程（留作下一个 walk-tracer 级实验）。
