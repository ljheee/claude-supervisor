# Spec: claude-supervisor v3 — 多 Supervisor 并存（registry 发现 + 账本分片）

> 分支：`feat/v3-multi-supervisor`（基于 main，含 v2 与 rework 两轮合并）
> 依据：2026-09-06 多模式并行讨论（walk-tracer 旧账覆盖问题 + 庞大项目跨模式并行诉求）
> 状态：三轮评审通过（子代理 CR + 修订 + 作者终审）+ dev-0 实测驱动修订（两项假设推翻后回炉）+ CR2 实测后复审（P0×1+P1×4+P2×7）+ hook 化扩展（实测⑦⑧背书）

## 1. 背景与问题

v2 + rework 后的架构是**单 Supervisor 世界**：一个 project-dir 一份平铺账本 `.supervisor/state.json`，supervisor 是 schema 里的单数概念。这带来两类已确认的现实问题：

1. **跨轮覆盖**：同一项目先跑完一轮任务（done:true），再开新任务时新 supervisor 续写同一账本——goal/workers 被覆盖，reviews/decisions 混账，旧实验证据被污染（walk-tracer 的 v2 账本即实例）。
2. **跨模式并行不可能**：庞大项目里 /supervisor 开新模块与 /rework 改存量同时进行时，三个共享资源全部打架——账本单例（消息路由串台、frozen_behaviors 跨模式不可见）、git 工作区单例（rework 的范围比对会把绿地 commit 误判越界 REFINE）、cron 查重串台（两个 supervisor 的巡检任务共用"监工定时巡检"标识，后启动者会因查重跳过创建自己的 cron）。

核心观察：**模式内的多 worker 并发已被支持**（scope 划分/交错上报/Loop Guard），缺的是"多 supervisor"这一层的隔离与发现机制。

## 2. 目标

1. 同一 project-dir 下**多个 supervisor 并存**：各自独立账本、独立巡检 cron、独立中断流水，互不污染；
2. worker 启动时能**确定性发现并选择**目标 supervisor（多 supervisor 时由用户选定）；
3. 账本天然按轮次隔离——新任务新分片，旧账自动成为只读存档（解决跨轮覆盖）；
4. git 并行风险有明确裁决：多 supervisor 同仓并行时**强制分支/worktree 隔离**（机械可判定，不做智能合并）；
5. 单 supervisor 场景**零行为回归**——不并行时用户体验与 v2/rework 完全一致。

## 3. 非目标

- 不做跨项目 supervisor（一个 supervisor 管多个 project-dir）；
- 不做消息广播/订阅分发（worker 永远只属于一个 supervisor）；
- 不做同分支混行提交的智能范围比对（排除他方 commit 的启发式）——并行即隔离，不做智能合并；
- 不做 supervisor 间通信（两个监工互不感知，冲突升级用户裁决）；
- 不改 worker 执行协议的主体（干活/上报/中断恢复不动，只动注册发现）；
- 不做 registry 的高可用分布式锁语义（单机 fcntl 互斥足够，本套件定位就是单机单用户）；
- 不做死条目/归档分片的自动清理（stale 只标记，归档只隔离，删除仅限注销自己）。

## 4. 架构定位

```
.supervisor/
├── registry.json              ← 发现层：活跃 supervisor 注册表（多写者，registry.py fcntl 互斥）
├── <supervisor-session-id>/   ← 存储层：分片账本（per-file 单写者，目录名为 UUID 格式）
│   ├── state.json
│   ├── interrupts.jsonl
│   └── acknowledged.jsonl
└── archive/                   ← 旧平铺账本归档处（非 UUID 目录名，分片扫描白名单天然隔离）
```

**hook 面（v3 扩展，dev-0 实测⑦⑧背书）**：StopFailure（存量，中断直投）+ **SessionStart 注入器**（会话级一次，stdout 注入本会话 session_id——消除 LLM 扫注册表取 sid 的执行漂移）+ **PreToolUse 分片守卫**（Write|Edit 匹配，路径 sid 与 stdin sid 等值校验——机械阻断选错分片键）。三层 hook 均为 dumb 代码：注入器零外部状态只输出（不读会话状态、不写任何文件），守卫短路优先，StopFailure 的改动仅限分片解析层（send_uds 投递与帧格式不动）。**注册作用域为用户级 `~/.claude/settings.json`（与既有 StopFailure 同模式，CR3 P0-1）**——注入行与守卫全局生效，取舍明示：SESSION_ID 行是一行良性噪音（任何会话知自身 sid 无害且有用）；守卫对无关项目靠短路压到纯字符串判断（延迟实测毫秒级）；resume 核对提示仅在 `<cwd>/.supervisor/` 存在时注入（一次 stat 门控，无关项目零噪音）。

