# Plan: claude-supervisor v3 多 Supervisor 并存实施

> 依据：`spec.md`（同目录）
> 原则：core 协议语义零弱化（账本路径换根 + 三处新增局部条款）；hook/watchdog 首次进入改动面（v3 spec 明确扩边界），每处改动配回归用例；全部新机制先实测后依赖（dev-0 沿用 rework 的前置实测纪律）。

## Phase 划分总览

| Phase | 内容 | 改动文件 | 依赖 |
|---|---|---|---|
| dev-0 | 前置实测 ×6：机制假设逐项验证 | 无产物（实测记录写回本 plan；第 4 项已实测通过） | 无 |
| dev-1 | core 协议改造（分片账本 + registry 四命令三时机 + cron 标识） | commands/_core-supervisor.md | dev-0 |
| dev-2 | worker.md 发现改造 | commands/worker.md | dev-0 |
| dev-3 | hook 多分片解析 + worktree 支持 | hooks/worker-stopfailure.py, test_stopfailure.sh | dev-0 |
| dev-4 | watchdog 分片适配 | watchdog.sh, test_watchdog.sh | dev-0 |
| dev-5 | install.sh + README/DESIGN 同步 | install.sh, README.md, DESIGN.md | dev-1~4 |
| dev-6 | 回归 + 双 supervisor 冒烟实测 + 收尾 | 全部 | dev-0~5 |

每 Phase 完成即 commit（沿用 `worker: claude-supervisor, phase: dev-N` 习惯格式），commit 前跑该 Phase 的 DoD 验证。

---

## dev-0 前置实测（机制假设验证）

不做未实测机制的关键路径依赖。六项独立，任一失败只影响对应设计决策，不阻塞其他项（第 4 项已实测通过并定案）。

### 实测项

1. **CronList 跨会话可见性**（F2 cron 查重修复的前提）：起两个 Claude Code 会话，A 建 cron 后 B CronList——B 能否看到 A 的任务？prompt 内容是否完整可见？（查重键形态已定案完整 UUID，本项只回答可见性与归属信息有无。）
2. **SendMessage 按 session_id 并发寻址**（F3 路由前提）：两个 supervisor 会话并存，worker 分别按两个 sid 发消息，验证各达各的收件箱、无串扰、无广播。
3. **worktree 下 hook 的 cwd 与 git 定位**（F4 前提）：linked worktree 中跑 `git rev-parse --git-common-dir`，确认输出主工作区 gitdir 且可推导主工作区根；确认 hook 在 worktree 中触发时的工作目录就是 worker cwd。
4. **hook stdin 的 session_id 可用性**（F4 分片选择的身份来源）【已实测通过，2026-09-06】：探针 hook（项目级 settings.json，Stop 事件 cat stdin 落盘）+ `claude -p` 实测——stdin JSON 确含 `session_id` 字段，36 位 UUID 格式，与 transcript_path 首行 sessionId 及 projects 目录名三方一致。额外可用字段：`prompt_id`（可作 worker 回合标识）、`cwd`、`transcript_path`。F4 身份源定案：hook stdin session_id。
5. **flock 可用性**（F1 前提）：macOS 无原生 /usr/bin/flock（CR 实测确认，仅 shlock）——定案方案已改为 registry.py 助手脚本（python fcntl），本项实测 registry.py 原型：fcntl 持锁读-改-写 + 锁超时语义 + 并发首建（两进程同时 register 无丢失/重复）；四个子命令（register/heartbeat/unregister/mark-stale，作者终审补充）逐一验证。
6. **resume 保 sid 不变性**（分片键基石假设，CR P1-1）：起一个会话记下 ListAgents 中的 session_id → `claude --resume <sid>` 重开 → ListAgents 再比对——sid 不变则分片键成立；顺带验证 idle 存活会话在 ListAgents 的可见性（stale 判定"可达"语义依赖它）。若 sid 会变，分片键方案回炉重设计。

### DoD

- [ ] 六项各有独立实测结论（通过/不通过 + 发现）回填本 plan
- [ ] registry.py 原型锁语义定案；resume sid 结论定案（不成立则 spec 回炉）
- [ ] 实测产生的临时会话/文件已清理

---

## dev-1 core 协议改造（F2）

### 步骤

