# claude-supervisor

基于 Claude Code 跨会话消息（Cross-session messaging）的项目监工套件：一个 Supervisor 会话督促并审查 N 个 Worker 会话，把「需求澄清 → spec → plan → 逐 Phase 开发 → 总结」的全流程管起来，worker 中断（429/网络/进程死亡）也不会静默失联。

支持两种模式：**绿地模式**（`/supervisor`，从零开发新项目）与 **rework 模式**（`/rework`，老项目修补/重构——考古基线 + 回归安全网 + 不改清单）。

设计原理、逆向依据、中断模型 → 见 [DESIGN.md](DESIGN.md)。本文只讲怎么用。

## 安装

```bash
bash install.sh
```

安装内容：`/supervisor`、`/rework`、`/worker` 三个 slash 命令（→ `~/.claude/commands/`，其中 supervisor/rework 由「模式层 + `_core-supervisor.md` 核心协议」在安装期拼接生成）；StopFailure hook（→ `~/.claude/hooks/claude-supervisor/`，自动注册进 `~/.claude/settings.json`，幂等）；watchdog 脚本（→ `~/.agent-mail/supervisor-watchdog`）。已有同名文件会先备份（`.bak-<时间戳>`）再覆盖；settings.json 损坏时备份后**中止安装**，不会重置你的配置；拼接产物过结构断言（关键节齐全/无重复标题），断言失败同样中止不留半成品。

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

之后你只需要跟 supervisor 会话对话（进度询问、需求澄清的回答都在它终端）；worker 按指令干活、自 CR、上报。supervisor 靠 session_id 识别每个 worker（注册时自动解析，重名/改名不串扰），你不用管细节。

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

## 你会看到什么流程

```
clarify（需求澄清，问题经 supervisor 汇总转达给你）
  → spec（worker 产出规格，supervisor 审查，REFINE 发编号问题清单）
  → plan（分 Phase 计划审查，APPROVE 时锁定 Phase 总数）
  → dev-1..N（每 Phase：worker 先自 CR → supervisor 补充 CR → APPROVE 推进）
  → done（supervisor 出项目总结：做了什么、质量结论、遗留风险）
```

## worker 中断了会发生什么

| 中断类型 | 表现 |
|---|---|
| 429 / 网络错误 / API 错误掐断回合 | StopFailure hook 秒级自动上报，supervisor 用 `ScheduleWakeup` 原生延迟唤醒退避约 5 分钟（多 worker 错峰）后发消息唤醒 worker 从中断点继续；两次唤醒无回应则升级你 |
| worker 自己遇到环境卡点（工具失败、依赖坏） | worker 主动发 WORKER STALLED，supervisor 给替代方案或升级你 |
| 进程被杀 / 终端关闭 | hook 无法执行（执行主体已消失）——watchdog/巡检发现超时静默后升级你，附 session_id 和 `claude --resume` 恢复指引；恢复后 worker 发 WORKER RESUME 报到 |

中断流水落盘 `.supervisor/interrupts.jsonl`，supervisor 处理后在 `.supervisor/acknowledged.jsonl` 记账；两者差集 = 未处理中断，每次被唤醒自动补课（即使当时 supervisor 不在线也不会漏）。每 Phase 立即 commit 的纪律保证任何中断最多丢当前 Phase 未提交部分。

前提：项目 `.gitignore` 加 `.supervisor/`（supervisor 启动时也会提醒）。

## 定时自巡检（v2）

supervisor 启动时用 `CronCreate` 创建每 10 分钟的 session-only 巡检任务（不传 durable——durable 任务是目录级共享的，执行者死后会被同目录其他会话接管执行，巡检必须只属于 supervisor 自己）。每次 tick：CronList 自查（任务因自动过期消失则立即重建）→ 执行巡检三步（失联判定 / pending_check 结算 / 中断补课）→ 无事时只输出一行"巡检正常，无待办"（noop 纪律，防上下文膨胀加速协议淡化）。全部 worker 完成时 CronDelete 收尾。即使 cron 过期/失效，supervisor 被任何消息/用户输入唤醒时仍顺带执行同样的巡检（双保险）。机制实测依据见 `specs/2026-09-05-scheduled-supervision/claude_cron.md`。

另：worker 空闲时宿主的 notify_when_idle 通知会刷新其活性时钟（idle ≠ 完成，不作督促触发器——worker 协议本就是不干完里程碑不上报）。