**分片枚举白名单**：hook/watchdog 扫描分片时**仅匹配 UUID 格式目录名**，archive/ 与其他非 UUID 目录一律不可见——归档隔离靠目录命名规则机械保证，不靠运行时判断。

**分片键 = supervisor 的 session_id（UUID）**。理由：天然跟"监工实例"走，跨 `claude --resume` 稳定（resume 不换 sid，找回自己分片），新会话即新任务即新分片——跨轮隔离免费获得。

**发现层与存储层分离**：registry.json 是唯一多写者文件（registry.py 的 fcntl 事务串行化），分片内 **per-file 单写者**（state.json/acknowledged.jsonl=该 supervisor，interrupts.jsonl=hook，watchdog_state.json=watchdog，CR3 P3-8）——把并发复杂度压缩到一个文件上。

**发现与寻址职责拆分（双键架构，dev-0 实测定案）**：**会话名称（name）是消息路由键**——SendMessage 只认名称（UUID 与短 ID 实测均不可达）；**session_id（UUID）是持久身份与存储键**——分片目录、hook stdin 匹配、watchdog UDS 直投都用它。两键都不可弃：名字是进程生命周期属性（resume 后会重分配，实测 test-98→test-34），sid 跨 resume 持久。因此 name 必须显式管理（/rename 固定唯一名），sid 必须可靠获取（`~/.claude/sessions/` 注册表，实测当前版本 ListAgents 不输出 UUID）。这是 v2"session_id 是身份主键、name 仅供展示"教训的实测级精化。

**git 并行裁决（方案：物理隔离）**：多 supervisor 各自队伍在不同分支或 worktree 上工作（worker.md 已有"若 supervisor 为你指定了独立分支或 worktree"条款，v3 将其从可选升级为多 supervisor 时的强制）。范围比对、安全网基线、回滚锚点全部在各自分支语义下成立。同分支并行明确不支持（supervisor 启动时检测到 registry 有其他活跃 supervisor 且本方未获隔离承诺 → ESCALATE 用户先裁决分支）。

## 5. 功能需求

### F1 registry.json（发现层）

- 路径 `<project-dir>/.supervisor/registry.json`，schema：
  ```json
  {"supervisors": [
    {"session_id": "<UUID>", "name": "supervisor", "mode": "greenfield|rework",
     "goal_brief": "<目标摘要 ≤60 字>", "project_dir": "/abs/path",
     "branch": "<该队伍工作分支>", "started_at": "<ISO>", "heartbeat_ts": "<ISO>",
     "stale": false}
  ]}
  ```
