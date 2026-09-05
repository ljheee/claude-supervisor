# Claude Code 定时任务机制实测记录

> 实测环境：macOS arm64 / Claude Code **2.1.259** / 2026-09-05
> 方法：二进制逆向 + tmux 交互会话对照实验（沙箱目录，已清理）
> 结论用途：claude-supervisor 监工套件的定时巡检设计依据

## 一、机制总览

自然语言描述创建定时任务、`/loop` 命令、最终都落到同一套工具：

| 工具 | 作用 |
|---|---|
| `CronCreate` | 创建定时任务（5 段 cron 表达式，本地时间） |
| `CronDelete` | 按 id 删除任务 |
| `CronList` | 列出当前可见任务 |
| `ScheduleWakeup` | 一次性唤醒（自续环机制，见 §五） |

**写不写 `.claude/scheduled_tasks.json` 只看 `durable` 参数，与创建方式无关。**

## 二、CronCreate 参数语义（实测确认）

| 参数 | 类型 | 默认 | 语义 |
|---|---|---|---|
| `cron` | string | 必填 | 标准 5 段 cron（分 时 日 月 周），本地时间 |
| `prompt` | string | 必填 | 每次触发时注入的 prompt |
| `recurring` | bool | true | true=循环；false=one-shot（下次匹配触发一次后自删） |
| `durable` | bool | false | **true=落盘 `.claude/scheduled_tasks.json` 且跨重启存活；false=纯内存，会话退出即死** |

工具 schema 原文：durable 只在用户明确要求任务跨会话存活时才置 true。

- session-only 过期时间：**7 天**（注意：腾讯云文章写 3 天，版本间已变过，勿硬编码）
- durable 落盘结构：

```json
{
  "tasks": [
    {
      "id": "da3d2dac",
      "cron": "*/5 * * * *",
      "prompt": "...",
      "createdAt": 1788576124007,
      "recurring": true,
      "createdBySessionId": "ba962b66-...",
      "createdByPid": 77297,
      "createdByProcStart": "Sat Sep  5 02:41:58 2026",
      "lastFiredAt": 1788576446041
    }
  ]
}
```

身份字段是 sessions 注册表同款三元组（sessionId/pid/procStart）。**创建者身份只做记录，不构成执行权**——执行权看 lock 文件（见 §四）。

## 三、任务作用域：目录级，非会话级（durable）

- durable 任务创建者退出后，同目录**新会话** CronList 可见、CronDelete 可删
- 同目录多会话并存时，任务只 fire 进**一个**会话（单一执行者）
- **执行者死亡后，同目录其他活着的交互会话立即抢锁接管**，并补跑错过的任务
- 接管补跑**不触发** AskUserQuestion（missed 询问只在会话启动时出现）

⚠️ 工程含义：worker 与 supervisor 同目录时，若 supervisor 用 durable cron，它死后 worker 会话可能接管执行巡检 prompt——prompt 会 fire 进 worker 上下文。要么用 session-only 绕开，要么把 prompt 写成角色无关的幂等指令。

## 四、单一执行者与 lock

`.claude/scheduled_tasks.lock` 内容：

```json
{"sessionId":"...","pid":14209,"procStart":"...","acquiredAt":1788576636939}
```

谁持锁谁是执行者；执行者死后锁被其他会话重新抢占（实测 kill 执行者后接管发生在秒级，不等下一个分钟边界）。

## 五、/loop 的两条路线（实测确认）

| 用法 | 底层机制 | 特性 |
|---|---|---|
| `/loop 1m <prompt>`（带间隔） | CronCreate 固定 cron | **默认 session-only 不落盘**；按固定间隔 tick |
| `/loop`（无间隔） | ScheduleWakeup 动态自续环 | 模型每环自己决定下环延迟；harness 自动 arm session-only one-shot 哨兵（prompt 为字面量 `<<autonomous-loop-dynamic>>`）接力续环；无固定 cron 行 |

/loop 特有纪律机制：

- **noop 折叠**：连续"无事可报"的 tick 在终端折叠成一行，省视觉噪音
- **自主熔断**：实测连续 3 个 noop 后模型自主调 `ScheduleWakeup(stop:true)` 停环，防无限空转烧 token

ScheduleWakeup 参数：`delaySeconds`（**被夹在 [60, 3600] 秒**，最短 1 分钟最长 1 小时）、`reason`、`prompt`（原样回传续环）、`stop`、`noop`。

## 六、missed 任务与执行语义

- **print 模式（`claude -p`）调度器完全不跑**：Cron 工具可用（能建能删），但不 fire、不检查 missed。cron 唤醒只对交互式会话有效
- 交互会话**启动时**发现 missed 的 one-shot → AskUserQuestion（Run it now / Skip），选 Run 执行后自删
- ⚠️ **one-shot 不保证恰好执行一次**（实测抓到重复执行）：missed 流程的执行不走调度器 fire 记账（json 无 lastFiredAt 痕迹），接管会话会认为"从未 fire 过"再执行一次。**one-shot prompt 必须写幂等**

## 七、触发时机（二进制证据，未直接观测）

调度器触发时**等当前回合结束才注入 prompt**，不打断进行中的回合——与被动守卫原则天然兼容。

## 八、对 claude-supervisor 的设计结论

1. **supervisor 定时巡检**：`/loop 10m <巡检指令>`（CronCreate 路线）；执行者永远只有 supervisor 自己
2. **退避唤醒改用 ScheduleWakeup**：收到 WORKER INTERRUPTED 后不再 `sleep 300`（Bash 默认 2 分钟超时坑 + 占用工具调用），改调 `ScheduleWakeup(delaySeconds=300, reason=..., prompt=...)` 原生唤醒，无超时坑
3. **巡检无事时输出一行**（配合 noop 语义），防上下文膨胀加速协议淡化
4. supervisor 宿主死亡 → session-only cron 同死，由外部 watchdog（第四层防线）兜底，职责边界不变
5. 协议中不硬编码过期天数等易变参数，让模型现场 CronList 核对

## 附：与既有防御层的关系

```
第一层  StopFailure hook        —— 中断瞬间的自动上报（不变）
第二层  协议层 STALLED/RESUME    —— worker 自见失败（不变）
第三层  supervisor 巡检          —— 被动唤醒 → /loop 定时醒来（本机制增强）
第四层  外部 cron watchdog       —— supervisor 死亡兜底（不可替代，不降级）
```
