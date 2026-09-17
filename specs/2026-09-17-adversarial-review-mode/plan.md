# Plan: 对抗审查模式（/adversarial）

- 状态：plan 待审（2026-09-17）
- 分支：feat/adversarial-review-mode
- 依据：spec.md（0b3807a，三轮半 CR 定稿）
- 结构模板：commands/abstract.md（模式层最相近先例：非代码产出、非 git 允许、worker-facing 下发清单、落点纪律）

## 改动文件总览

| 文件 | 动作 | 预估行数 |
|---|---|---|
| commands/adversarial.md | 新建（模式层） | ~95 |
| install.sh | 修改 4 处 | +5/-1 |
| README.md / README-zh.md | 修改 4+2 处（双语）+ 模式专章一节 | ~35 行/语言 |
| specs/2026-09-17-adversarial-review-mode/ | 不动（本 plan 落此目录） | — |

零改动文件：commands/worker.md、commands/_core-supervisor.md、hooks/*（registry.py 收任意 mode 字符串）、watchdog.sh、test_*.sh。

## 一、commands/adversarial.md（模式层，核心交付物）

按 abstract.md 的既定结构组织（frontmatter → 模式声明 → 前置阶段 → 执行特化 → 专属纪律），内容映射 spec §2-§5：

### 1.1 frontmatter

```
description: 将当前会话初始化为对抗审查监工 Supervisor（多视角独立审 → 匿名交叉攻击 → 收敛报告）
argument-hint: <被审对象与审查目标> [--project-dir DIR] [--out <报告目录>]
```

### 1.2 模式声明节（## 模式声明（adversarial 对抗审查模式））

六条，对应 spec §3：

1. 模式定位（输入=PR diff/方案文档/调研报告等已有产出，输出=收敛审查报告，非代码改动）。执行阶段语义覆盖 core 的 dev-N 骨架（无 total_phases，覆盖即完整裁定）——**phase 归属声明**：supervisor 侧 `ingest|assign|merge` 不占 workers[].phase，worker 侧 `round1 → cross-1 →（必要时）cross-2 → done` per-worker 流转。
2. **core 启动步骤 8 的模式层覆盖**：收到 WORKER REGISTER 照常登记（校验+写 workers[]），初始指令暂缓——assign 定稿后按视角分配表补发，**补发时 worker 的 phase 直接置 `round1`**（不走 core 默认的 dev-1/前置首阶段语义；上报 Phase 字段填 round1/cross-1 实际值，同 abstract 对 WORKER REPORT 模板 Phase 字段的覆盖方式）。此条必须显式写明（防无视角指令先发出去）。
3. registry 注册 `--mode adversarial`。
4. `--out` 落点纪律（同 abstract 第 16 行）：显式传参启动即校验父链，缺省启动只校验 `docs/adversarial/` 可创建，完整路径 assign 定题后随初始指令下发。
5. **worker-facing 五项统一下发**（worker 读不到模式层，对齐 abstract 五项下发清单）：①视角 scope（审查清单+排除项）；②round1 纪律（findings 只在消息体内上报、每条含观点+锚点+置信+证伪判据）；③cross 纪律（匿名并集逐条三态回应、允许新增、不得揣测对手身份）；④时限约定（大 PR 建议 120 分钟，覆盖 core 默认 60 分钟）与超时中间上报义务；⑤**审查零 commit 纪律**（审查是只读任务，被审仓库内 worker 零 commit、零落盘——与 abstract 相反的显式差异；报告由监工在 merge 后统一落盘 --out，worker 不碰 git，自然无 trailer/rename 窗口问题）。
6. **中断对齐锚**（round1 产出在消息体不落盘，worker 崩溃恢复需替代锚）：初始指令下发时与 worker 显式约定——崩在 round1 中间，resume 唤醒后以**监工分片已登记的 findings 清单**为断点（监工下发 cross-1 时把该 worker 已收到的 findings 原样回显），重干未上报部分、不重干已登记部分；监工崩了同样以分片重建状态。worker 无法自查分片，断点真值在监工侧。
7. 两个汇合点声明（core「该 phase 明确需要汇合」例外条款的适用者）：① round1 全员收齐→监工建匿名并集→统一下发 cross-1；② cross-1 回应全员收齐→判争议，有未收敛争议项才发 cross-2。

### 1.3 前置阶段节（## 前置阶段（adversarial））

**supervisor 侧 ingest**（监工亲自做，无 worker 参与）：解析被审对象（PR→`git diff <base>..head`+涉及文件清单+关联上下文；文档→清单+逐件锚点；口述+文件混合→逐件盘点）。质询上限两轮：模糊审查目标拆可判定、盘点遗漏挖掘、「审完拿报告做什么决策」反问。**被审对象定稿即锁死**（diff 版本/文档清单不得中途换，材料一改锚点全失效）。

**supervisor 侧 assign**：视角菜单+决策表+备选区（spec §4 全量：每条候选=视角名+审查清单+排除项+入选理由；备选区一句话理由；用户指定视角标注且不得删并、可超推荐值；裁决通过即定稿锁定）。降级判定在此：单视角（材料小/用户只点一个）→ 走单 worker 多视角路径，报告标「未隔离审查」。

### 1.4 执行特化节（## round1/cross 特化（adversarial））

**round1 审查你必做**（命令式）：登记 findings 入自己的分片（`.supervisor/<你的sid>/`，防 worker 落盘共享路径）；无锚点 finding 退回补（两次不补撤回该条）；证据分级复用 research A-E（finding 自标级别）；空话检查复用 abstract（逐条自问「证伪会看到什么」）。

**cross-1 收齐后你必做**：建匿名并集（去视角署名，防权威跟随；N=2 时匿名化如实标注为形式统一）；下发时序监控（先行者已停等，失联时限用四项下发的 ④ 约定值）；cross-1 回应收齐后按三态+混合多数/少数判争议（多数确认+少数反驳=一致带附注；反驳附反证锚点且多数未回应=进争议项）。

**merge 你必做**：锚点抽查复用 abstract 纪律（打开核对 finding 与被审对象相符，锚点指向不存在/内容不符即撤回该 finding，系统性造假→该视角全部 findings 撤回整轮重审——spec 声明的比 research 更强的新增增强）；覆盖对账（材料×视角矩阵）；Loop Guard（cross 最多 2 轮，仍僵持标「用户裁决项」止）；减员处理（剩余 ≥2 路继续、缺方标「因减员未交叉」；<2 路降级单路汇总标「对抗结构未成立」）。

### 1.5 专属纪律节（## adversarial 专属纪律）

- 单 worker 降级路径：phase 为 `round1|done`，单上下文按视角清单逐个扫，报告标「未隔离审查」。
- round1 后新增视角诉求：单路补充审查独立跑，单独成节，不入三态。
- 报告五节结构：TL;DR（确认发现按严重度）/ 争议项（各方论点+锚点并列）/ 撤回记录 / 覆盖对账（材料×视角矩阵）/ 视角清单（含用户指定/移除/备选转正标注）。
- 总结报告披露：匿名化边界（含 N=2 装饰性）、隔离残余边界（worker 可读监工分片但无激励）、锚点抽查结果、Loop Guard 触发情况。

### 1.5+ 尾部

`---`（分隔线，拼接时 core 跟在后面——同 abstract 尾行）。

## 二、install.sh（4 处）

1. `:142` 后加一行：`splice_command "$SRC/commands/adversarial.md" "$DEST/adversarial.md"`
2. `:16` 模式清单注释加 `/adversarial` 一行。
3. `:312` 附近安装完成 echo 块加 adversarial 用法行。
4. `:317` 流程 echo 行加「adversarial 模式为 多视角独立审→匿名交叉攻击→收敛报告」。

断言零改动：splice_command 的结构断言（frontmatter 闭合/core 必含节/无重复 ## 标题）对第五个模式层同样生效，adversarial.md 的标题设计避开与 core 重复的 ## 即可（1.2-1.5 的节名均带（adversarial）后缀，无碰撞）。

## 三、README.md / README-zh.md（4+2 处/语言）

1. 模式清单（:14-19 附近）：加第五模式 bullet（对抗审查——审 PR/方案/报告，多视角对抗收敛）。
2. 命令表（:160-168 / zh:152 附近）：加 `/adversarial <被审对象> [--project-dir DIR] [--out <报告目录>]` 行。
3. FAQ 决策树（:184 / zh:174+）：加「审已有产出（PR/方案/调研报告）→ /adversarial」分支。
4. 文件清单（Repository Layout :203+ / zh:194+）：four mode layers → five mode layers。
5. 英文版 Uninstall（:192+）：命令清单加 `adversarial.md`；中文版对应节同步。
6. 模式专章：README 现有四模式各有专章（rework/research/abstract 各一节）——adversarial 加一节（两轮结构一段+用法示例代码块+worker 数决策表精简版），双语，~35 行/语言。顺手修：README-zh:100 残留的旧术语「学城链接」（前次清理漏网，改「文档链接」）。

## 四、测试与验收

无新自动化测试（模式层是 prompt 协议文本，三套既有回归测试 registry/stopfailure/watchdog 不覆盖模式层内容，本模式无 hooks/代码改动故零回归风险）；验收按 spec DoD 执行：

1. **拼接过断言**：`bash install.sh` 全装一遍，确认 adversarial.md 拼接产物过三个结构断言（frontmatter/core 必含节/无重复标题），`~/.claude/commands/adversarial.md` 内容完整（模式层+core 全量）。
2. **真机冒烟（主验收）**：本仓真实 merge commit 跑全链路，2 路视角（架构+唱反调）。冒烟对象候选：v3 merge `6e3bfc8` 为 5132 行插入，按决策表属 4-6 路量级——冒烟用它是为了验证协议全链路而非规模适配，2 路由用户在 assign 裁决时明确选定（走「用户裁决可超/低于推荐值」路径，同时验证该裁决机制）；或换一个中型 commit（300-2000 行）让推荐值与 2 路自洽。核验五点：round1 两路 findings 零互相引用痕迹（隔离生效）；cross-1 三态回应覆盖；锚点抽查执行记录（监工亲开锚点）；报告五节齐全；Phase 字段上报 round1/cross-1 实际值。
3. **降级路径冒烟**：小 diff（<300 行）单 worker 多视角跑通，报告含「未隔离审查」标注。
4. **N≥3 语义**：桌面演练（构造 3 路视角的人工推演文档）验证并集下发与混合多数/少数判据，条件不允许则报告如实标注未验证。
5. 三套既有回归测试全绿（零回归确认）。
6. README 双语四+2 处自查（grep adversarial 逐处命中）。

## 五、实施顺序

1. commands/adversarial.md（模式层全文，按 1.2-1.5 节映射）
2. install.sh 4 处
3. 本地 `bash install.sh` + 断言验证（DoD-1）
4. 真机冒烟 2 路（DoD-2，主验收）+ 降级路径（DoD-3）
5. README 双语 6 处
6. 三套回归 + 收尾 commit

风险预留：冒烟若发现协议漏洞（如 cross 汇合时序在真机不可靠），修 spec 优先于改实现（spec 是行为契约），修完同步模式层。

## 六、明确不做

- registry/watchdog/shard-guard 改动（registry.py 收任意 mode 字符串，无需改）
- worker.md 改动（worker 协议零改动，视角走 workers[].scope）
- 历史数据增强推荐（v2，spec §4 已标）
- PR 未合并场景的 fetch ref 检出（spec §7 开放问题，实施期真机冒烟用本地 merge commit，不碰未合并 PR）