- **写者与时机**：supervisor 启动步骤内注册（register）、每次巡检心跳（heartbeat）、全部 worker done 收尾时注销（unregister）。register 为**按 session_id 的幂等 upsert**（同 sid 覆盖刷新——含更新 name 字段与清除自身 stale 标记）——resume 归来的 supervisor 重走启动流程不产生重复条目，且自动纠正 resume 导致的名字漂移。
- **名称唯一性断言（消息路由的硬前提，dev-0 实测：SendMessage 只认名称）**：register 事务内校验本方 name 与他人活跃条目的 name 不冲突——冲突则拒绝注册，要求本方先 `/rename <唯一名>`（建议形态：supervisor-<模式或短后缀>，如 supervisor-gf / supervisor-rw）。名称唯一性是多 supervisor 并存的准入条件，不是建议。**作用域边界（CR3 P1-1）**：唯一性断言仅约束本 registry（本项目）；跨项目同名是已知边界（SendMessage 无 cwd 消歧，ListAgents 输出 cwd 未验证）——建议命名含项目后缀（supervisor-<项目缩写>-<模式>），dev-6 冒烟补双 project-dir 同名实测，结论记 DESIGN §9。
- **写入门禁（单次持锁事务）**：注册 = "读 registry → 检查他人活跃条目 → 写自己条目"的**单次持锁读-改-写事务**。**CLI 契约（CR2 P1-2；退出码分诊 CR3 P3-2；实施后 CR2 修正输出契约）**：`registry.py register [--branch <本方分支>]` 无 `--isolation-confirmed` 时若发现他人活跃条目 → 打印条目列表（含各条 branch 供比对；列表行仅展示 8 位 sid 前缀）**及末尾一行机器可读的 `KNOWN_OTHERS ["<完整 sid>", ...]`**、exit 2、不写入；**与他人活跃条目撞名 → exit 3、不写入**（LLM 按退出码分诊：2=需隔离确认、3=需先 /rename，不靠解析自由文本）。带 `--isolation-confirmed --known-others '<首次输出 KNOWN_OTHERS 行的完整 sid JSON 数组>'` 时重读 registry，校验他人活跃条目集合相对首次输出**未新增**（grown 则再次 exit 2 并重印最新 KNOWN_OTHERS 行；只给 8 位前缀永远过不了 grown 校验——完整 sid 只能取 KNOWN_OTHERS 行，实施后 CR2 修正：原实现首启输出无完整 sid，按文档字面重试会死循环）。通过则写入；`--branch` 两次调用均可传（首次仅用于展示比对，写入以确认重试时的值为准，CR3 P3-7）。ESCALATE/用户叫停路径**不写入任何条目**（根除自造死条目）。
- **并发写安全**：读-改-写整文件必须持进程内互斥锁（lockfile `.supervisor/registry.json.lock`）。**实现载体是 `registry.py` 助手脚本**（随 watchdog 同目录安装，`install -m 755`——core 协议以裸路径直接调用），提供 `register / heartbeat / unregister / mark-stale / list` 五个子命令，内部 python fcntl 持锁（超时 5 秒，失败 ESCALATE 用户）——协议条款只约束"调哪个命令"，不要求 LLM 现场构造持锁读-改-写命令（对照：state.json 原子写是单写者无锁纯 mv；install.sh 更新 settings.json 已有 python fcntl 先例）。首次运行自动创建 `.supervisor/` 目录（启动步骤 register 先于分片目录创建）。heartbeat 对缺失条目**拒绝无名重建**（无 --name → exit 1 提示重走 register；带 --name 重建但撞他人活跃名 → exit 3——防击穿名称唯一性，实施后 CR2 修正）。**所有子命令接受 `--project-dir` 定位 registry（默认 CWD）**——supervisor cwd ≠ project-dir 时两边不会分裂。**写入为同目录 tmp+rename 原子替换（CR2 P2-4）**——读侧（worker 读 registry 选监工/supervisor 读他人条目）是裸读，非原子写会撞半文件。**调用路径（CR3 P2-4）**：安装于 watchdog 同目录（`~/.agent-mail/registry.py`），不在 PATH——协议条款中的调用一律写绝对路径（install 收尾 echo 输出该路径），不写裸 `registry.py`。
- **stale 标记的写路径**：活性检查（ListAgents 可达性）由 supervisor LLM 判断，判定结果经 `registry.py mark-stale <sid>` 写入——**stale 标记也必须走 registry.py，禁止 LLM 直接编辑 registry.json**（否则击穿"并发写全部经锁"）。register 的幂等 upsert 含清除自身 stale 标记（resume 归来自息）。
- **死条目清理**：supervisor 启动时与每次巡检时，对本条目以外的其他条目做活性检查——**按 name 检查**（该条目的 name 是否出现在 ListAgents 输出中；实测当前版本 ListAgents 不输出 UUID，按 sid 查可达性无从执行）。不可达且 heartbeat 超 30 分钟的条目标记 `"stale": true` 保留（不删：账本分片还在，可能是待 resume 的实例），仅在注销时删除自己的条目。**绝不删除他人条目**。注意：resume 重分配名字会让活着的 supervisor 被 name 检查误判不可达——由 heartbeat 双条件兼作兜底（心跳新鲜即不标 stale），且 resume 恢复流程的 register upsert 自愈。
- **崩溃残留**：supervisor 进程被杀未来得及注销 → 条目残留。处置：worker REGISTER 的 SendMessage 发送失败/无回应时，worker 向用户报告"疑似死条目"，由用户裁决——worker 报告时附三选项清单：① resume 该 supervisor（推荐，恢复流程自动续命）；② 稍后重试（可能仅是 resume 窗口期，恢复流程收尾后自动重新可达）；③ 确认监工不回来 → worker 转自主模式兜底：完成当前 phase 已下发指令并 commit（git log 为证），不自行流转 phase（phase 裁决临时代行者是用户），supervisor 恢复或用户接手后补审；死条目由用户人工清理（worker 对 registry 只读）。不做自动清除。

### F2 分片账本 + core 协议改造（存储层）

