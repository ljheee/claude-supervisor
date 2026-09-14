#!/usr/bin/env python3
"""
stop-anomaly-capture.py 判据 replay 验证（离线，不接投递链）。

按 stop-anomaly.md §三1 前置步骤：在事故 transcript 上离线跑判据脚本，
验证形态 1/2 的命中率与误报率，以及形态 3 候选判据 b（dangling tool_use）
是否零命中（预期不会响）。

判据（与 stop-anomaly.md §一逐字对齐）：
  形态 1   末条 assistant 记录 model == "error"
  形态 2   回合边界（最后一条非 tool_result 的 user 记录）之后全部
           assistant 聚合：零 tool_use 且文本全空或 "…"
  形态 3b  末条 assistant 记录带 tool_use，其后无对应 tool_result
           （对 user 记录的 content 按 tool_use_id 配对）

用法：python3 replay_check.py <transcript.jsonl> [label]
输出：逐形态命中数、逐命中时间戳（本地时间）、回合总数。
"""
import json
import sys


def is_tool_result_user(rec):
    """user 记录且 content 为 tool_result 数组（transcript 中 tool_result 挂在 user role）。"""
    if rec.get("type") != "user":
        return False
    m = rec.get("message", {})
    c = m.get("content")
    if isinstance(c, list):
        return any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c)
    return False


def assistant_blocks(rec):
    m = rec.get("message", {})
    c = m.get("content")
    return c if isinstance(c, list) else []


def assistant_text(rec):
    return "".join(b.get("text", "") for b in assistant_blocks(rec)
                   if isinstance(b, dict) and b.get("type") == "text").strip()


def assistant_tool_uses(rec):
    return [b for b in assistant_blocks(rec)
            if isinstance(b, dict) and b.get("type") == "tool_use"]


def local_ts(ts):
    try:
        h = (int(ts[11:13]) + 8) % 24
        return "%s %02d:%s" % (ts[:10], h, ts[14:19])
    except Exception:
        return ts


def replay(path, label):
    recs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                recs.append(json.loads(line))
            except Exception:
                pass

    # ---- 按回合切分：以"非 tool_result 的 user 记录"为回合起点 ----
    turns = []          # list of dict(start_idx, recs=[...])
    cur = None
    for i, r in enumerate(recs):
        if r.get("type") == "user" and not is_tool_result_user(r):
            cur = {"start": i, "recs": [r]}
            turns.append(cur)
        elif cur is not None:
            cur["recs"].append(r)

    hits1, hits2, hits3b, turns_with_assistant = [], [], [], 0
    normal_turns = 0

    for t in turns:
        # 回合内 assistant 记录（跳过起点 user）
        asst = [r for r in t["recs"][1:] if r.get("type") == "assistant"]
        if not asst:
            continue
        turns_with_assistant += 1
        last = asst[-1]
        ts = last.get("timestamp", "?")

        # ---- 判据 1：末条 assistant model == "error" ----
        if last.get("message", {}).get("model") == "error":
            hits1.append(ts)
            continue  # model:error 回合不算空回合判定对象

        # ---- 判据 2：末条零 tool_use 且文本空/"…"（统一 2a/2b，severity 区分） ----
        last_txt = assistant_text(last)
        last_tools = len(assistant_tool_uses(last))
        if last_tools == 0 and last_txt in ("", "…", "..."):
            all_tools = sum(len(assistant_tool_uses(a)) for a in asst)
            all_txts = [assistant_text(a) for a in asst]
            sev = "full" if (all_tools == 0 and all(t in ("", "…", "...")
                            for t in all_txts)) else "tail"
            hits2.append((ts, sev))
            if sev == "tail":
                normal_turns += 1  # tail 回合有实质工具产出，不计为无效回合
        else:
            normal_turns += 1

        # ---- 判据 3b：末条 assistant 带 tool_use，其后无对应 tool_result ----
        tus = assistant_tool_uses(last)
        if tus:
            # 回合尾部（末条 assistant 之后）是否有 user 记录回执这些 id
            ids = {b.get("id") for b in tus}
            tail = t["recs"][t["recs"].index(last) + 1:]
            got = set()
            for r in tail:
                if r.get("type") == "user":
                    for b in assistant_blocks(r):
                        if isinstance(b, dict) and b.get("type") == "tool_result":
                            got.add(b.get("tool_use_id"))
            if ids and not (ids & got):
                hits3b.append(ts)

    print("== %s ==" % label)
    print("  transcript: %s" % path.split("/")[-1])
    print("  总记录 %d | 回合（非 tool_result user 起点）%d | 含 assistant 回合 %d"
          % (len(recs), len(turns), turns_with_assistant))
    print("  判据1 model:error 命中 %d: %s"
          % (len(hits1), ", ".join(local_ts(t) for t in hits1) or "（零）"))
    fulls = [t for t, s in hits2 if s == "full"]
    tails = [t for t, s in hits2 if s == "tail"]
    print("  判据2 空回合/尾部退化命中 %d（full %d / tail %d）（前20）: %s"
          % (len(hits2), len(fulls), len(tails),
             ", ".join("%s[%s]" % (local_ts(t), s) for t, s in hits2[:20]) or "（零）"))
    if len(hits2) > 20:
        print("    … 其余 %d 个略" % (len(hits2) - 20))
    print("  判据3b dangling tool_use 命中 %d: %s"
          % (len(hits3b), ", ".join(local_ts(t) for t in hits3b[:10]) or "（零）"))
    print("  正常回合 %d | 判据1+2 合计覆盖率: %.1f%%"
          % (normal_turns,
             100.0 * (len(hits1) + len(hits2)) / max(1, turns_with_assistant)))
    print()
    return {"n_turns": turns_with_assistant, "h1": len(hits1),
            "h2": len(hits2), "h3b": len(hits3b), "normal": normal_turns}


if __name__ == "__main__":
    td = "/Users/lijianhua04/.claude/projects/-Users-lijianhua04-Documents-IdeaProject-walk-tracer/"
    targets = [
        (td + "54d21839-925e-45e3-a66e-fd8c6ee60518.jsonl", "WORKER（k3 劣化全程 + opus 换模后）"),
        (td + "a5f150f2-d550-461d-8b21-5fa738f80c6c.jsonl", "SUP（k3 劣化全程 + opus 换模后）"),
    ]
    if len(sys.argv) > 1:
        targets = [(sys.argv[1], sys.argv[2] if len(sys.argv) > 2
                    else sys.argv[1].split("/")[-1])]
    for path, label in targets:
        try:
            replay(path, label)
        except FileNotFoundError:
            print("== %s == 文件不存在：%s" % (label, path))
