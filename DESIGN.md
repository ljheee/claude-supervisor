# claude-supervisor 技术设计原理

本文档记录 claude-supervisor 的设计依据、逆向考古结论、中断模型与各机制的原理。使用方法见 [README.md](README.md)。

## 1. 问题定义

Claude Code 的多个会话之间天然隔离：任务要点、进度、context 各自为政。当用户用多个会话并行推进同一个项目时，缺少三样东西：

1. **全局视角**——谁在干什么、进行到哪；
2. **督促与审查**——worker 产出后有人把关，而不是干完才发现方向错；
3. **故障韧性**——worker 因限流/网络/进程问题中断后，项目不会无限期静默死亡。

claude-supervisor 用一个专门的 Supervisor 会话 + 官方跨会话消息机制 + 状态账本解决前两条，用四层防御解决第三条。

## 2. 底层能力考古（逆向 2.1.259 二进制所得）

本节是设计的事实依据，均来自对 `~/.local/share/claude/versions/2.1.259`（191MB Mach-O）的 strings/上下文逆向，**官方无文档，升级版本后需重新验证**。

### 2.1 会话注册表与凭据发布

`~/.claude/sessions/<pid>.json` 是运行中会话的注册表，关键字段：

```json
{
  "pid": 80446,
  "sessionId": "169ac824-...",
  "cwd": "/path/to/project",
  "name": "supervisor",           // /rename 固定，或自动派生
  "messagingSocketPath": "/tmp/cc-socks/80446.sock",  // UDS 消息通道
  "peerProtocol": 1,
  "peerFeatures": ["notify_idle", "reply_across_default_dirs", "artifact_yield"],
  "procStart": "Fri Sep  4 15:18:49 2026"
}
```

同目录的 `<pid>.<hash>.key` 是官方"发布"的入站凭据：

```json
{"peerToken": "12c635aa38def87395898c6aea77c1ba", "procStart": "Fri Sep  4 15:18:49 2026"}
```

二进制中的证据：`[uds-messaging] Failed to publish the inbox auth key; peers will send unauthenticated (accepted: auth is optional on this platform)`——auth key 会被发布给 peers，且**本平台（macOS）auth 是可选的**（token 校验失败仍接受投递，这降低了本套件对 key 文件可用性的依赖，也意味着 token 匹配是尽力而为而非硬门槛）。

### 2.2 跨会话消息（ListAgents / SendMessage / 帧）

- `ListAgents`（内部名 ListPeers）：列出 subagent / teammates / 本机会话 / 云会话。
- `SendMessage`：按会话名或 `uds://`/`bridge://` 地址寻址投递。
- 外部进程注入姿势（二进制中的官方提示原文）：

```bash
{ echo '{"type":"auth","token":"'"$CLAUDE_CODE_MESSAGING_TOKEN"'"}';
  echo '{"type":"user","message":{"role":"user","content":"hello"}}'; } \
| socat - UNIX-CONNECT:$CLAUDE_CODE_MESSAGING_SOCKET
```

帧协议：顶层 `type` ∈ {auth, user, control}；user 帧的 message 就是标准的 role/content 结构，投递到目标会话后表现为一条用户消息。

### 2.3 hook 事件全集（与本套件相关的部分）

从二进制事件常量表逆向出的完整列表：

```
PreToolUse, PostToolUse, PostToolUseFailure, PostToolBatch, Notification,
UserPromptSubmit, UserPromptExpansion, SessionStart, SessionEnd, Stop,
StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact,
PreModelSwitch, PostModelSwitch, PermissionRequest, PermissionDenied,
Setup, TeammateIdle, TaskCreated, TaskCompleted, Elicitation,
ElicitationResult, ConfigChange, WorktreeCreate, WorktreeRemove,
InstructionsLoaded, CwdChanged, FileChanged, DirectoryAdded, MessageDisplay
```

关键事件：