- 账本路径改为 `.supervisor/<本 supervisor session_id>/state.json`；`interrupts.jsonl`、`acknowledged.jsonl` 同目录随行（中断流水天然属于单个 supervisor）。
- core 启动步骤改造：
  - **会话名固定与 sid 获取（dev-0 实测驱动的流程改造）**：启动时先确认自己会话名——若为自动分配名（含"test-"等随机形态）或与已知名冲突，建议用户 `/rename supervisor-<后缀>` 固定唯一名；sid 获取以 **SessionStart hook 注入为主**（dev-0 实测⑦：hook stdout 注入本会话 36 位 UUID 到上下文，模型能逐字复述）——启动时直接从上下文中的注入行取 sid；注入行缺失（未安装 hook/异常）时 fallback 扫 `~/.claude/sessions/` 注册表，匹配规则：**name 相等且 cwd==本方 project-dir**（sessions 注册表是全局命名空间，名称唯一性只约束本项目 registry，跨项目同名必现，必须用 cwd 消歧——CR2 P1-4）；仍多条（同名同目录）→ 报错并建议换名后重扫，禁止任选（选错 = 分片键错，hook pass-1 永远 miss）。两项就绪后才继续。
  - **resume 恢复流程（dev-0 实测：resume 保 sid 但重分配名字）**：触发机制双通道（CR2 P1-3 升级）——① 机械通道：SessionStart hook 在 source=resume 时注入核对提示（dev-0 实测⑦：resume 会再触发 SessionStart 且 sid 不变），supervisor resume 归来第一回合即被引导走恢复流程；② 协议通道：巡检 prompt 常驻首条"每轮巡检开头读 registry 本方条目：name 与自身当前名不符 / stale=true / 条目缺失 → 立即走 resume 恢复流程"（机械通道失效时的兜底）。恢复动作：先读 registry 本方条目与他人活跃条目——**旧名未被占用才 /rename 回旧名，被占用则直接选新唯一名**（避免与后继者撞名，CR2 P2-1），随即 `registry.py register` upsert 刷新 name，然后向用户汇报中断点继续；期间 worker 若按旧名寻址失败，走死条目报告路径由用户引导（恢复流程收尾后自动重新可达）。
  - **旧布局迁移**：检测到平铺 `.supervisor/state.json`（v2/rework 遗留）→ 询问用户：归档（推荐，`mv` 为 `.supervisor/archive/<started_at>-<旧 goal 摘要>/`，目录名中 `/` 与空格替换为 `-`，CR3 P3-3）或保留原地不动（本 supervisor 新建分片与旧账并存，旧账不再读写）。用户未答前不创建分片。**旧账有未完结轮次（done:false 且 workers 非空）时警告用户：v3 supervisor 启动后 hook/watchdog 以分片优先，v2 worker 的中断直投与逾期告警由平铺兜底通道接住（见 F4/F5），建议先让 v2 轮次收尾或归档**（CR3 P1-3）。
  - **worker 身份登记改造（CR2 P0-1，实测⑦后简化）**：core 启动步骤 9（原 7）现行"用 ListAgents 解析发送方会话，取得其 session_id"已失效（ListAgents 不输出 UUID）——改为：**worker 在 WORKER REGISTER 消息内自报本会话 session_id**（worker 开局即从 SessionStart 注入行获得自身 sid，dev-0 实测⑦），supervisor 校验格式（36 位 UUID）后**做一次 sessions 扫描交叉验证**（按发送方 name 且 cwd==project_dir；不一致以扫描为准并要求 worker 重报——防幻觉/抄错的自报，CR3 P2-5；扫描零命中且无注入行 → 非 Claude worker 分支），再写入 workers[]；自报缺失或格式非法时同样走扫描 fallback（同消歧规则）；同名同目录多条 → 要求 worker 先 /rename 换名再注册，禁止任选。**非 Claude worker（Codex 经 agent-mail 桥上报）**：无注入行且不在 sessions 注册表——session_id 记为 null、`workers[].channel` 记 `"agent-mail"`（Claude worker 为 `"sendMessage"`，CR3 P3-4）；hook 层不覆盖（StopFailure 本就是 Claude Code hook，与 v2 一致），失联判定照常走 last_response_ts。workers[].session_id 是 hook 身份门禁（stdin sid 匹配分片 workers[]）的唯一输入，取错则四层防御第一层整层失效。
  - **registry 注册与并行隔离断言（单次事务，CR2 P2-3）**：**启动步骤顺序定死（CR3 P2-3）：名称固定与 sid 获取 → 旧布局迁移询问 → 注册事务 → 分片与 cron 创建**（迁移询问先于注册：注册后用户在迁移处弃答会留下"有条目无分片"的孤儿形态）。执行 F1 定义的单次持锁注册事务（含名称唯一性断言）——发现其他活跃（非 stale）条目时，锁外与用户确认本方工作分支/worktree 与他方不冲突，确认后重做带校验的注册写入（branch 字段此时填入）；未确认或用户叫停 → ESCALATE，**不写入条目**（无孤儿分片与孤儿 cron）。
  - **cron 查重修复**：巡检 cron 的查重标识从"监工定时巡检"改为"监工定时巡检(<本 sid 完整 UUID>)"（dev-0 实测：session-only cron 不跨会话可见，多 supervisor 巡检天然隔离——查重键的实际职责收窄为防**同会话协议重注入**产生双 cron；完整 UUID 消灭碰撞类风险，"能硬不软"）。重建条款（巡检 prompt 第 1 条）同步改。