1. `_core-supervisor.md` 启动步骤 3：账本路径改为 `.supervisor/<本 supervisor session_id>/state.json`（分片目录随建）；**旧布局迁移条款**（平铺 state.json 存在 → 问用户：归档到 `.supervisor/archive/<started_at>-<goal 摘要>/` 或原地保留不读写；未答不建分片）。
2. 启动步骤新增（编号顺延）：**registry 注册与并行隔离断言（单次事务，CR P0-2）**——registry.py register 事务：无他人活跃条目直接写入；有他人活跃条目锁外与用户确认分支/worktree 隔离，确认后重做带校验的注册写入（branch 此时填入）；ESCALATE/叫停不写入条目。register 为按 sid 幂等 upsert（resume 重走启动不产生重复条目，CR P1-1）。
3. 启动步骤 6（cron）：查重标识改"监工定时巡检(<本 sid 完整 UUID>)"（碰撞类风险零容忍，见 spec F2），巡检 prompt 里的重建条款同步改标识（含"重建时用自己的完整 sid"）。
4. 巡检步骤：新增 heartbeat_ts 更新（registry.py heartbeat，仅自己条目）。
5. 收尾（状态机 dev-N 第 4 条）：CronDelete 同时从 registry 注销自己（registry.py unregister）。
6. `interrupts.jsonl`/`acknowledged.jsonl` 全部路径引用改分片路径（grep 逐处核对：中断补课条含两文件、落账条款 acknowledged 一处——以 grep DoD 为准，不依赖计数）。
7. 顺手修存量漂移：启动步骤 2 "hook 靠 supervisor_session_id 前缀匹配"改"精确匹配"（CR P2-1，实际代码是等值匹配）。
8. 拼接门禁：`cat` 两模式层 + 新 core，与 v3 前拼接产物 diff——允许项仅限：路径换根（`<project-dir>/.supervisor/` → 分片路径）、启动步骤新增注册事务条款、cron 标识改写、心跳/注销各一句、旧布局迁移条款、前缀→精确匹配措辞修正。逐条归类，语义条款零丢失零弱化（沿用零回归 diff 门禁方法学）。

### DoD

- [ ] diff 归类清单落本 plan 附录（每条：所属允许类 / 语义等价说明）
- [ ] grep 核对：全文无残留平铺路径引用（`\.supervisor/state.json`、`\.supervisor/interrupts` 旧形态）
- [ ] registry.py 调用条款（register/heartbeat/unregister/mark-stale 四时机）、stale 判定（双条件）、"绝不删他人条目"在 core 中均为命令式表述；core 明文禁止 LLM 直接编辑 registry.json

---

## dev-2 worker.md 发现改造（F3）

### 步骤

1. 注册步骤 1 重写：读 registry → 唯一活跃条目直接选 / 多条目展示（name/mode/goal_brief/branch）请用户指定 / 无条目走现行 ListAgents 兜底。
2. `--supervisor` 参数：接受名字或完整 session_id（sid 优先精确匹配），frontmatter argument-hint 同步。
3. 红线精确化："`.supervisor/` 永不 add、永不修改" → "registry.json 与分片目录**只读**；分片内容禁碰；`.supervisor/` 整体永不 add"。两处红线（并行协作纪律节 + 行为红线节）同步改。
4. 注册消息格式不动；执行协议主体不动。

### DoD

- [ ] 注册步骤四分支齐全（唯一/多条/无条目/参数指定），每分支命令式
- [ ] 红线两处一致，无"永不修改"与"只读"措辞冲突
- [ ] worker.md 行数增量 ≤ 12 行（体积预算）

---

## dev-3 hook 多分片解析 + worktree（F4）

### 步骤

1. `find_state_upward` 改造：`.supervisor/` 存在时先扫分片（**UUID 目录名白名单**，archive/ 与非 UUID 目录不可见，CR P0-1）；零分片回退平铺。返回 (state_dict, shard_dir) 二元组。
2. 分片选择：用 dev-0 实测定案的身份源（hook stdin 的 session_id）匹配分片的 `workers[].session_id`；sid 多命中时取非归档且 registered_at 最新，仍不唯一不投递（CR P0-1）。
3. `resolve_supervisor` pass-2 收紧：分片数 > 1 时禁用 pass-2，仅 supervisor_session_id 精确匹配（CR P1-4）。
4. worktree：向上找不到 `.supervisor/` 时，`git rev-parse --git-common-dir` 推主工作区根再找（仅当 start_dir 在 git 仓库内）。
5. interrupts.jsonl 落盘路径随选中分片。
6. test_stopfailure.sh 扩展六用例：多分片定向投递 / 多分片无匹配（含双命中歧义）不投递 / 平铺回退（零分片时）/ worktree 发现（临时建 linked worktree）/ archive 不被扫描 / 双 supervisor 名字碰撞且目标 sid 死 → 不投递。