- **`StopFailure`**（2.1.259 存在）：turn 以失败结束（429 耗尽重试、网络错误、API 错误）时触发。stdin schema：`{hook_event_name, session_id, transcript_path, cwd, prompt_id, error, error_details, last_assistant_message}`。配套执行器 `executeStopFailureHooks`。**这是中断防御第一层的根基。**
- `PostToolUseFailure`：单个工具调用失败后触发（粒度太细，且 429 发生在模型回合层而非工具层，不适用本场景）。
- `Stop`：turn 正常结束。不能用于中断检测——它恰恰在失败时不触发。
- `notify_when_idle`（control 帧 `peer_idle_notice`）：turn 结束的信号性通知。**不能作为中断检测**：错误结束的 turn 是否发 notice 未经验证；即便发，也只表达"停了"不携带原因；进程死亡时主体消失什么都发不出。**v2 起的新用法**：作为 worker 活性信号刷新 `last_response_ts`（idle ≠ 完成，不作督促触发器）。订阅机制已实测可用（2026-09-05 端到端实测记录①，见 9.8）；若未来版本机制变更失效，本用法整体回退，不影响其余条款。

### 2.4 明确不用的机制及原因

- **notify_when_idle（v1 结论，v2 部分反转）**：不用作中断检测或完成信号（信号太弱、覆盖不全，见 2.3），且 worker 协议已强制每个里程碑主动上报，订阅完成信号属于冗余。v2 起仅用作活性信号（刷新 last_response_ts，见第 11 节），仍不作督促触发器——按 idle 督促会按回合频率轰炸正在干活的 worker（长 Phase 中间每回合都 idle）。
- **Agent Teams**：官方的 lead/teammate 组织（roster.json、plan 审批、worktree 隔离）。它是"组织内的层级协作"，本套件要的是"平级会话之上的独立监工"——supervisor 不属于团队、不写代码、只审查推进，与 Teams 的 lead（亲自干活的人）角色冲突。用跨会话 messaging + 自定义协议更贴合。

## 3. 架构

```
用户 ⟷ Supervisor 会话（监工，不写代码）
              │ ListAgents / SendMessage（官方跨会话消息）
              │
     ┌────────┼────────┐
   Worker A   Worker B  ...（工人会话，各管一段 scope）
     │
     │ StopFailure hook（回合失败时自动直投 supervisor UDS）
     │ WORKER REGISTER / REPORT / STATUS / STALLED / RESUME（协议消息）
     ▼
<project>/.supervisor/
   state.json         ← 全局账本（supervisor 单写，原子写）
   interrupts.jsonl   ← 中断流水（hook 追加写，append-only，永不回改）
   acknowledged.jsonl ← 中断确认账本（supervisor 单写，append-only）
   watchdog_state.json← 告警去重状态（watchdog 单写，原子写）
```

三要素对应监工模式：

- **被动守卫（Passive Guardrail）**：supervisor 从不主动打断 worker 干活；只在收到上报（或中断通知）后才对已产出的结果做后置审查（Post-audit）。触发器是消息，不是轮询（v2 唯一例外：定时自巡检 cron，见第 11 节，tick 无事时零消息零长输出）。
- **OODA 循环**：Observe（读上报 + 亲自读文件/git diff 验证，不只信摘要）→ Orient（对照 goal 与账本）→ Decide（APPROVE / REFINE / ESCALATE）→ Act（SendMessage 下发结构化决策）。随下一次上报再次进入循环。
- **全局状态存储**：`state.json` 记录 goal、per-worker phase、每次审查结论、事故流水。Loop Guard（同 phase 连续 3 次 REFINE → 升级用户）防"错改-回改"死循环。

### 3.1 身份模型（session_id 主键）

worker 与 supervisor 的身份主键一律是 **session_id**（注册时由 supervisor 通过 ListAgents 从发送方解析获得），name 仅作展示：

- StopFailure hook 的准入判定是"stdin 的 session_id ∈ workers[].session_id"——名字重复、改名、同目录的用户会话、空账本都不会误报（P1-1/P1-3 修复）。
- hook 寻址 supervisor：先 `supervisor_session_id` 精确匹配；id 失配再退到 `supervisor_name` + 会话 cwd == `project_dir` 双重校验——跨项目的同名 supervisor 会话不会被选中（P1-2 修复）。
- 升级用户、WATCHDOG ALERT、interrupts 账本都携带 session_id，`claude --resume <session-id>` 的恢复指引可以直接兑现（P1-13 修复）。
- worker 从子目录启动的场景：hook 从 StopFailure.cwd 向上逐级找 `.supervisor/state.json`，找到后靠 session_id 准入判定排除"路径上误撞的无关项目"（P1-4 修复）。

## 4. 中断模型（本套件的核心设计）

### 4.1 中断三分类