- core 巡检步骤改造：每次巡检顺带更新自己 registry 条目的 heartbeat_ts；巡检三步不动；**新增 stale 活性检查条款（CR2 P2-2）**：启动时与每次巡检时，对本条目以外的其他条目按 name 检查活性（name 出现在 ListAgents 输出中即可达；ListAgents 无 UUID，按 sid 查不可行）——不可达且 heartbeat 超 30 分钟 → `registry.py mark-stale <sid>`（绝不删他人条目，删除仅限注销自己）；resume 重分配名字导致的误判由 heartbeat 双条件兼作兜底、resume 恢复流程 upsert 自愈。
- core 收尾改造：CronDelete 巡检 cron 的同时从 registry 注销自己（registry.py unregister）。
- 其余 core 条款（四层防御/三层回答/OODA/dev-N 骨架/红线）**零改动**——分片只是路径换根，语义不变。
- 两模式层（supervisor.md/rework.md）零改动（模式声明与质询不涉及账本路径）。

### F3 worker 发现改造（worker.md）

- 注册步骤 1 改为：
  1. 读 `<project-dir>/.supervisor/registry.json`（只读）；
  2. 活跃（非 stale）条目唯一 → 直接以其 **name**（消息路由键，dev-0 实测 SendMessage 只认名称）为监工目标，SendMessage 按名称寻址；
  3. 活跃条目多个 → 把列表（name/mode/goal 摘要/branch）展示给用户，请用户指定监工名；
  4. 无活跃条目或 registry 不存在 → 维持现行兜底：提示监工未启动，或按 `--supervisor <会话名>` 参数指定后用 ListAgents 按名字查找。
- `--supervisor` 参数：接受**会话名称**（必须唯一；同名多条时要求先 rename——`<名>[<短ID>]` 消歧形式 dev-6 实测 SendMessage 不可达，CR2 P2-5 的"失败则删除该形式改为提示用户先 rename"分支已触发落地）——SendMessage 寻址的唯一可用键（UUID/短 ID 实测均不可达）。
- 注册消息唯一改动：WORKER REGISTER 内**自报本会话 session_id**（从 SessionStart 注入行获得，dev-0 实测⑦；注入行缺失时扫 sessions 注册表取）——供 supervisor 写 workers[]，消除 CR2 P0-1 的扫描路径；其余字段不变；
- worker 持有的监工名失效时（supervisor resume 重分配名字的窗口期），SendMessage 失败 → 按"疑似死条目"路径报告用户（与 F1 崩溃残留共用处置，含三选项清单与单干兜底）。SendMessage 按名称寻址路由到唯一 supervisor——名称唯一性断言在注册源头上保证无串台；消息层零改动是本方案的成本优势。
- **红线放宽（精确化）**：worker.md 现行"`.supervisor/` 目录永不 add、永不修改"改为——registry.json 与各分片目录**只读**；state.json 及一切分片内容**禁碰**；`.supervisor/` 整体仍永不 add（账本不进 git）。

### F4 hook 层改造（StopFailure 多分片解析 + 新增注入器/守卫）

**新增 hook 一：SessionStart 注入器（`session-start-injector.py`）**

- 事件 SessionStart（startup 与 resume 均触发，dev-0 实测⑦），stdout 单行注入：`SESSION_ID <本会话 36 位 UUID> <source>`——会话内所有角色（supervisor/worker）开局即知自身 sid，机械可靠。
- source=resume 时额外注入核对提示：`若你是 supervisor：读 <cwd>/.supervisor/registry.json 核对本方条目（name 不符/stale=true/缺失 → 走 resume 恢复流程）`——resume 恢复流程的机械触发通道。
- hook 为 dumb 脚本（零外部状态：不读会话状态、不写任何文件；内部有 source 分支与 .supervisor/ 存在性门控，CR3 P3-1）：读 stdin 取 session_id/source/cwd，stdout 拼 1-2 行；异常时静默 exit 0（注入缺失由 F2 的 sessions 扫描 fallback 兑住，不中断会话）。resume 核对提示仅在 `<cwd>/.supervisor/` 存在时输出（无关项目零噪音，CR3 P0-1）。

