# claude-supervisor

基于 Claude Code 跨会话消息（Cross-session messaging）的项目监工套件：一个 Supervisor 会话督促并审查 N 个 Worker 会话，把「需求澄清 → spec → plan → 逐 Phase 开发 → 总结」的全流程管起来，worker 中断（429/网络/进程死亡）也不会静默失联。

支持四种模式：
- **绿地模式**（`/supervisor`，从零开发新项目）。
- **rework 模式**（`/rework`，老项目修补/重构——考古基线 + 回归安全网 + 不改清单）.
- **research 模式**（`/research`，调研/探索任务——产出报告与证据而非代码改动）.
- **abstract 模式**（`/abstract`，抽象提炼——从一堆现成材料提炼支配它们的高层命题）。


## 安装

```bash
# 方式一：
git clone git@github.com:ljheee/claude-supervisor.git && cd claude-supervisor
bash install.sh

# 方式二：
curl -fsSL https://raw.githubusercontent.com/ljheee/claude-supervisor/install.sh | sh
```


安装内容：`/supervisor`、`/rework`、`/research`、`/abstract`、`/worker` 五个 slash 命令（→ `~/.claude/commands/`，其中 supervisor/rework/research/abstract 由「模式层 + `_core-supervisor.md` 核心协议」在安装期拼接生成）；四个 hook（→ `~/.claude/hooks/claude-supervisor/`，自动注册进 `~/.claude/settings.json` 用户级，幂等）——StopFailure（中断自动上报）、SessionStart（v3 身份注入器）、PreToolUse·Write|Edit（v3 分片守卫）、Stop（模型层异常捕获：model-error/空回合/尾部退化）；registry.py（→ `~/.agent-mail/registry.py`，v3 发现层助手，所有 registry.json 写操作经它）；watchdog 脚本（→ `~/.agent-mail/supervisor-watchdog`）。已有同名文件会先备份（`.bak-<时间戳>`）再覆盖；settings.json 损坏时备份后**中止安装**，不会重置你的配置；拼接产物过结构断言（关键节齐全/无重复标题），断言失败同样中止不留半成品。

版本要求：Claude Code >= 2.1.259（ListAgents + SendMessage + StopFailure hook + CronCreate/ScheduleWakeup 定时任务）。`claude --version` 确认。

## 快速开始（多终端）

```bash
# 终端A：项目目录，初始化监工（建议先 /rename supervisor 固定名字）
claude
> /rename supervisor
> /supervisor 做一个XXX功能

# 终端B：同一项目目录，注册工人
cd /path/to/repo && claude
> /worker

# 终端C、D...：可再开更多 worker，多 worker 并行受监工（各自 scope 隔离）
```

之后你只需要跟 supervisor 会话对话（进度询问、需求澄清的回答都在它终端）；worker 按指令干活、自 CR、上报。supervisor 靠 session_id 识别每个 worker（worker 注册时自报 + supervisor 扫描交叉验证，重名/改名不串扰），你不用管细节。

## 老项目修补/重构（rework 模式）

有存量代码要改？用 `/rework` 代替 `/supervisor`，同一姿势：

```bash
# 终端A：老项目目录（必须是 git 仓库）
claude
> /rework 修复XX模块的YY问题 --baseline <行为正常的commit>

# 终端B：同一项目目录
claude
> /worker
```

rework 模式的前置阶段是「考古与基线 → 回归安全网 → spec → plan」：先考古出架构地图、债务清单、bug-vs-feature 疑点（禁 worker 自行裁决，默认升级用户）、依赖暗网；再锁定当前行为的安全网测试（含待改行为——先锁现状，改造前后 diff 才可归因）；「不改清单」（frozen_behaviors）在安全网 APPROVE 时由你确认锁定，之后 worker 任何 commit 触碰即 REFINE。开发期有两条硬纪律：**范围比对**（每 phase 的 diff 文件集 ⊆ 声明范围，超出即 REFINE——顺手重构零容忍）与**单 phase = 一次可独立回滚的改动单元**。`--baseline` 缺省 HEAD。

注意：rework 模式要求项目是 git 仓库（考古硬依赖 git 历史，非 git 目录会直接 ESCALATE）。