### DoD

- [ ] 既有用例零改动全绿（存量行为不回归）
- [ ] 新增六用例全绿
- [ ] hook 对分片目录的写操作仅 interrupts.jsonl 一处（grep 核对无越权写）

---

## dev-4 watchdog 分片适配（F5）

### 步骤

1. `watchdog.sh`：STATE 读取改为遍历分片（UUID 目录名白名单，排除 archive）+ 平铺回退；每分片独立逾期判定。
2. **告警路由改 UDS 直投（CR P1-2）**：复用 hook 的 send_uds 机制，按分片的 supervisor_session_id 精确匹配 `~/.claude/sessions/` socket 直投——agent-mail 名字路由废弃（多 supervisor 默认同名必串台）。
3. 去重状态分片化：`.supervisor/<sid>/watchdog_state.json`。
4. test_watchdog.sh 扩展：双分片独立告警 / 去重状态互不干扰 / 平铺回退 / archive 不被扫描。

### DoD

- [ ] 既有用例零改动全绿
- [ ] 新增三用例全绿
- [ ] 单分片场景 watchdog 行为与 v3 前一致（含告警文案）

---

## dev-5 install.sh + 文档同步（F6）

### 步骤

1. install.sh：新增 `registry.py` 安装（与 watchdog 同目录同方式，CR P1-3）；收尾 echo 补多 supervisor 用法一句 + 平铺路径表述改分片语义（`.supervisor/interrupts.jsonl` → `.supervisor/<sid>/interrupts.jsonl`，CR P2-4）；其余零改动（拼接断言不受影响——core 新增内容全部落在既有节内，无新 `## ` 标题）。
2. README：多 supervisor 并存用法节（分支/worktree 隔离警示）、`--supervisor <sid>` 说明、旧账本归档说明、registry.json 进文件清单（运行时产物说明）。
3. DESIGN 新增第 13 节（六要素：分层动机/分片键选型/registry.py 锁载体取舍/物理隔离裁决/死条目不对称处置/UUID 白名单 archive 隔离）+ §9 已知边界补"同分支混行不支持"。
4. 行数实测回填 DESIGN 体积预算（core/worker 增量）。

### DoD

- [ ] grep 无过时表述（"单 supervisor"/"唯一监工"类与 v3 矛盾的措辞）
- [ ] DESIGN 13 节六要素齐全，行数与实测一致
- [ ] install.sh 重装幂等（产物 diff 为空）

---

## dev-6 回归 + 双 supervisor 冒烟 + 收尾

### 步骤

1. 全量回归：test_stopfailure.sh（含新用例）+ test_watchdog.sh（含新用例）。
2. 本地真实安装 + 单 supervisor 注入实测（/supervisor 与 /rework 各一，验证分片账本落位、registry 注册、旧布局迁移询问分支）。
3. **双 supervisor 冒烟**（spec DoD 2）：同 project-dir 起 greenfield + rework 双 supervisor → 各自 worker 注册路由正确 → 账本互不可见 → CronList 见两条不同 UUID 巡检 → 一方收尾注销 → registry 只剩另一方；**registry 并发首建竞态合成测试**（两进程并发 register，验证锁串行化无丢失/重复，CR P2-3）。全程最小目标，走完注册与首轮上报即可，不做完整项目。
4. worktree 冒烟（spec DoD 4）：linked worktree 中触发 StopFailure（模拟），验证投递到所属分片。
5. spec §6 五项 DoD 逐条勾验；挂账清单汇总；最终 commit。

### DoD

- [ ] 全量回归全绿（存量 + 新增用例）
- [ ] 双 supervisor 冒烟四步证据齐全（路由/隔离/双 cron/注销）
- [ ] worktree 投递实测通过
- [ ] spec §6 五项勾验；挂账清单（预期至少三条：双 supervisor 真实项目长跑（含分支隔离下真实并行）/ stale 双条件判定与死条目用户裁决路径的协议级演练（无法脚本化）/ hook 错投零事故的长尾观察）

---

## 明确不做清单

- 不做 supervisor 间通信与协调（互不感知，冲突升级用户）；
- 不做死条目自动清除（只标记 stale，删除仅限注销自己）；
- 不做同分支混行的智能范围比对；
- 不做跨项目/跨机器 registry；
- 不在本轮做双 supervisor 真实项目长跑（冒烟即止，长跑挂账）。