worker 的中断按"谁能感知"分三类，处理主体完全不同：

| 类别 | 例子 | 谁能感知 | 处理层 |
|---|---|---|---|
| A. 模型可自见的失败 | 工具连续失败、依赖坏掉 | worker 模型自己（回合还在） | 协议层：WORKER STALLED |
| B. 回合级传输失败 | 429 耗尽重试、网络错误、API 错误 | 模型**永远**没机会发言；但进程还活着，宿主的 hook 机制仍可执行 | StopFailure hook：WORKER INTERRUPTED |
| C. 进程级死亡 | 进程被杀、终端关闭、机器休眠 | **没有任何 in-process 机制可用**——执行主体已消失 | 外部检测（watchdog/巡检）+ 人工 resume |

### 4.2 为什么进程死亡"无能为力"是原理性的

B 类与 C 类的本质区别：hook、模型自报、任何消息机制都寄生在 worker 进程里。进程死亡意味着**一切寄生于它的机制同时死亡**——StopFailure hook 没有宿主可执行，WORKER STALLED 没有发送方可发。这不是实现缺陷，是逻辑必然：你不能要求死者报丧。

因此 C 类只能由**进程之外的观察者**处理：

1. watchdog（cron 定时器）发现 worker 超时静默 → 告警 supervisor；
2. supervisor 巡检（ListAgents 确认可达性）→ 升级用户；
3. 用户 `claude --resume <session-id>` 恢复会话（会话持久化在 `~/.claude/projects/` 的 jsonl 里，进程死亡不丢 transcript）→ worker 恢复后发 WORKER RESUME。

恢复的锚点是纪律而不是机制：worker 协议强制"每 Phase 立即 commit"，所以任何中断（B/C 类都一样）丢失的最多是当前 Phase 未提交的部分，历史成果在 git 里完好。

### 4.3 四层防御（按响应及时性排序）

```
B类中断 ──→ ① StopFailure hook（秒级，自动）
A类中断 ──→ ② 协议层 STALLED/RESUME（worker 自报，秒级）
静默失联 ──→ ③ supervisor 巡检（v2 起为 10 分钟定时 cron + 被唤醒时顺带，分钟级）
              ④ 外部 watchdog（cron，分钟级，覆盖 supervisor 自身不在线的盲区）
```

四层互为冗余而非互斥：hook 投递失败（supervisor 进程也死了）时 `delivered: false` 落盘，③ 的补课逻辑会在 supervisor 下次醒来时追认；③ 依赖 supervisor 被唤醒（v2 起定时 cron 把它从"碰运气"升级为"最多 10 分钟必醒"），④ 用 cron 补上"supervisor 进程死亡时无人唤醒"的盲区（cron 调度器寄生在 supervisor 宿主进程里，宿主死则巡检死，第四层不降级）。

### 4.4 失联判定的活性语义

**失联时钟只由 worker 主动发出的消息重置**（WORKER REPORT / STATUS / RESUME / REGISTER → `last_response_ts`）。supervisor 自己下发的指令（`last_instruction_ts`）只作展示，绝不参与判定。否则会出现"告警 → 发 STATUS CHECK → 时钟重置 → 再等一个周期"的无限循环，失联的 worker 永远升不了级（P1-10 修复）。

supervisor v1 无法定时醒来，v2 起有 10 分钟巡检 cron（见第 11 节），但 STATUS CHECK 的"10 分钟无回应重试、再无回应升级"仍由 `pending_check = {ts, retries}` 状态承载：每次 supervisor 被唤醒（含 cron tick）时结算（超时则重试或升级），配合 watchdog 的 cron 摧发保证 supervisor 一定会被叫醒（P1-9 修复）。

## 5. StopFailure hook 设计细节

`hooks/worker-stopfailure.py`，注册于 `settings.json` 的 `hooks.StopFailure`。

### 5.1 身份判定

见 3.1。判定链（全通过才投递）：

1. 从 StopFailure.cwd 向上找到 `.supervisor/state.json`（找不到 → 非监工项目，退出）；
2. `done: true` → 退出；
3. stdin 的 session_id 必须在 `workers[].session_id` 中（不在 → 退出；空 workers 数组天然全拒）。

### 5.2 supervisor 发现算法