## 调研/探索任务（research 模式）

产出是报告不是代码？用 `/research`，同一姿势：

```bash
# 终端A：任意目录（非 git 也行——调研不硬依赖历史）
claude
> /research 调研XX技术选型/事故根因/依赖现状 --out <报告目录>

# 终端B：同一目录
claude
> /worker
```

research 模式的前置阶段是「问题定义 → 调研方案」：先把模糊调研目标挖成**可验收的编号问题清单**（每问什么算回答了必须可判定）+ 明确的不回答边界，再审调研方案（每章对应哪些问题、信息源清单与优先级、时间盒）。调研执行期三道硬纪律：
- **证据五级分级**（A 一手实测/B 源码定位/C 官方文档/D 二手转述/E 显式推测——监工抽查复现 A-C 级关键证据，伪证一条整章重查）
- **产品代码只读红线**（探针与产物只落 `--out` 目录，默认 `docs/research/<日期-主题>/`；git diff 越出报告目录即 REFINE）
- **结论对账**（done 前逐问核对：要么有答案+置信度，要么显式标未决+原因——查不到必须写明查了什么卡在哪）。单章默认 90 分钟时间盒防无限展开。
git 仓库内报告照 commit 纪律，非 git 目录落盘即交付。

## 抽象提炼任务（abstract 模式）

一堆现成材料（几篇报告/文章、十几处零碎代码修改、口述背景）想提纲挈领提炼高层结构？用 `/abstract`：

```bash
# 终端A：材料所在目录（非 git 也行——输入常是文档目录/学城链接）
claude
> /abstract 从这批报告提炼当前系统的根因问题 / 从最近 30 个 commit 提炼共性 [--out <报告目录>]

# 终端B：同一目录
claude
> /worker
```

abstract 与 research 方向相反：research 是发散（从问题去世界找证据），abstract 是收敛（从材料找支配结构）——**证据在材料内，输入面锁死**（ingest 定稿后不得引入新材料，含联网/查库）。前置阶段是「材料盘点 → 命题草稿」：先把材料盘成可对账的清单（粒度约定：文档逐篇/commit 逐个/散 diff 逐 hunk 群）并逐件压缩+锚点，再审命题草稿。执行期三道硬纪律：
- **两件套验收**（覆盖对账——每件材料要么被命题解释要么显式反例；回指锚点——`材料内模式`命题锚点必填，`意图/归因推断`命题显式标注推断性质+推导链，防揣测当事实）
- **锚点抽查**（监工亲自打开锚点核对命题与材料相符，系统性造假整轮重提炼）
- **空话检查+缺席信号**（不可证伪的正确废话降级为观察；材料里反复缺席的东西必须进清单——只看“有什么”提炼不出“没什么”）。

监工还对抗**叙事强制**：一个叙事解释所有材料往往是最可疑的那个。每轮 refine 产出即上报、监工逐轮对抗审查，非逐章生产。报告默认 `docs/abstract/<日期-主题>/`。

## 你会看到什么流程

```
clarify（需求澄清，问题经 supervisor 汇总转达给你）
  → spec（worker 产出规格，supervisor 审查，REFINE 发编号问题清单）
  → plan（分 Phase 计划审查，APPROVE 时锁定 Phase 总数）
  → dev-1..N（每 Phase：worker 先自 CR → supervisor 补充 CR → APPROVE 推进）
  → done（supervisor 出项目总结：做了什么、质量结论、遗留风险）
```

（这是绿地的默认骨架；rework/research/abstract 模式会覆盖前置阶段与执行阶段枚举，见上文各模式章节。）

## worker 中断了会发生什么

| 中断类型 | 表现 |
|---|---|
| 429 / 网络错误 / API 错误掐断回合 | StopFailure hook 秒级自动上报，supervisor 用 `ScheduleWakeup` 原生延迟唤醒退避约 5 分钟（多 worker 错峰）后发消息唤醒 worker 从中断点继续；两次唤醒无回应则升级你 |
| worker 自己遇到环境卡点（工具失败、依赖坏） | worker 主动发 WORKER STALLED，supervisor 给替代方案或升级你 |
| 进程被杀 / 终端关闭 | hook 无法执行（执行主体已消失）——watchdog/巡检发现超时静默后升级你，附 session_id 和 `claude --resume` 恢复指引；恢复后 worker 发 WORKER RESUME 报到 |