**新增 hook 二：PreToolUse 分片守卫（`shard-guard.py`）**

- matcher `Write|Edit`（封堵 LLM 写分片与 registry 的主通道——Bash 仍可写任意文件，守卫是绊索不是墙，Bash 绕过属既有协议红线范畴，CR3 P2-1）；tool_input.file_path 匹配 `.supervisor/<uuid>/` 下任何文件时，校验路径中 uuid 与 stdin session_id **等值**——不等则 exit 2 + stderr 给出正确 sid（dev-0 实测⑧：拦截真生效且 stderr 可作纠错信道）；**Write|Edit 目标为 `.supervisor/registry.json` 一律 exit 2**（多写者核心文件，合法写全部经 registry.py/Bash，LLM 直编会击穿并发锁——零成本规则，CR3 P2-1）。
- **廉价短路**：路径不含 `.supervisor/` 直接 exit 0（纯字符串判断，不起解释器、不解析 JSON——绝大多数业务写文件零开销）；疑似命中才解析 JSON 做精确校验。放行路径零输出零感知。
- 守卫只拦"写他方/不存在的分片路径"，不拦正确分片写入（本方 sid 匹配即放行）；archive/ 与平铺 state.json 天然不匹配 `.supervisor/<uuid>/` 模式放行（归档 mv 走 Bash 工具，本就不触发 Write|Edit matcher）。

**存量 hook：worker-stopfailure.py 多分片解析（原 F4 主体）**

- `find_state_upward` 改造：向上找到 `.supervisor/` 后，**优先扫描分片**（UUID 目录名白名单，archive/ 与非 UUID 目录不可见）；无分片时回退平铺 state.json。**分片集合存在但 stdin sid 零命中时，追加一次平铺 workers[] 精确匹配（CR3 P1-3 升级窗口兼容）**——命中则按平铺流程投递（v2 存量轮次的中断直投不因首个 v3 分片出现而静默丢失），未命中维持不投递不落盘（宁漏勿错投）。
- 分片选择规则：hook 从 **stdin JSON 的 session_id**（dev-0 已实测定案）匹配分片的 `workers[].session_id`；worker sid 命中多个**活跃分片**时（同一 worker 会话先后注册进两个 supervisor 的形态），取 `registered_at` 最新者（现役队伍优先），仍不唯一 → 不投递不落盘，stderr 记一行（宁漏勿错投——错投会污染他方 acknowledged 账）。归档分片因 UUID 白名单不可见，不会进入命中集合（P0-1 白名单与多命中消歧协同生效）。
- `resolve_supervisor` pass-2（name+cwd 回退）收紧：**存在任一分片（分片数 ≥ 1）时禁用 pass-2**，仅允许 supervisor_session_id 精确匹配——否则目标 supervisor 已死时，同目录同名同 cwd 的他方 supervisor 会收到不属于自己队伍的干扰消息（补课机制可兜后果，但投递语义已错）。实施 CR 修正：原实现写成分片数 > 1，漏掉了 v2→v3 升级窗口（平铺 v2 账本 + 恰好 1 个 v3 分片共存）——此时 v2 supervisor 已死、同名 v3 supervisor 存活，v2 worker 的中断会被错投；纯 v2 零分片场景保留 pass-2 兼容（回归用例 case18b 覆盖）。
- interrupts.jsonl 写入路径随选中分片（`.supervisor/<sid>/interrupts.jsonl`）。
- **worktree 支持**：worker 工作在 linked worktree 时，向上找不到 `.supervisor/`——用 `git rev-parse --git-common-dir` 定位主工作区根，再在主工作区根下找 `.supervisor/`（确定性命令，不做目录猜测）。
- 回归测试 test_stopfailure.sh 扩展用例：多分片定向投递 / 多分片无匹配（含双命中歧义）不投递 / 平铺回退（零分片时）/ worktree 发现 / **archive 不被扫描** / **双 supervisor 名字碰撞且目标 sid 死 → 不投递（pass-2 禁用）**；新增两 hook 各自用例：注入器（startup/resume 两种 source 输出、异常静默 exit 0）、守卫（正确分片放行 / 错 sid deny + stderr 含正确 sid / 短路路径零 JSON 解析 / archive 与平铺写入放行）。

