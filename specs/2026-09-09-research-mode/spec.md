# Spec: claude-supervisor research 模式 — 调研/探索任务监工

> 分支：`feat/v3-multi-supervisor`
> 依据：rework-mode spec §3 非目标（"调研/探索任务另立 spec"）+ 2026-09-08 walk-tracer polish 轮交付后的模式补全
> 状态：已实施（2026-09-09）

## 1. 背景与问题

v3 已有两种模式：绿地（`/supervisor`，从零开发）与 rework（`/rework`，老项目修补）。两类任务的共同假设是**产出是代码**——commit 纪律、scope 文件隔离、DoD 都是围绕"改代码"设计的。但第三类高频真实场景是**调研/探索任务**：技术选型对比、事故根因考古、依赖现状摸底、可行性验证——产出是**报告与证据**，不是代码改动。直接套用现有模式会暴露四个缺口：

1. **验收锚点错位**：dev-N 的 DoD 语法（"测试全绿+可演示"）对调研不适用——报告的验收标准是"问题清单逐问有答案+置信度"；
2. **只读语义缺失**：现有协议的 commit 纪律隐含"鼓励改代码"，调研 worker 的产品代码默认应该是只读的，探针产物只能落隔离目录；
3. **证据无分级**：调研报告最大的死法是"看起来有结论，细看全是转述"——没有 A-E 证据分级与抽查复现机制；
4. **无限展开风险**：调研没有"phase 完成"的自然边界（代码写完就完了，调研永远可以再查一个来源），缺时间盒与结论对账。

v3 核心资产（身份/账本/四层中断防御/巡检/watchdog/OODA/三层回答防火墙/红线）继续全部模式无关复用。

## 2. 目标

1. 新增 `/research` 命令（调研/探索模式），复用「模式层 + `_core-supervisor.md`」拼接架构；
2. research 特有机制：问题定义阶段（可验收的问题清单）、调研方案阶段（信息源+章节=dev 单元）、证据五级分级（A 一手实测 / B 源码定位 / C 官方文档 / D 二手转述 / E 推测）、A-C 抽查复现、产品代码只读红线、单章时间盒、结论对账（scope 清单 ↔ 报告终稿逐问核对）；
3. 绿地/rework 模式层零改动；core 的改动限于双路 CR 修复（registry --mode 枚举补 research + 两处绿地举例改为模式无关表述，见 plan.md dev-4）——三模式产物同步重拼，拼接结构断言全过。

## 3. 非目标

- 不做任务类型自动判定（用户显式选命令，沿用既有哲学）；
- 不改 worker.md / hook / watchdog（零代码改动边界：调研差异全部在模式层声明，worker 协议本就模式无关）；
- 不做报告模板引擎/渲染（markdown 落盘即交付）。

## 4. 设计决策

- **状态机**：`scope → survey → dev-N`。scope 对应绿地 clarify 的位置（把模糊调研目标挖成可验收问题清单）；survey 对应 plan 的位置（章节划分=dev 单元，信息源清单+时间盒）；dev-N = 每章一个调研执行单元。不复用 rework 的 archaeology/safety-net（那两个阶段的产出——行为锁定/安全网测试——对"不改代码"的任务无意义）。
- **git 语义与 rework 相反**：调研不硬依赖 git 历史——非 git 目录允许（落盘即交付）；git 仓库内则报告/探针照 commit 纪律（trailer `phase: dev-N` 沿用，scope/survey 期产物一并入报告目录）。
- **只读红线的机械信号**：`git diff --name-only` 文件集 ⊆ `--out` 报告目录，越界即 REFINE（复用 rework 范围比对的执行姿势，比对对象从"声明文件范围"换成"报告目录"）。
- **证据分级的抽查义务在监工**：A-C 级结论监工亲自复现关键证据（重跑命令/grep/打开链接）——延续"机械回放纪律，不只信 worker 摘要"；抽查发现一条伪证 → 整章 REFINE 重查（伪证不是局部问题，是整章可信度问题）。
- **`--out <报告目录>`缺省 `<project-dir>/docs/research/<日期-主题>/`**：与 walk-tracer 实践中 docs/rework/ 的先例一致。

## 5. 实施清单

- `commands/research.md`（模式层，51 行，dev-4 CR 修复后实测）：frontmatter + 模式声明（phase 枚举 `<scope|survey|dev-N>`、首阶段指令全文、registry `--mode research`、--out、非 git 允许、长阶段时限 120min）+ 前置阶段质询 + dev-N 特化（证据分级/抽查/对账/时间盒/章间新发现走 QUESTIONS）+ research 专属纪律（只读红线/未决显式化/报告结构/总结披露）；
- `install.sh`：头部注释 + `splice_command research.md` 一行；
- README：模式清单、调研章节、命令表；
- 拼接结构断言（frontmatter/必备节/无重复标题）对 research.md 同样生效，安装期自动把关。

## 6. 测试

install.sh 的拼接结构断言即本模式的安装期回归（断言失败中止安装不留半成品）；运行期行为由核心协议的既有测试面（hook/watchdog/registry 全绿）覆盖——模式层是纯 prompt 文本，无可执行面。
