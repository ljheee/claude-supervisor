# Plan: research 模式 — 调研/探索任务监工

> 依据：spec.md（同目录）
> 状态：**post-hoc 补记**——实现先行（2026-09-09 单次会话内完成 dev-1..dev-3），本 plan 按仓库先例（7001dae plan: record post-implementation CR findings）补齐计划面并承载 CR 记录；dev-4 为 CR 修复待办。

## §0 约束回顾（来自 spec 的硬边界）

- 绿地/rework 零改动：只允许新增 `commands/research.md` + install.sh 两处新增行 + README/DESIGN/spec 纯追加；
- 不改 worker.md / hooks / watchdog / registry.py（--mode 自由文本，无需动）；
- 模式层预算 ≤ rework 的 68 行（§12.6 注入体积纪律）。

## Phase 划分（post-hoc 对账）

### dev-1 模式层 `commands/research.md`（已完成）

- DoD：frontmatter（description/argument-hint 含 `--out`）；模式声明节含五要素（phase 枚举 `<scope|survey|dev-N>`、首阶段指令全文、`--mode research`、`--out` 语义与缺省、非 git 允许 + 120min 长阶段时限）；前置阶段两节（scope/survey 质询条款，上限两轮）；dev-N 特化（证据五级 A-E/抽查复现/结论对账/90min 时间盒/章间新发现走 QUESTIONS）；research 专属纪律（只读红线/未决显式化/报告结构/总结披露）。
- 验证：行数 ≤68（实测 50 ✓）；四个 spec 缺口各有对应条款 ✓。

### dev-2 install.sh 注册（已完成）

- DoD：头部注释 `/research` 条目 + `splice_command research.md` 一行；拼接结构断言（frontmatter/五关键节/无重复 h2）对 research.md 生效。
- 验证：install.sh 全绿；产物 12 个 h2（模式层 4 + core 8）无撞名 ✓。

### dev-3 文档同步（已完成）

- DoD：README（模式清单/安装内容/调研章节/命令表/FAQ/卸载六处）+ DESIGN（§12.6 行预算表 + §12 尾 research 摘要）+ spec 入库。
- 验证：grep 无"两种模式/三个 slash 命令"残留 ✓。

### dev-4 CR 修复（待办——见下方自 CR 记录与 subagent CR 结果）

## pre-mortem

"假设 /research 第一次真机跑就翻车，最可能死在哪？"——**worker 侧语义断层**：模式层的约束全是 worker 需要遵守的（只读红线、--out 落点、证据分级、非 git 跳过 commit），但 worker 只读 worker.md，模式层条款不会自动到达 worker——必须由 supervisor 在初始指令/首个 dev 指令中显式下发。rework 有先例条款（"锁定后 supervisor 在首个 dev 指令中把 frozen 清单全文下发给 worker——worker 不读 state.json，必须显式告知"），research 模式层目前只有时间盒一处带"下发时显式约定"。这是自 CR 的 P1，见下。

## 自 CR 记录（2026-09-09，实现者本人）

- **P1-1 worker-facing 语义无下发条款**：`--out` 路径、只读红线（含 commit 文件集 ⊆ 报告目录）、证据五级分级定义、"非 git 目录跳过 commit"——四项 worker 必须知道的约束，模式层均无"初始指令/首个 dev 指令中显式下发"条款。worker 只读 worker.md；worker.md 的 commit 纪律是强制语气，非 git 目录下 research worker 会陷入"协议要求 commit 但无 git"的自相矛盾。修法：模式层补一条统一下发条款（对齐 rework frozen 清单下发的先例句式）。
- **P3-2 DESIGN.md 行数未实测**：§12.6 写"拼接产物 research 218 行"，实测 244 行；同段 spec 实施清单写"~70 行"，实测 50 行。数字是编写时估的没量。
- **查过无问题项**：phase 枚举/首阶段指令全文符合 core P0-1 参数化契约（F1 三处锚点全命中）；质询两轮上限与 Loop Guard 独立计数声明与 core 一致；`--mode research` 走 registry 自由文本无 schema 改动；时间盒 90min < 失联判定 120min 顺序合理（超时上报先于 watchdog 兜底）；只读红线是绊索不是墙（Bash 可绕）与 §9.5 哲学一致；hook/watchdog/registry 全绿证明零代码改动边界未破。

## subagent CR 记录（2026-09-09，独立会话，逐条经实证复核属实）

