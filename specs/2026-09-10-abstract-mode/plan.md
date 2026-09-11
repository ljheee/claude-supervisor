# Plan: abstract 模式 — 抽象提炼任务监工

> 依据：spec.md（同目录）
> 状态：**dev-1..dev-4 已完成（2026-09-10，两轮 subagent CR 修复均入账）；真机冒烟待做**

## §0 约束回顾（来自 spec 的硬边界）

- 绿地/rework/research 三模式层零改动：只允许新增 `commands/abstract.md` + install.sh 新增行 + core 枚举与状态机参数化两处 + README/DESIGN/spec 纯追加；
- 不改 worker.md / hooks / watchdog / registry.py（--mode 自由文本，无需动）；
- 模式层预算 ≤ rework 的 68 行（§12.6 注入体积纪律）。

## Phase 划分

### dev-1 模式层 `commands/abstract.md`

- DoD：frontmatter（description/argument-hint 含 `--out`）；模式声明节含五要素（phase 枚举 `<ingest|distill|refine-N>`、首阶段指令全文、`--mode abstract`、`--out` 语义与缺省、非 git 允许 + 120min 长阶段时限）；worker-facing 五项统一下发（--out 落点/只读红线/命题与锚点格式/非 git 跳 commit 覆盖声明含 `worker: <你的名>` 署名与 /rename 时序/时间盒与超时上报）；前置阶段两节（ingest/distill 质询条款，上限两轮）；refine-N 特化（锚点抽查/覆盖对账/空话检查/缺席信号/命题两分法/对抗返工）；abstract 专属纪律（输入面锁死/未决显式化/报告结构/总结披露）。
- 验证：行数 ≤68（wc -l 实测）。

### dev-2 install.sh 注册 + core 枚举与状态机参数化

- DoD：头部注释 `/abstract` 条目 + `splice_command abstract.md` 一行 + 尾部快速开始补 /abstract 示例块与流程行；core 两处：步骤 4 枚举 `<greenfield|rework|research|abstract>` + 状态机进入/推进条款参数化（执行阶段语义以模式层声明为准，dev-N 骨架为默认）。
- 验证：install.sh 全绿；四产物与源逐字节一致（cmp）；无重复 h2。

### dev-3 文档同步

- DoD：README（模式清单/抽象提炼章节/命令表/FAQ/文件清单表）+ DESIGN（§12.6 行数表实测更新 + §12 尾 abstract 摘要）。
- 验证：grep 无"三种模式/三个模式"残留；DESIGN 行数为实测数。

### dev-4 CR 修复（2026-09-10，已完成）

subagent CR（独立会话 Explore agent，5 项发现逐条实证复核属实）与修复：

- **P1-1 core 状态机硬绑 dev-N**（`_core-supervisor.md:178,183`）：前置阶段 APPROVE 后强制进 `dev-1`、APPROVE 推进/done 绑 total_phases——abstract 的 refine-N 进不去也收不了尾。修：core 两处参数化（执行阶段语义以模式层声明为准，dev-N 骨架为默认，覆盖即完整裁定）+ abstract.md 模式声明完整声明 refine-N 进入/推进/done 判据与收尾引用。spec §2/§4 同步如实（core 改动一处→两处）。
- **P1-2 免责通道未定义**：下发条款②提「只读红线与免责通道」但全文无免责规则定义（research.md 有：确需改产品代码→QUESTIONS 需用户级申请，未获准标 E 级收章——半条覆盖教训重演）。修：refine-N 特化补完整免责通道（未获准就以材料内现有信息收稿并显式标注缺口）。
- **P2-1 --out 时序矛盾**：下发条款①要求初始指令下发「--out 最终路径」，但最终路径要 distill 定题后才确定。修：①改为落点纪律（显式路径即最终路径；缺省则明确最终路径由首个 refine 指令下发）。
- **P2-2 非 git 与 git diff 强制检查冲突**：非 git 目录允许，但 refine-N 只读红线核对无条件 `git diff`。修：限定 git 仓库内执行，非 git 目录以落盘审计面代替（产物路径 ⊆ 报告目录或系统临时目录）。
- **P3 README 四处**：「三个 hook」实装四个（Stop 漏列，存量错误顺手修）；abstract 示例命令断行；漂移恢复 FAQ 写死 `/supervisor`（改对应模式命令）；文件清单表漏 specs/2026-09-10-abstract-mode/ 行。
- 查过无问题项：frontmatter 4 行闭合；h2 与 core 无撞名；行数/拼接数与 DESIGN §12.6 一致；install 注册/registry 枚举/命令表/卸载已覆盖 abstract；无模式计数残留。

### 第二轮终审 CR（2026-09-10，独立会话，4 项发现逐条实证复核属实并已修）