```
state.supervisor_session_id
  → 扫 ~/.claude/sessions/*.json，sessionId 精确匹配且 socket 存活 → 用它
state.supervisor_name + state.project_dir
  → name 匹配 且 会话 cwd == project_dir 且 socket 存活 → 取 updatedAt 最新
  → 都不中 → 不投递（interrupts.jsonl 仍落盘，等补课）
```

auth 在本平台是可选的（见 2.1），key 文件缺失/procStart 不匹配时降级为无 auth 帧投递，不阻断。

### 5.3 落盘与确认语义（delivered / handled / acknowledged）

`delivered` 的语义刻意收窄为"**字节写进了 supervisor 的 UDS**"——sendall 成功不代表 supervisor 处理了（目标进程可能在处理前退出、协议层拒绝或丢弃）。真正的送达确认走三层：

1. hook 每次中断追加一条（append-only，永不回改）到 `interrupts.jsonl`，字段含 `id`、`delivered`、`handled: false`；
2. supervisor 收到 WORKER INTERRUPTED（或补课时）处理完该中断后，**追加** `{"id": ..., "ts": ..., "action": ...}` 到 `acknowledged.jsonl`（自己的单写账本）；
3. supervisor 每次被唤醒做差集：`interrupts.jsonl 的 id - acknowledged.jsonl 的 id` = 未处理中断，逐条补处理。

这个设计避免了"原地给 JSONL 行打标"的写-写竞态（supervisor 重写文件会覆盖 hook 并发追加的行），两个账本各自 append-only、单写者明确（P1-5/P1-7 修复）。

### 5.4 安全边界

hook 挂在用户全局 settings.json 上，失败模式必须极度保守：

- 任何异常（含 stdin 畸形、文件不可读、socket 拒连、字段类型异常）→ 静默 `exit 0`；
- 时间预算有界：UDS connect 1s + send 1s，无等待性 recv（原版 recv(2) 已移除），落盘只 flush 不 fsync（P2-1 修复）；
- 所有外部输入（error/error_details/sessions 字段）先做类型防御（`as_text` 强转、dict/str 校验）再使用，防异常逃逸（P2-2 修复）；
- 只读 state.json/sessions，只追加 interrupts.jsonl，**永不碰 state.json**（那是 supervisor 的单写者领地）。

### 5.5 退避与唤醒（supervisor 侧协议）

supervisor 收到 WORKER INTERRUPTED 后：

- kind 为 rate-limit/network：`ScheduleWakeup(delaySeconds=300)` 延迟唤醒后 SendMessage 唤醒（v2 起；v1 用 Bash `sleep 300`，存在 Bash 工具默认 2 分钟超时提前打断退避的坑，已废弃）。**流程纪律：落账在前、arm 在后**——ScheduleWakeup arm 后本回合即结束，incidents/acknowledged/pending_check 必须在 arm 之前落账，唤醒指令整体内嵌于自包含 prompt。
- 多 worker 同时中断：错峰，每个额外 +60s（sleep 360/420/...），避免同时唤醒再次集体撞限流。
- kind 为 api-error：退避缩至 60s；重试后仍中断直接升级用户（大概率是配置/额度问题，重试无益）。
- 唤醒后置 `pending_check`，重试/升级由后续唤醒结算（见 4.4）。

## 6. watchdog 设计细节

`watchdog.sh`（安装为 `~/.agent-mail/supervisor-watchdog`），cron 定时调用。

- **失联判定与 4.4 相同**：只认 `last_report_ts` / `last_response_ts` / `registered_at`，忽略 `last_instruction_ts`。
- **时间解析**：ISO-8601 容错（`fromisoformat` + `Z` 后缀归一 + 两套 fallback 格式），时区偏移会换算到本地再比较；解析失败该 worker 跳过本轮（保守不告警），不做任何输出（P1-11/P2-3 修复）。
- **告警去重（梯度升级）**：`.supervisor/watchdog_state.json` 记录每 worker 上次告警时的静默分钟数；仅当静默又增长一个完整阈值（T, 2T, 3T...）或条目是新的才再告警。去重状态先原子落盘再发告警——崩溃时最坏丢一条，绝不会有告警风暴（P1-12 修复；空 to_alert 时完全静默）。
- **macOS 通知**：通知文本经 `osascript` 的 `on run argv` 传参，**永不**拼进 AppleScript 源码——worker 名来自 state.json，是不可信输入（P0-3 修复）。
- **agent-mail 调用**：参数数组式 subprocess，无 shell 拼接。
- **永远 exit 0**：shell 层 `trap 'exit 0' EXIT` + python 层 `2>/dev/null || exit 0`，cron 永远收不到错误输出。