中断流水落盘 `.supervisor/<sid>/interrupts.jsonl`（v3 分片路径，`<sid>` 是该 supervisor 的 session_id；旧平铺布局自动兼容），supervisor 处理后在同目录 `acknowledged.jsonl` 记账；两者差集 = 未处理中断，每次被唤醒自动补课（即使当时 supervisor 不在线也不会漏）。每 Phase 立即 commit 的纪律保证任何中断最多丢当前 Phase 未提交部分。

前提：项目 `.gitignore` 加 `.supervisor/`（supervisor 启动时会主动询问是否代为追加，用户点头即做——不会只提醒不跟进）。

## 定时自巡检（v2）

supervisor 启动时用 `CronCreate` 创建每 10 分钟的 session-only 巡检任务（不传 durable——durable 任务是目录级共享的，执行者死后会被同目录其他会话接管执行，巡检必须只属于 supervisor 自己）。每次 tick：CronList 自查（任务因自动过期消失则立即重建）→ 执行巡检三步（失联判定 / pending_check 结算 / 中断补课）→ worker 在场性检查（本方零 worker 且注册超 15 分钟 → 提醒用户去 worker 终端重试注册，防「worker 先查后注册 vs supervisor 晚注册」的互等死锁）→ 无事时只输出一行"巡检正常，无待办"（noop 纪律，防上下文膨胀加速协议淡化）。全部 worker 完成时 CronDelete 收尾。即使 cron 过期/失效，supervisor 被任何消息/用户输入唤醒时仍顺带执行同样的巡检（双保险）。机制实测依据见 `specs/2026-09-05-scheduled-supervision/claude_cron.md`。

另：worker 空闲时宿主的 notify_when_idle 通知会刷新其活性时钟（idle ≠ 完成，不作督促触发器——worker 协议本就是不干完里程碑不上报）。

## watchdog（可选，推荐）

supervisor 活着时每 10 分钟定时自巡检（v2）；但定时 cron 调度器寄生在 supervisor 宿主进程里，supervisor 死则巡检死。cron watchdog 补上「supervisor 进程死亡无人巡检」的盲区（v3.1 起还补上「supervisor 自身劣化/死亡无人发现」的盲区，见下）：

```bash
# 手动跑：项目目录 + 超时阈值（分钟，默认 60）
~/.agent-mail/supervisor-watchdog /path/to/repo 60

# cron 每 10 分钟巡检一次（正常路径无需手工配：supervisor 启动协议步骤 7b
# 自动注册/收尾自动移除。手工兜底务必用与 7b 完全相同的两行格式——标识行 +
# 条目行；否则 7b 查重 miss 产生重复条目、收尾移除也匹配不掉）
crontab -e
# supervisor-watchdog /path/to/repo
# */10 * * * * ~/.agent-mail/supervisor-watchdog '/path/to/repo' 60
```

发现逾期 worker 时按分片 supervisor 的 session_id 精确匹配 `~/.claude/sessions/` 后 UDS 直投 WATCHDOG ALERT（含 session_id 与恢复指引）并弹 macOS 通知——多 supervisor 并存时按 sid 路由不会串台（前提：supervisor 会话活着且可达；socket 不可达时该告警丢弃，watchdog 本就是第四层 best-effort）。告警自带梯度去重：静默每加深一个阈值才再告警一次（T、2T、3T…），不会刷屏；无逾期零输出。路径含空格时给 cron 行里的项目目录加引号。