- **P1-A 只读红线机械信号无基线**（`research.md:45` vs `rework.md:59`）：裸 `git diff --name-only` 只看未暂存改动——已 commit 的越界产品代码改动静默漏检；且缺 rework 的 dev-1 前 clean 断言，用户存量脏区会被误判为 worker 越界。修法：补"每章基线 commit ..HEAD + 进入 dev-1 前 clean 断言"。
- **P2-A registry --mode 枚举冲突**（`_core-supervisor.md:14`）：core 步骤 4 命令模板硬编码 `--mode <greenfield|rework>`，research supervisor 忠实照抄会注册错 mode。修法：core 枚举参数化（`<greenfield|rework|research>` 或"由模式层声明"）。
- **P2-B --out 归属两处打架**（`research.md:16` vs `:22`）：启动断言要验证缺省目录可写，但缺省路径的 `<日期-主题>` Phase 0 才能定。修法：显式 --out 锁死；缺省由 supervisor 在 scope APPROVE 后定题回填。
- **P2-C 追加 scope 权限冲突**（`research.md:41`）：授权 supervisor 自行追加问题（记 decisions），与 core QUESTIONS "范围增减=需用户" 冲突。修法：明确追加需用户确认（对齐"范围变更即目标变更"）。
- **P2-D 90min 中间上报与 worker 协议冲突**：worker.md "不干完里程碑不上报" vs research "超时必须上报中间结论"——P1-1 下发缺口的新实例证据。
- **P2-E 非 git 恢复锚悬空**：core/worker 恢复流程全 git 锚定（commit hash），非 git 调研中断后无对齐锚。修法：补"--out 最新落盘产物"作锚。
- **P3-A DESIGN §12.6 行数全表过期**：core 194（写 173）/worker 128（写 124）/rework 拼接 262（写 237）/research 拼接 244（写 218）/绿地拼接 233（写 208）——五个数全错（前四个是 v3.1 期间过期，research 是本次未实测）。
- **P3-B DESIGN:331 "启动步骤 7"**：现行 core 首阶段指令在步骤 8（v3 插 cron 后未更新引用，历史叙述）。
- **P3-C README 文件清单表缺行**（162-165）：无 `commands/research.md` 与本 specs 目录两行（卸载节有，清单节漏）。
- **P3-D 尾部输出与 core 残留**：install.sh 尾部快速开始无 research 示例；core:101 "spec APPROVE 前不进入 plan" 与 core:166 "spec.md/plan.md" 举例在 research 枚举下悬空（rework CR 时期已容忍的绿地举例残留，research 下更明显）。
- 查过无问题：拼接产物与源逐字节一致；P0-1 三锚点参数化正确；质询两轮/Loop Guard 独立计数一致；90min<120min 顺序成立；worker.md 零改动边界成立；install.sh 备份/原子写/断言中止逻辑未受影响。

## dev-4 CR 修复（2026-09-09，已完成）

- **P1-1 + P2-D（下发缺口，合并修）**：`research.md` 模式声明新增「worker-facing 约束统一下发」条款——初始指令除 core 必含项外强制完整下发五项（--out 路径与落点纪律/只读红线与免责通道/证据五级定义与上报格式/非 git 跳 commit 覆盖声明/90min 时间盒与超时中间上报义务——显式覆盖 worker「不干完里程碑不上报」默认纪律）。
- **P1-A（机械信号修复）**：只读红线改为「范围比对（命令式动作）」：`git diff --name-only <本章基线 commit>..HEAD` 与报告目录比对（基线=该章首指令下发前最后一个 commit），并补「进入 dev-1 前确认工作区 clean」断言——对齐 rework.md:59-60 先例。
- **P2-A**：`_core-supervisor.md` 步骤 4 registry 命令模板枚举改为 `<greenfield|rework|research>`（一处改动惠及全部三模式产物）。
- **P2-B（--out 时序矛盾）**：显式传参启动即校验；缺省时启动只校验 `docs/research/` 可创建，`<日期-主题>` 由 supervisor 在 scope APPROVE 后定题回填，首个 dev 指令显式下发。
- **P2-C**：章间新发现改为「你评估后**向用户确认再追加**（追加即范围变更，对齐 core 总则，确认结果记 decisions）」。
- **P2-E**：非 git 目录中断对齐锚补「--out 最新落盘产物（文件清单+mtime），resume 后先对齐最新落盘再续查」。
- **P3-A**：DESIGN §12.6 行数表全量实测重写（39/68/51/194/128 源 + 233/262/245 拼接，2026-09-09 双路 CR 后实测），并落教训「改完必须 wc -l 再写数」。
- **P3-B**：DESIGN §12.2「启动步骤 7」加时点注记（拆分时是步骤 7，v3 插 cron 后顺延为步骤 8）——历史叙述保留，不改写。
- **P3-C**：README 文件清单表补 `commands/research.md` 与 `specs/2026-09-09-research-mode/` 两行。
- **P3-D**：install.sh 尾部快速开始补 /research 示例块 + 流程行加 research 模式；core:101 串行规则改为模式无关表述（「上一前置阶段 APPROVE 前不进入下一阶段（绿地即 spec APPROVE 前不进入 plan）」）；core:166 产出物举例改为「各阶段产出物如 spec.md/plan.md/调研章」。
- **验证**：install.sh 拼接断言全过，三产物与源逐字节一致（cmp）；行数 245/233/262 与 DESIGN 新表相符；三套回归 stopfailure 83 / watchdog 50 / registry 29 全绿。
- **修复后行数**：research 模式层 50→51 行（仍在 ≤68 预算内）。