## 7. 数据文件与并发纪律

| 文件 | 写者 | 模式 |
|---|---|---|
| `state.json` | supervisor 单写 | 读-改-写，**原子写**（tmp + rename），更新前重读最新 |
| `interrupts.jsonl` | hook 追加写 | append-only，永不回改 |
| `acknowledged.jsonl` | supervisor 追加写 | append-only（中断确认） |
| `watchdog_state.json` | watchdog 单写 | 原子写（mkstemp + replace） |

单写者 + append-only + 原子写三原则下，唯一的残余竞态是**读者读到半写文件**：hook/watchdog 读 state.json 遇到解析失败按"未监工/跳过本轮"处理（保守放弃，下一轮 cron 或下一次中断会补上），supervisor 写 state.json 必须走 tmp+rename 原子发布（P1-6 修复，协议层约束——supervisor 是 LLM 不是程序，靠协议明文要求）。`.supervisor/` 整体建议进 .gitignore。

## 8. install.sh 设计细节

- **损坏的 settings.json → 备份后中止安装**，绝不自动重置全局配置（P0-2 修复）；
- **已有同名文件先备份再覆盖**（时间戳后缀 `.bak-<stamp>`，内容相同时跳过备份）（P0-1 修复）；
- hook 注册命令用 `shlex.quote()` 构建，路径含单引号也安全（P2-5 修复）；
- settings.json 更新：flock 排他锁 + mkstemp 唯一临时文件 + fsync + 保留原文件 mode + os.replace 原子发布（P2-4 修复）；
- hooks 配置结构异常（非对象/非数组）时中止而不是破坏。

## 9. 已知边界（记录在案，非缺陷待修）

1. **进程死亡无自动恢复**（4.2 节，原理性）：watchdog 只能检测+告警，resume 必须人手执行。
2. **模式选择是用户显式决策**（12.1 节）：绿地（/supervisor）与重构（/rework）的选型由用户拍板，协议不做任务类型自动判定——软判定判错模式整场错配，宁可多问一次人。
3. **hook 版本依赖**：StopFailure 事件在 2.1.259 二进制中确认存在，官方无文档；Claude Code 升级后该机制可能变化，需要重跑 `test_stopfailure.sh` 回归。
4. **peerToken 非硬校验**：本平台 auth optional，恶意本地进程本就能读同一 key 文件——本套件不提供跨进程认证，只在单用户信任域内工作。
5. **错误分类是启发式**：`classify_error` 按错误串关键字归类（429/rate limit/overloaded → rate-limit；timeout/econnreset → network；其余 → api-error），决定退避时长。误分类的后果只是退避时长不优，不影响正确性。
6. **协议对 LLM 的依赖（遵循度不可确保，只能工程化对冲）**：监工人格由 slash command 注入——`/supervisor` 的本质是把协议全文作为一条长 user prompt 发给模型，没有任何进程级隔离或角色绑定。prompt 是软约束，LLM 遵循度永远不是 100%：监工可能跳过某次巡检、忘掉 Loop Guard、在多次 REFINE 后行为漂移（长会话 context 压缩会加速漂移）。**无法根除，只能对冲**，本套件的对冲分三层：
   - **把确定性逻辑从 LLM 手里拿走**：中断检测的触发不依赖监工自觉——StopFailure hook 是进程级代码（回合失败瞬间触发）、watchdog 是 cron 定时器（不依赖任何 agent 活着）。需要监工做的只剩"收到消息后按协议响应"，触发链是硬的，响应是软的；
   - **状态外置，使漂移可恢复**：全部进度在 state.json 而非监工的 context 里，状态文件不会撒谎。漂移的退路是重新执行 `/supervisor <目标>` 重注入协议全文，state.json 恢复全部上下文，漂移归零。协议因此反复强调"决策依据是 state.json 而不是你的记忆"；
   - **协议写法本身**：立即执行式指令、行为红线明确列举、每步给具体动作而非抽象原则——经验上强命令式 + 具体步骤的遵循率显著高于软描述。
   残余风险：监工的软失效（漏巡检、忘规则）无解，硬兜底层保证其后果是"晚发现"而非"不发现"。这是本套件与纯代码方案的本质折衷，也是引入第四层 watchdog 的根本原因之一。