**v3.1 supervisor 自检（第五层，盯 supervisor 本体）**：同一脚本以 `.supervisor/registry.json` 心跳判 supervisor 活性——心跳停更（心跳由 supervisor 每轮巡检顺带 `registry.py heartbeat` 刷新，停更即巡检链已死）且会话 socket 不存在 → **DEAD**，通知文本引导用户 `claude --resume <sid>` 唤醒；心跳停更但 socket 仍在 → **DEGRADED**（疑似模型劣化，同 09-07 事故形态），通知用户人工介入。通知直投用户（osascript 桌面通知）而非 supervisor——病人不能给自己叫医生。自检在零 worker 分片上同样生效，去重与 worker 梯度共用 `watchdog_state.json`（key `supervisor:<sid>`，心跳前移即梯度重置）。零 worker 也可检：自检在 worker overdue 判定之前，不受「零 worker 时跳过循环尾部」影响。已知边界：心跳只在巡检时刷新、巡检 cron tick 要等当前回合结束才注入——supervisor 陷在一个超过阈值的**长回合**（深度 CR、自己跑全量测试）时会产生一次假 DEGRADED（梯度去重保证只此一次、不刷屏），可忽略。

## 命令

- `/supervisor <目标> [--project-dir DIR]`：绿地开发模式监工（前置阶段 clarify→spec→plan）。
- `/rework <改造目标> [--project-dir DIR] [--baseline <git-ref>]`：老项目修补/重构模式监工（前置阶段 archaeology→safety-net→spec→plan，含不改清单与顺手重构红线）。
- `/research <调研目标> [--project-dir DIR] [--out <报告目录>]`：调研/探索模式监工（前置阶段 scope→survey，每章一个 dev 单元；证据五级分级 + 产品代码只读红线 + 结论对账，非 git 目录可用）。
- `/abstract <提炼目标与材料来源> [--project-dir DIR] [--out <报告目录>]`：抽象提炼模式监工（前置阶段 ingest→distill，refine-N 对抗返工；覆盖对账 + 回指锚点 + 锚点抽查 + 空话检查，输入面锁死，非 git 目录可用）。
- `/worker [--supervisor <会话名>]`：把当前会话注册成受监工的工人（模式无关）。已含上报协议与中断恢复协议。`--supervisor` 接受**会话名称**（SendMessage 唯一可用寻址键；无此参数时 worker 自动读 `.supervisor/registry.json` 选监工——唯一活跃条目直接选，多条目列出来请你指定）。

四模式共享同一份核心协议（身份/五层中断防御/账本/OODA/三层回答防火墙），由 install.sh 在安装期拼接进各自命令。

## 多 supervisor 并存（v3）

同一项目可同时跑多个监工（典型场景：`/supervisor` 开新模块 + `/rework` 改存量并行）。隔离靠三件事：

- **唯一会话名**：每个监工用 `/rename` 固定唯一名（建议 `supervisor-<模式或项目后缀>`，如 `supervisor-gf` / `supervisor-rw`；跨项目同名 supervisor 无法被 SendMessage 消歧，命名含项目后缀更稳）。名字是消息路由键，撞名会串台。
- **各自分支/worktree**：多 supervisor 同仓并行是硬性要求——各队伍在不同分支或 linked worktree 上工作（协议启动时强制隔离确认）；同分支混行提交不支持，冲突升级用户裁决。
- **账本分片**：每轮任务的账本在 `.supervisor/<supervisor 的 session_id>/` 下（state.json / interrupts.jsonl / acknowledged.jsonl），互不可见；发现层在 `.supervisor/registry.json`（registry.py 维护，worker 启动时只读它选监工）。新任务即新分片，旧账自动成为只读存档。

旧平铺布局（v2/rework 的 `.supervisor/state.json`）在 v3 supervisor 启动时会被识别并引导归档到 `.supervisor/archive/`（归档目录对 hook/watchdog 不可见，不会被误当活分片）。

监工意外死亡时 registry 里会留下死条目：worker 向它注册失败时会把三选项清单报给你（resume 该监工 / 稍后重试 / 转自主模式单干）；stale 判定双条件（不可达且心跳超 30 分钟）只标记不删他人条目。

## 常见问题