- **P1-1 WORKER REPORT 模板未覆盖**（core:46 `Phase: <本模式前置阶段枚举|dev-N>`）：refine-N 既非前置阶段也非 dev-N，worker 可能按 dev-N 上报。修：abstract.md phase 枚举条款显式声明覆盖范围含 REPORT 模板 Phase 字段。
- **P1-2 范围比对漏未提交改动**：只查 `git diff <基线>..HEAD` 漏掉 worker 改了未 commit 的产品代码。修：abstract.md 补 `git status --porcelain` 与 diff 双查。⚠️ 同型盲区存在于 rework.md:59 与 research.md:47（存量，本轮不动真机验证过的 research/rework 条款，记录为遗留观察待用户裁决）。
- **P2 Loop Guard 失效**：core:105「同一 phase 连续 3 次 REFINE」——abstract 的 REFINE 恒递增序号，该条款永不命中。修：abstract.md 补本模式适配（按 refine 序列计数，连续 3 轮退回即 ESCALATE）。
- **P3 文档残留**：README「四层中断防御」与 core 节标题「五层防御」不一致（存量错误顺手修）；spec/plan 状态行仍写待实施/枚举一处。已同步。
- 查过无问题项：三旧模式正确落入 dev-N 默认骨架；四拼接产物逐字一致；行数全符 §12.6；输入锁死/抽查/免责与时间盒数值自洽；install.sh `bash -n` 通过。

## 遗留观察

### 第三轮复审（2026-09-10，独立会话，1 P2 + 2 P3 + 1 判断，均已处置）

- **P2 Loop Guard off-by-one 歧义**：「连续 3 轮被退回（refine-3 仍收问题清单）」退回事件计数与 refine 序号锚点不一致，LLM 执行者可能提前一轮 ESCALATE。修：改为「审查 refine-3 的产出仍需发问题清单即已连续 3 轮退回——不再签发 refine-4，直接 ESCALATE」。
- **P3 DESIGN 四处四层/单处残留**：§1「四层防御」补 v3 时点说明；§4.3 照 §12.2 历史叙述先例保留原文加时点注记；§12.1 core 内容清单「四层」→五层；§12.6 research 段「git diff 文件集」→「改动文件集含未提交」；abstract 段「core 有一处改动」→两处（补状态机参数化，与 spec §2 对齐）。
- **P3 research.md 红线首句表述面偏窄**：「commit 的文件集」→「改动（含未提交，与下方双查一致）的文件集」。
- **判断项（不改）**：core:105 Loop Guard 原文保留——三旧模式 phase 名不变条款有效；abstract 覆盖声明显式点名原文并完整替代前半句，后半句（双 worker 互覆盖）模式无关继续生效，覆盖无缺口；改 core 需重拼四产物并动摇「真机验证过」状态，代价大于收益。
- 查过无问题：三模式双查条款语义一致各自适配；core:46 模板与覆盖声明无冲突；两 commit diff 与 message 相符；行数全表实测相符；四产物 cmp 一致；无新增计数残留。

- ~~范围比对「未提交改动」盲区为三模式共有~~ **已统一修（2026-09-10，用户裁决"修"）**：rework.md 与 research.md 的范围比对同样补 `git status --porcelain` + 基线 diff 双查（严格增强、无语义风险；research.md 原"裸 diff 只看未暂存改动"的括注方向写反，一并更正为"区间 diff 不含未提交改动"）。abstract 已在第二轮 CR 修复，三模式现已一致。

## pre-mortem

"假设 /abstract 第一次真机跑就翻车，最可能死在哪？"——**输入面锁死与监工自身行为的矛盾**：监工锚点抽查要"打开材料核对"，但抽查中看到材料里别的内容算不算"引入新材料"？若条款措辞不精确，worker 会拒绝配合抽查或监工自行扩面。spec §4 已显式豁免"抽查打开材料本身不算引入"，dev-1 措辞必须把豁免边界写实（打开核对 ≠ 把新观察写进命题）。

第二风险：**refine-N 与 worker"不干完里程碑不上报"的默认纪律冲突**——worker 把整轮 refine 当一个里程碑干完才报，监工失去逐轮对抗的机会。照 research 先例：下发条款显式约定"每轮 refine 产出即上报，不等整体收敛"。

## 自 CR 记录（2026-09-10，设计者本人）

- **P2-1 覆盖矩阵的"材料"粒度未定义**：十几处代码修改是 1 件材料（一个 diff）还是 14 件（14 个 commit）？粒度太粗则覆盖对账空转（一个 diff 被"作者在重构"一句话全覆盖），太细则清单爆炸。修法（dev-1 落条款）：ingest 时与 worker 约定材料盘点粒度——可独立解释的最小单元（文档=逐篇，commit=逐个，散 diff=逐 hunk 群），粒度在 ingest 定稿时锁定并随覆盖矩阵披露。
- **P3-2 "替代解释做建议"与空话检查的判定顺序**：替代解释未做不 REFINE，但空话检查不通过必须返工——顺序上空话检查是门槛、替代解释是加分，dev-1 条款需显式区分两档，避免 worker 混淆。
- **查过无问题项**：--out 机制/只读红线/git 语义均整条抄 research（含 §7.1 教训的署名与 /rename 时序）；`--mode abstract` 走 registry 自由文本无需改 registry.py；拼接结构断言的五节清单是 core 侧共有节，abstract 模式层新增 h2 无撞名风险（ingest/distill/refine 等节名与 core 8 节不重）。