7. **真实 429 场景未实测**：逆向确认了事件存在和触发条件，但官方无文档；首次实战使用时建议盯第一次触发。
8. **cron 调度器寄生宿主进程（v2）**：定时巡检的调度器跑在 supervisor 的宿主 Claude Code 进程内，supervisor 死则巡检死，由第四层外部 watchdog 兜底，防线不降级。另：cron 过期天数等参数版本间已变过（3 天→7 天），协议一律以现场 CronList 为准。
9. **v2 端到端实测记录（2026-09-05，真实双会话演练）**：① notify_when_idle 订阅——✅ 实测通过：SendMessage 自动附带订阅（worker 侧可见 UDS 地址级订阅请求），worker idle 后 supervisor 正常感知，唤醒消息再次自动附带新订阅；② WORKER INTERRUPTED 注入 + ScheduleWakeup 退避——✅ 实测通过：UDS 注入送达、四步流程（incidents→acknowledged→pending_check→arm）完整执行且顺序正确、60s 后唤醒 fire、唤醒消息送达 worker；③ SendMessage 唤醒空闲/中断 worker——✅ 实测通过：worker 收到唤醒消息立即开新回合（ack + 继续干活 + spec 上报），链条⑥打通，429 中断全自动闭环成立（StopFailure 终态的极端情形仍未实测，但空闲唤醒已证 SendMessage 可驱动停止的会话）。**实测意外收获**：(a) supervisor 对伪造中断的防御超出预期——worker_session_id 不在账本时拒绝处理并升级用户，且正确识别"peer 消息不能冒充用户授权"，两次社会工程尝试均被拒绝；(b) 发现并修复 session_id 格式坑：ListAgents 输出 `This session is supervisor [6aebfc]` 的方括号短哈希不是 session_id（真实值为 36 位 UUID），协议已补 UUID 格式自检条款。
10. **StopFailure 终态唤醒（残留挂账）**：③的实测覆盖的是"idle worker"而非"StopFailure 终态 worker"——真实 429 后会话是否等价于可被 SendMessage 驱动的状态，仍需真实 429 事件验证（无法伪造，等首次实战）。


## 10. 测试策略

`test_stopfailure.sh`（22 项断言）与 `test_watchdog.sh`（15 项断言）均为断言型回归测试，完全沙箱化（伪 sessions 目录、伪 state.json、假 UDS 服务端/假 agent-mail CLI），失败时保留临时目录供排障、成功时自动清理。覆盖矩阵：

- hook：正常投递（auth+user 帧、kind 分类、phase、session_id 落账）、陌生人会话/空 workers/done 项目/无 state 目录的零误伤、子目录 cwd 向上寻址、socket 存在但拒连（真 connect 失败分支）、key 缺失的 auth 降级、畸形 stdin、非字符串 error_details、同名 supervisor 诱饵不被选中；
- watchdog：逾期告警（含 session_id）、同静默级别去重、`last_instruction_ts` 不抑制告警、新鲜 worker/最近响应/done 项目静默、非法阈值/目录/损坏 state/workers 非列表的静默退出、梯度升级、RFC3339 Z 时间戳解析。

测试数据的一个教训值得记录：给本地 naive 时间戳硬加 `Z` 后缀会把它变成"未来时间"（UTC 解析比本地墙钟早 8 小时），导致静默值为负、永不告警——测试用例 K 用真正的 UTC 过去时间戳单独覆盖 Z 解析路径。

真实 429 场景的端到端（Claude Code 触发 StopFailure → hook 投递 → supervisor 退避唤醒）尚未实测，首次实战使用时建议盯第一次触发。

## 11. 定时自巡检与对齐漏斗（v2 新增）

实测依据见 `specs/2026-09-05-scheduled-supervision/claude_cron.md`（Claude Code 2.1.259 定时任务机制实测记录）。

### 11.1 定时自巡检

supervisor 启动时用 `CronCreate` 创建每 10 分钟的 session-only 巡检 cron，prompt 含巡检三步 + CronList 自查重建（crons 自动过期，重建是例行动作）+ noop 纪律（无事时只输出一行，防上下文膨胀加速协议淡化）。