- **绿地/重构拿不准用哪个**：有存量代码要改就用 `/rework`（考古+安全网前置）；从零开始用 `/supervisor`；产出是报告不是代码用 `/research`（问题定义+证据分级，不改产品代码）；一堆现成材料要提炼高层结构用 `/abstract`（覆盖对账+锚点抽查，输入面锁死）。
- **worker 找不到 supervisor**：supervisor 终端执行 `/rename supervisor` 固定名字后 worker 重试；同时确认两边在预期目录。
- **supervisor 行为漂移**（长会话被压缩后协议淡化）：重新执行对应模式的命令（`/supervisor`、`/rework`、`/research`、`/abstract`）重注入协议，state.json 会恢复全部上下文。
- **监工不是 100% 可靠（已知边界）**：监工人格来自 prompt 注入，遵循度无法确保。本套件的对冲：中断检测的触发（hook/watchdog）是硬代码不依赖监工自觉；进度全在 state.json 里，漂移可重注入恢复；软失效（漏巡检等）的后果被硬兜底层限制为"晚发现"而非"不发现"。详见 DESIGN.md 第 9 节。
- **怀疑 hook 没生效**：跑 `bash test_stopfailure.sh`、`bash test_watchdog.sh` 和 `bash test_registry.sh` 回归（断言型沙箱测试，不碰真实数据）；真实中断后查 `.supervisor/<sid>/interrupts.jsonl`（`<sid>` 是该 supervisor 的 session_id；旧平铺布局在 `.supervisor/interrupts.jsonl`）有无新条目。
- **想跨 Codex 用**：本套件的消息通道是 Claude↔Claude 官方机制；Codex worker 可改用 agent-mail 桥上报（两套件互补）。

## 卸载

```bash
rm ~/.claude/commands/supervisor.md ~/.claude/commands/rework.md ~/.claude/commands/research.md ~/.claude/commands/abstract.md ~/.claude/commands/worker.md
rm -rf ~/.claude/hooks/claude-supervisor
rm ~/.agent-mail/supervisor-watchdog ~/.agent-mail/registry.py
# 并从 ~/.claude/settings.json 的 hooks.StopFailure / hooks.SessionStart /
# hooks.PreToolUse / hooks.Stop 数组中删掉对应条目
```

## 文件清单

| 文件 | 用途 |
|---|---|
| `commands/_core-supervisor.md` | 核心协议片段（拼接原料，不单独安装） |
| `commands/supervisor.md` | /supervisor 绿地模式层（安装期与 core 拼接） |
| `commands/rework.md` | /rework 重构模式层（安装期与 core 拼接） |
| `commands/research.md` | /research 调研模式层（安装期与 core 拼接） |
| `commands/abstract.md` | /abstract 抽象提炼模式层（安装期与 core 拼接） |
| `commands/worker.md` | /worker 命令（工人协议，v3 含 registry 发现/自报 sid） |
| `hooks/worker-stopfailure.py` | StopFailure hook（中断自动上报，v3 多分片解析） |
| `hooks/stop-anomaly-capture.py` | Stop hook（模型层异常捕获：model-error / 空回合 / 尾部退化判据，分级投递，见 stop-anomaly.md；事故 transcript replay 实证零误报） |
| `hooks/session-start-injector.py` | SessionStart hook（会话身份注入，v3） |
| `hooks/shard-guard.py` | PreToolUse hook（分片写入守卫，v3） |
| `hooks/registry.py` | 发现层助手（registry.json 的 fcntl 互斥写，v3，安装到 ~/.agent-mail） |
| `watchdog.sh` | 外部逾期巡检脚本（v3 分片遍历 + UDS 直投） |
| `test_stopfailure.sh` | hook 回归测试（v3 扩展，83 项断言，含 stop-anomaly-capture case 22-29） |
| `test_watchdog.sh` | watchdog 回归测试（v3.1 扩展，50 项断言，含 supervisor 自检 Q/R/S/T/U） |
| `test_registry.sh` | registry.py 回归测试（v3，29 项断言） |
| `specs/2026-09-05-rework-mode/` | rework 模式 spec/plan |
| `specs/2026-09-05-scheduled-supervision/` | v2 spec/plan + 定时任务机制实测记录（claude_cron.md） |
| `specs/2026-09-06-multi-supervisor/` | v3 spec/plan（多 supervisor 并存） |
| `specs/2026-09-09-research-mode/` | research 模式 spec/plan（含双路 CR 记录） |
| `specs/2026-09-10-abstract-mode/` | abstract 模式 spec/plan（含 CR 记录） |
| `install.sh` | 安装 |
| `DESIGN.md` | 设计原理 |

