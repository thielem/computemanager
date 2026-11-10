"""Check a headless Claude Code run (stream-json) + gatehost log. Stdlib only; run via uv.

usage: check_claude.py <b1|b2|b3> <stream.jsonl> <gatehost.log> <session-id>
Prints PASS/FAIL lines; exit 1 if any FAIL.
"""
import json
import sys

mode, stream_path, log_path, sid = sys.argv[1:5]
events = [json.loads(l) for l in open(stream_path) if l.strip().startswith("{")]
reqs = [json.loads(l[4:]) for l in open(log_path) if l.startswith("req ")]

# Tool calls in order: (tool_use_id, name, input) and results by id.
calls, results = [], {}
for e in events:
    msg = e.get("message") or {}
    content_list = msg.get("content") if isinstance(msg.get("content"), list) else []
    for c in content_list:
        if c.get("type") == "tool_use":
            calls.append((c["id"], c["name"], c.get("input", {})))
        elif c.get("type") == "tool_result":
            content = c.get("content")
            if isinstance(content, list):
                content = " ".join(x.get("text", "") for x in content if isinstance(x, dict))
            results[c["tool_use_id"]] = str(content)
init = next((e for e in events if e.get("type") == "system" and e.get("subtype") == "init"), {})
final = next((e for e in reversed(events) if e.get("type") == "result"), {})

fails = 0


def check(desc, cond, evidence=""):
    global fails
    print(f"  {'PASS' if cond else 'FAIL'} {desc}" + (f" — {evidence}" if evidence else ""))
    fails += 0 if cond else 1


def short(s, n=160):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


print("  tool calls:")
for i, (tid, name, inp) in enumerate(calls):
    print(f"    {i}. {name} {short(json.dumps(inp), 120)} -> {short(results.get(tid, '?'), 140)}")
print(f"  final: {short(final.get('result', ''), 300)}")

check("session id used", init.get("session_id") == sid, init.get("session_id", "?"))
check("plugin loaded", any("compute-gate" in json.dumps(p) for p in init.get("plugins", [])),
      short(init.get("plugins")))
bash = [(t, i) for t, n, i in calls if n == "Bash"]
acq = [r["body"] for r in reqs if r["op"] == "acquire" and r["body"].get("sessionId") == sid]
rel = [r["body"] for r in reqs if r["op"] == "release"]
hooks = [r["body"] for r in reqs if r["op"] == "hookCheck" and r["body"].get("sessionId") == sid]
check("hook ran for this session (hookCheck requests)", len(hooks) > 0, f"{len(hooks)} hookChecks")

if mode == "b1":
    direct = [(t, i) for t, i in bash if "check.sh" in i.get("command", "") and "cgate" not in i.get("command", "")]
    denied = [t for t, i in direct if "Compute gate: heavy command" in results.get(t, "")]
    check("direct scripts/check.sh denied by hook with cgate suggestion", bool(denied),
          short(results.get(denied[0], "")) if denied else "no denied direct call")
    wrapped = [(t, i) for t, i in bash if i.get("command", "").lstrip().startswith("cgate run")]
    check("agent re-ran as cgate run", bool(wrapped), short(wrapped[0][1]) if wrapped else "")
    check("lease registered with session id", bool(acq), short(acq[0]) if acq else "no acquire")
    ok_rel = [r for r in rel if r.get("reason") == "exited" and r.get("exitCode") == 0]
    check("run completed (release exited 0)", bool(ok_rel), short(rel))
    check("agent reports ok", "ok" in final.get("result", "").lower(), short(final.get("result", ""), 80))
elif mode == "b2":
    # Background runs: the exit-76 text arrives via whatever tool reads the task output.
    off = [t for t, _, _ in calls if "Compute gate off" in results.get(t, "")]
    check("agent got 'Compute gate off' feedback from cgate run (exit 76)",
          bool(off) and any("76" in results.get(t, "") for t in off), short(results.get(off[0], "")) if off else "")
    check("no lease granted (gatehost log has no release for a run)", not acq or not rel, short(rel))
else:
    first = calls[0] if calls else None
    check("pending stop notice denied the first tool call",
          bool(first) and "compute gate:" in results.get(first[0], ""),
          short(results.get(first[0], "")) if first else "no tool calls")
    check("agent stopped (no further heavy run attempted)",
          not any("cgate run" in i.get("command", "") for _, i in bash))

sys.exit(1 if fails else 0)