关键设计决定：**session-only（durable=false）而非 durable**——实测 durable 任务是目录级共享的，执行者死后同目录其他会话（worker）会抢锁接管执行，巡检 prompt 将 fire 进 worker 上下文造成污染；session-only 保证执行者永远只有 supervisor 自己。代价：supervisor 死则 cron 死（可接受，第四层兜底）。

幂等：/supervisor 协议重注入是既定的漂移恢复手段，启动步骤先 CronList 查重防双 cron。收尾：全部 done 时 CronDelete。

信号频率谱（自下而上）：分钟级 watchdog 告警（硬）→ 10 分钟巡检 tick（硬，宿主调度器）→ 回合级 idle 通知（硬，宿主）→ 里程碑 WORKER REPORT（软）。

### 11.2 ScheduleWakeup 退避与流程重排

中断退避从 Bash `sleep 300` 改为 `ScheduleWakeup(delaySeconds=300, ...)`：消除 Bash 默认 2 分钟超时坑与工具占用。delaySeconds 运行时夹在 [60,3600]，api-error 类退避 60s 恰为下限。**流程重排是本改动的核心**：arm 后本回合即结束，所以落账（incidents/acknowledged/pending_check）必须前置于 arm，唤醒动作整体移入自包含 prompt（不依赖原回合记忆）。

### 11.3 idle 活性信号

supervisor 每次 SendMessage 附带 notify_when_idle 订阅，收到 idle 通知唯一动作是刷新 `last_response_ts`（宿主级硬证据：进程活着、回合正常结束）。**明确不用作督促触发器**：worker 协议本就是不干完里程碑不上报，长 Phase 中间每回合都 idle，按 idle 督促会按回合频率轰炸正在干活的 worker（CR P0-1 裁定）。是否督促只走既有 60 分钟失联判定，一套逻辑不双轨。订阅机制已实测通过（见 §9.8 实测记录①）；若未来版本机制变更失效，本节回退。

### 11.4 三层回答防火墙

worker 提问按 goal内/监工职权/需用户三级标注（WORKER QUESTIONS 格式）。supervisor 只答前两级（监工职权裁决记入 state.json 的 decisions，总结报告披露）；需用户级攒批问真用户。防火墙目的：把"监工代理"与"冒名顶替用户"隔开——若 supervisor 无边界地代答目标级问题，会形成"两个 LLM 互相说服"的漂移放大器，目标偏移无人校验。

### 11.5 三阶段质询（对齐漏斗）

v1 的对齐是被动的（worker 报什么审什么），真问题的挖掘责任全压在执行者视角的 worker 身上。v2 升级为主动质询：clarify 挖理解偏差（对抗式挖掘沉默假设、反向验收标准）、spec 挖完整性缺口（边界/错误路径/非功能）、plan 挖执行风险（DoD 可验证性、隐藏耦合、pre-mortem）。每阶段质询上限两轮，与 Loop Guard（3 次 REFINE）独立计数，防"完美澄清"变不开工借口。

## 12. 模式分层与 rework 模式

### 12.1 拆分动机：协议膨胀 vs 泛化的矛盾

v2 之后 /supervisor 协议对绿地项目（从零开发）高度适配，但对老项目修补/重构这类高频场景缺四块针对性设计（基线锚定、回归安全网、考古裁决、范围纪律）。直接的泛化路径有两个：给 /supervisor 加任务模式参数，或新增 /rework 命令。前者的问题：全量协议注入意味着 rework 条款与绿地条款互相污染上下文，协议越长 LLM 遵循度越低（§9.5 的老问题），且模式判定交给 LLM 软判断会引入"判错模式整场错配"的不确定性。后者单独复制核心协议的问题：150 行级拷贝的同步维护是灾难。解法是物理拆分：`commands/_core-supervisor.md`（模式无关：身份/启动/账本/四层防御/OODA/QUESTIONS/dev-N 骨架/红线）+ 每模式一个薄模式层（frontmatter + 模式声明 + 前置阶段质询），模式由用户显式选命令（不做自动判定）。

### 12.2 组合机制：安装期拼接（方案 B），非运行时 @ 引用