### F5 watchdog 适配（watchdog.sh）

- 状态文件读取从单一 state.json 改为遍历所有分片（UUID 目录名白名单，同 F4）+ 平铺回退；每个分片独立判定逾期、独立路由告警。
- **告警路由改 UDS 直投**：对目标分片的 supervisor_session_id 按 `~/.claude/sessions/` 注册表精确匹配 socket 直投（复用 hook 的 send_uds 机制，v1/v2 已实测背书）——agent-mail 按名字路由废弃（多 supervisor 默认同名必串台）。**复用范围含三件事（CR2 P2-6）**：messagingSocketPath 存在性 liveness 检查（旧版本 sessions 条目无此字段）、peerToken 定位（auth 帧）、连接超时预算。**取舍明示**：socket 不可达时告警无痕丢失（agent-mail 有 mailbox 持久化，UDS 无）——watchdog 本就是第四层 best-effort，可接受，但不可再对外承诺不丢。
- watchdog 去重状态按分片拆分：`.supervisor/<sid>/watchdog_state.json`（避免多 supervisor 互相重置对方的告警梯度）。
- 回归测试 test_watchdog.sh 扩展用例：双分片独立告警、去重状态互不干扰、平铺回退、archive 不被扫描。

### F6 install.sh + 文档同步

- install.sh：新增 `registry.py` 安装（与 watchdog 同目录同方式）；**新增两个 hook 安装与 settings.json 注册**（SessionStart → 注入器、PreToolUse(Write|Edit matcher) → 分片守卫，与既有 StopFailure 注册同模式——settings.json 更新已有 python fcntl 先例；重装幂等，已有注册不重复追加）；收尾 echo 补多 supervisor 用法一句，且原平铺路径表述改分片语义（`.supervisor/interrupts.jsonl` → `.supervisor/<sid>/interrupts.jsonl`）；其余零改动。
- **hook 注册作用域（用户级，CR3 P0-1）**：两新 hook 与 StopFailure 同模式注册于 `~/.claude/settings.json`（用户级，全机生效）——注入行是一行良性噪音（任何会话知自身 sid 无害且有用），守卫对无关项目靠短路压开销（纯字符串判断毫秒级），resume 核对提示靠 `.supervisor/` 存在性门控零噪音。卸载 = 手动删 settings.json 条目（未提供反装脚本，已知取舍）。
- README：多 supervisor 并存用法节（并行需分支/worktree 隔离警示、命名建议含项目后缀）、`--supervisor <会话名>` 说明（CR2 P1-5：修正此前残留的 <sid> 表述）、旧账本归档说明；**两处存量表述同步删改（CR3 P2-6）**：watchdog agent-mail 投递句（"前提：supervisor 在 agent-mail 注册过"——F5 已改 UDS 直投）与"注册时自动解析 session_id"句（改为 worker 自报+交叉验证）。
- DESIGN 新增第 13 节：发现/存储分层动机、分片键选 session_id 的理由、registry.py 单点多写者的取舍（为何不用 LLM 现场持锁）、git 物理隔离裁决、死条目处置的不对称设计（可标 stale 不可删他人）、分片枚举 UUID 白名单（archive 隔离）、**hook 化三件套的取舍（sid 获取/分片键防错从协议条款升级为机械保证；PostToolUse 自动 register 评估后未纳入——解析 state.json 太脆，unregister/stale 裁决保留 LLM 侧）**。
- DESIGN §9 已知边界更新：补"同分支混行并行不支持"与"跨项目同名 supervisor 边界"（CR3 P1-1 实测结论回填）条目。
- **存量文档漂移顺手修**：core 启动步骤 2 中"hook 靠 supervisor_session_id **前缀**匹配"改为"精确匹配"（实际代码是等值匹配，v3 改 core 时避免把错误说法抄进新条款）。

## 6. DoD（交付完成标准）

