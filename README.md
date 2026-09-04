# claude-supervisor

基于 Claude Code 跨会话消息（Cross-session messaging）的项目监工套件：一个 Supervisor 会话督促并审查 N 个 Worker 会话，把「需求澄清 → spec → plan → 逐 Phase 开发 → 总结」的全流程管起来，worker 中断（429/网络/进程死亡）也不会静默失联。

设计原理、逆向依据、中断模型 → 见 [DESIGN.md](DESIGN.md)。本文只讲怎么用。

## 安装

```bash
bash install.sh
```

安装内容：`/supervisor`、`/worker` 两个 slash 命令（→ `~/.claude/commands/`）；StopFailure hook（→ `~/.claude/hooks/claude-supervisor/`，自动注册进 `~/.claude/settings.json`，幂等）；watchdog 脚本（→ `~/.agent-mail/supervisor-watchdog`）。已有同名文件会先备份（`.bak-<时间戳>`）再覆盖；settings.json 损坏时备份后**中止安装**，不会重置你的配置。

版本要求：Claude Code >= 2.1.224（ListAgents + SendMessage）；StopFailure hook 需 >= 2.1.259。`claude --version` 确认。

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
| 429 / 网络错误 / API 错误掐断回合 | StopFailure hook 秒级自动上报，supervisor 退避约 5 分钟（多 worker 错峰）后发消息唤醒 worker 从中断点继续；两次唤醒无回应则升级你 |
| worker 自己遇到环境卡点（工具失败、依赖坏） | worker 主动发 WORKER STALLED，supervisor 给替代方案或升级你 |
| 进程被杀 / 终端关闭 | hook 无法执行（执行主体已消失）——watchdog/巡检发现超时静默后升级你，附 session_id 和 `claude --resume` 恢复指引；恢复后 worker 发 WORKER RESUME 报到 |

中断流水落盘 `.supervisor/interrupts.jsonl`，supervisor 处理后在 `.supervisor/acknowledged.jsonl` 记账；两者差集 = 未处理中断，每次被唤醒自动补课（即使当时 supervisor 不在线也不会漏）。每 Phase 立即 commit 的纪律保证任何中断最多丢当前 Phase 未提交部分。

前提：项目 `.gitignore` 加 `.supervisor/`（supervisor 启动时也会提醒）。

## watchdog（可选，推荐）

supervisor 只在被消息/输入唤醒时巡检；cron watchdog 补上「长时间无人唤醒」的盲区：

```bash
# 手动跑：项目目录 + 超时阈值（分钟，默认 60）
~/.agent-mail/supervisor-watchdog /path/to/repo 60

# cron 每 10 分钟巡检一次
crontab -e
# */10 * * * * ~/.agent-mail/supervisor-watchdog /path/to/repo 60
```

发现逾期 worker 时通过 agent-mail 向 supervisor 投递 WATCHDOG ALERT（含 session_id 与恢复指引）并弹 macOS 通知（前提：supervisor 在 agent-mail 注册过，即 `/supervisor` 启动过的机器上装了 agent-mail）。告警自带梯度去重：静默每加深一个阈值才再告警一次（T、2T、3T…），不会刷屏；无逾期零输出。路径含空格时给 cron 行里的项目目录加引号。

## 命令

- `/supervisor <目标> [--project-dir DIR]`：把当前会话变成监工。已含完整协议（OODA、状态机、四层中断防御）。
- `/worker [--supervisor NAME]`：把当前会话注册成受监工的工人。已含上报协议与中断恢复协议。

## 常见问题

- **worker 找不到 supervisor**：supervisor 终端执行 `/rename supervisor` 固定名字后 worker 重试；同时确认两边在预期目录。
- **supervisor 行为漂移**（长会话被压缩后协议淡化）：重新执行 `/supervisor <目标>` 重注入协议，state.json 会恢复全部上下文。
- **怀疑 hook 没生效**：跑 `bash test_stopfailure.sh` 和 `bash test_watchdog.sh` 回归（断言型沙箱测试，不碰真实数据）；真实中断后查 `.supervisor/interrupts.jsonl` 有无新条目。
- **想跨 Codex 用**：本套件的消息通道是 Claude↔Claude 官方机制；Codex worker 可改用 agent-mail 桥上报（两套件互补）。

## 卸载

```bash
rm ~/.claude/commands/supervisor.md ~/.claude/commands/worker.md
rm -rf ~/.claude/hooks/claude-supervisor
rm ~/.agent-mail/supervisor-watchdog
# 并从 ~/.claude/settings.json 的 hooks.StopFailure 数组中删掉对应条目
```

## 文件清单

| 文件 | 用途 |
|---|---|
| `commands/supervisor.md` | /supervisor 命令（监工协议） |
| `commands/worker.md` | /worker 命令（工人协议） |
| `hooks/worker-stopfailure.py` | StopFailure hook（中断自动上报） |
| `watchdog.sh` | 外部逾期巡检脚本 |
| `test_stopfailure.sh` | hook 回归测试（22 项断言） |
| `test_watchdog.sh` | watchdog 回归测试（15 项断言） |
| `install.sh` | 安装 |
| `DESIGN.md` | 技术设计原理 |