模式层与 core 在 install.sh 安装期 cat 拼接成单一命令文件。选拼接而非 @ 引用的理由与本套件一贯哲学一致（能硬不软，§9.5 对冲策略第一条）：拼接发生在安装期，可 grep 断言、可 diff 审查；拼接产物带三重结构断言（frontmatter 唯一性——第二个 `---` 后的水平线不误判；五个关键节齐全；无重复二级标题——模式层章节不得与 core 撞名），断言失败备份中止、不留半成品。**dev-0 实测的两个关键结论**：拼接产物可被 Claude Code 正常加载为 slash command（方案 B 前提成立）；**下划线前缀文件也会被注册为命令**（实测推翻预期）——因此 `_core-supervisor.md` 绝不能放进 `~/.claude/commands/`（会变成可误触的伪命令），原料副本只装 `~/.claude/hooks/claude-supervisor/`。

零回归保障：拆分是纯重构，拼接产物与拆分前 supervisor.md 的 diff 仅允许模式声明节新增、章节顺序重排、三处绿地特化措辞参数化（启动步骤 7 首阶段指令整句 / phase 枚举 / schema 示例——参数由模式层声明，rework 下由 supervisor 初始指令下发本模式枚举覆盖 worker.md 的绿地默认值）。dev-1 门禁实测：removed 24 条 = 纯移位 20 + 允许改写 4，零条款丢失。

### 12.3 rework 的考古四件套与安全网

rework 状态机：`archaeology → safety-net → spec → plan → dev-N`。考古四件套（架构地图/债务清单/疑点清单/依赖暗网）的设计依据：老项目的第一课是考古而非规划——没有行为基线的 REFINE/APPROVE 无从判定"改好了还是改坏了"。三条硬规则：bug-vs-feature 疑点禁 worker 自行裁决（git blame 说不清的标"待用户"，默认"需用户"级——考古裁决的存档价值高于绿地，不落账就会有人再犯）；安全网测试锁行为不锁实现（assert 内部结构的测试会让重构必然假红）；安全网含待改行为（只有先锁住现状，改造前后的 diff 才可归因）。

### 12.4 frozen_behaviors（不改清单）

（实现决策记录【实施 CR P2-7】：spec F1 曾要求 core schema 含 frozen_behaviors 可选字段，但这与零回归硬约束矛盾——core schema 必须与拆分前逐字一致，不能加字段。最终实现：schema 定义放 rework 模式层（模式特化字段归模式层），core 不动。这与"模式无关者进 core"的抽取原则自洽。）

state.json 可选顶层字段，生命周期：archaeology 产出初稿 → safety-net APPROVE 时用户确认锁定（locked_by）→ 锁定后首个 dev 指令把清单全文下发给 worker（worker 不读 state.json，必须显式告知）→ dev 期触碰且无授权即 REFINE + 升级。触碰的机械信号：条目 evidence 字段（考古证据 + 关联文件/函数清单）与 dev diff 求交，交非空即触发；模糊条目（如"响应时间不劣化"）无机械信号，由 supervisor 审查时人工比对并标注。变更通道："需用户"级申请，获准后先改账再动手。

### 12.5 顺手重构红线（范围比对）

重构最经典的死法是"顺手重构"：每个 phase 都顺便多改一点，最终 diff 无法评审。对策固化为机械信号：每次审查 dev 上报时必跑 `git diff --name-only <本 phase 基线 commit>..HEAD` 与该 phase 声明范围比对，超出即 REFINE 无论改动多"合理"（不依赖 worker 自觉，也不依赖 supervisor 记忆）。免责通道：确需扩大范围走"需用户"级 QUESTIONS（范围变更即目标变更）。配套纪律：进入 dev-1 前工作区必须 clean（防脏区污染安全网基线与范围比对）；单 phase = 一次可独立回滚的改动单元；每 phase DoD 必含"安全网前后输出一致"断言或"预期行为 diff 清单"。

### 12.6 注入体积预算

协议长度直接关系遵循度（每加一个模式的条款都在稀释其他模式的遵循度），故模式层有硬预算：绿地模式层 39 行、rework 模式层 68 行（实施 CR 后实测）、core 169 行（拆分时实测）。拼接产物：绿地 208 行（原 197，增量全在模式声明节）、rework 237 行（实施 CR P1-1 内联化后）。rework 的增量条款通过引用 core 既有机制（QUESTIONS 三层、Loop Guard、质询两轮上限）而非重复声明来控制体积；自包含条款（边界/错误路径/非功能三查）例外——拼接产物不含绿地层，跨模式引用会悬空（实施 CR P1-1 裁定）。