1. 单 supervisor 场景回归：两套回归测试（扩展后）全绿；/supervisor 与 /rework 单独注入实测行为与 v3 前一致（账本落在分片路径为唯一可见差异，**另验 SESSION_ID 注入行上下文可见、守卫对错 sid 拦截真机生效**）。 **[dev-6 勾验 ✅]** 全量回归双绿（62+30 断言，实施后 CR2 又扩至 65+32+29）、/supervisor 注入实测一致、注入行与守卫拦截均真机验证。
2. 双 supervisor 冒烟实测：同一 project-dir 起 greenfield + rework 两个 supervisor，worker 双双注册路由正确、账本互不可见、**各自终端的 CronList 各见且仅见本方一条 UUID 标识巡检、互不可见（隔离本身就是证据——实测 session-only cron 不跨会话可见，CR2 P1-1）**、一方收尾注销后 registry 只剩另一方；**registry 并发首建竞态合成测试**（两进程并发 register，验证锁串行化无条目丢失/重复）；**workers[].session_id 为真 UUID 且 hook 可命中的验证**（CR2 P0-1 的下游检查）。 **[dev-6 勾验 ✅（部分）]** 双 supervisor 启动/隔离门/两阶段注册/分片互不污染/注销/并发竞态全真机走通；worktree 场景 hook 命中真 UUID 分片；worker 双向注册路由与 CronList 双方各见未完整演练（挂账）。
3. 旧布局迁移实测：放置平铺 state.json 后启动，走归档询问分支，归档后旧数据可读、新分片干净，且归档目录对 hook/watchdog 均不可见（archive 隔离验证）。 **[dev-6 勾验 ⏸]** 未真机触发（沙箱 case16/N 已覆盖 archive 隔离；挂账补验）。
4. worktree 实测：worker 在 linked worktree 中触发 StopFailure，hook 经 git-common-dir 找到主工作区账本并正确投递所属分片。 **[dev-6 勾验 ✅]** 真机：中断落主工作区分片，worktree 零残留。
5. 零回归 diff 门禁：core 协议改造后的拼接产物与改造前 diff 逐条归类，语义条款除八类允许项（账本路径换根；registry 注册/心跳/注销/stale 条款；cron 查重标识改写；旧布局迁移条款；resume 恢复、会话名固定与 worker 身份登记（自报 sid 主 + 扫描 fallback）的新增条款；存量措辞修正五处——前缀→精确匹配、按会话寻址→按名称寻址、name 仅供展示补路由硬依赖、ListAgents 推导 sid→SessionStart 注入行（主）/sessions 注册表扫描（fallback）、watchdog 投递 agent-mail→消息通道直投（随 F5 联动）；注册前置（先于分片/cron 创建）的顺序调整；WORKER REGISTER 消息格式增自报 sid 一行）外零丢失零弱化——与 plan dev-1 步骤 9 逐字对齐。 **[dev-6 勾验 ✅]** dev-1c 完成，15 条归类落 plan 附录 A。

## 7. 风险对冲

| 风险 | 对冲 |
|---|---|
| registry 并发写竞态 | 写入全部经 registry.py 的 fcntl 事务（register 为幂等 upsert）；锁超时 5s + ESCALATE；并发首建有合成测试 |
| 死条目误判（supervisor 活着但心跳延迟） | stale 判定双条件（不可达 **且** 心跳超 30 分钟）；stale 只标记不删除；worker 注册失败走用户三选项裁决（resume / 稍后重试 / 单干） |
| 归档目录被误当活分片 | 分片枚举 UUID 目录名白名单（hook/watchdog 同规则）+ 回归用例固化 |
| hook 错投分片污染他方账 | 分片选择强匹配 worker session_id；多命中取非归档最新，不唯一不投递；pass-2 在多分片下禁用 |
| "resume 不换 sid"假设不成立 | dev-0 第 6 项已实测通过（resume 保 sid）；但会话名跨 resume 重分配，由恢复流程（rename + register upsert）补偿 |
| supervisor resume 窗口期 worker 寻址失效 | 恢复流程第一时间 rename 回注册名 + upsert；失效窗口内 worker 走死条目报告路径，用户引导后自动恢复 |
| supervisor LLM 执行漂移（取错 sid/漏调 registry.py） | SessionStart 注入器机械供给 sid（实测⑦）；PreToolUse 守卫机械阻断错分片写入（实测⑧）；sessions 扫描 fallback 兑住注入缺失 |
| hook 开销（每次 Write/Edit 触发守卫） | matcher 收窄 Write|Edit（Bash/Read 等不触发）+ 廉价短路（非 .supervisor 路径纯字符串判断直接放行）——实测单次毫秒级，淹没在 LLM 生成延迟中 |
| 平铺回退与分片并存的边界 | 回退仅在零分片时生效；一旦存在分片，平铺文件对 hook/watchdog 不可见 |
| 多 supervisor 同分支混行 | 注册事务内强制隔离确认；DESIGN §9 明示不支持 |
| 体积预算膨胀 | core 增量条款集中在启动/巡检/收尾三处局部，行为红线与四层防御不动；实测行数回填 DESIGN |