## watchdog（可选，推荐）

supervisor 活着时每 10 分钟定时自巡检（v2）；但定时 cron 调度器寄生在 supervisor 宿主进程里，supervisor 死则巡检死。cron watchdog 补上「supervisor 进程死亡无人巡检」的盲区：

```bash
# 手动跑：项目目录 + 超时阈值（分钟，默认 60）
~/.agent-mail/supervisor-watchdog /path/to/repo 60

# cron 每 10 分钟巡检一次
crontab -e
# */10 * * * * ~/.agent-mail/supervisor-watchdog /path/to/repo 60
```

发现逾期 worker 时通过 agent-mail 向 supervisor 投递 WATCHDOG ALERT（含 session_id 与恢复指引）并弹 macOS 通知（前提：supervisor 在 agent-mail 注册过，即 `/supervisor` 启动过的机器上装了 agent-mail）。告警自带梯度去重：静默每加深一个阈值才再告警一次（T、2T、3T…），不会刷屏；无逾期零输出。路径含空格时给 cron 行里的项目目录加引号。

## 命令

- `/supervisor <目标> [--project-dir DIR]`：绿地开发模式监工（前置阶段 clarify→spec→plan）。
- `/rework <改造目标> [--project-dir DIR] [--baseline <git-ref>]`：老项目修补/重构模式监工（前置阶段 archaeology→safety-net→spec→plan，含不改清单与顺手重构红线）。
- `/worker [--supervisor NAME]`：把当前会话注册成受监工的工人（模式无关）。已含上报协议与中断恢复协议。

两模式共享同一份核心协议（身份/四层中断防御/账本/OODA/三层回答防火墙），由 install.sh 在安装期拼接进各自命令。

## 常见问题

- **绿地/重构拿不准用哪个**：有存量代码要改就用 `/rework`（考古+安全网前置）；从零开始用 `/supervisor`。
- **worker 找不到 supervisor**：supervisor 终端执行 `/rename supervisor` 固定名字后 worker 重试；同时确认两边在预期目录。
- **supervisor 行为漂移**（长会话被压缩后协议淡化）：重新执行 `/supervisor <目标>` 重注入协议，state.json 会恢复全部上下文。
- **监工不是 100% 可靠（已知边界）**：监工人格来自 prompt 注入，遵循度无法确保。本套件的对冲：中断检测的触发（hook/watchdog）是硬代码不依赖监工自觉；进度全在 state.json 里，漂移可重注入恢复；软失效（漏巡检等）的后果被硬兜底层限制为"晚发现"而非"不发现"。详见 DESIGN.md 第 9 节。
- **怀疑 hook 没生效**：跑 `bash test_stopfailure.sh` 和 `bash test_watchdog.sh` 回归（断言型沙箱测试，不碰真实数据）；真实中断后查 `.supervisor/interrupts.jsonl` 有无新条目。
- **想跨 Codex 用**：本套件的消息通道是 Claude↔Claude 官方机制；Codex worker 可改用 agent-mail 桥上报（两套件互补）。

## 卸载

```bash
rm ~/.claude/commands/supervisor.md ~/.claude/commands/rework.md ~/.claude/commands/worker.md
rm -rf ~/.claude/hooks/claude-supervisor
rm ~/.agent-mail/supervisor-watchdog
# 并从 ~/.claude/settings.json 的 hooks.StopFailure 数组中删掉对应条目
```

## 文件清单

| 文件 | 用途 |
|---|---|
| `commands/_core-supervisor.md` | 核心协议片段（拼接原料，不单独安装） |
| `commands/supervisor.md` | /supervisor 绿地模式层（安装期与 core 拼接） |
| `commands/rework.md` | /rework 重构模式层（安装期与 core 拼接） |
| `commands/worker.md` | /worker 命令（工人协议） |
| `hooks/worker-stopfailure.py` | StopFailure hook（中断自动上报） |
| `watchdog.sh` | 外部逾期巡检脚本 |
| `test_stopfailure.sh` | hook 回归测试（22 项断言） |
| `test_watchdog.sh` | watchdog 回归测试（15 项断言） |
| `specs/2026-09-05-scheduled-supervision/` | v2 spec/plan + 定时任务机制实测记录（claude_cron.md） |
| `install.sh` | 安装 |
| `DESIGN.md` | 技术设计原理 |
