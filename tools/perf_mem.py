"""Process memory sampler for perf runs (dev tool, owner vykon).

Starts a command (or attaches to a PID), samples the process tree every --interval seconds (working set and private
bytes per process: the game, its child game processes, hzsconv) and writes a CSV plus a summary JSON:

  python tools/perf_mem.py --out E:/meshy_work/vykon/run1 --timeout 900 -- <exe> <args...>
  python tools/perf_mem.py --out E:/meshy_work/vykon/run1 --pid 1234

CSV columns: t_s, pid, ppid, name, role, ws_mib, private_mib. role = game | converter | other.
Summary: per role max / last / mean of working set and private bytes (sum over processes of the role per sample),
and per process. Only the processes this tool started are ever terminated (on --timeout, by exact PID).
"""
import argparse
import csv
import json
import os
import subprocess
import sys
import time

import psutil

MIB = 1024.0 * 1024.0


def role_of(name: str) -> str:
    n = name.lower()
    if n.startswith("hzsconv"):
        return "converter"
    if n.startswith("horizonstrike") or n.startswith("godot"):
        return "game"
    return "other"


def tree(root: psutil.Process):
    procs = [root]
    try:
        procs += root.children(recursive=True)
    except psutil.Error:
        pass
    return procs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--pid", type=int, default=0)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--timeout", type=float, default=1800.0)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    os.makedirs(a.out, exist_ok=True)
    started = None
    if a.pid:
        root = psutil.Process(a.pid)
    elif cmd:
        log = open(os.path.join(a.out, "console.log"), "w", encoding="utf-8", errors="replace")
        started = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        root = psutil.Process(started.pid)
    else:
        ap.error("give --pid or a command after --")
        return 2
    t0 = time.time()
    rows = []
    per_role = {}
    per_proc = {}
    with open(os.path.join(a.out, "mem.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["t_s", "pid", "ppid", "name", "role", "ws_mib", "private_mib"])
        timed_out = False
        while True:
            if not root.is_running() or (started is not None and started.poll() is not None):
                break
            t = time.time() - t0
            if t > a.timeout:
                timed_out = True
                break
            sums = {}
            for p in tree(root):
                try:
                    with p.oneshot():
                        mi = p.memory_info()
                        name = p.name()
                        ppid = p.ppid()
                except psutil.Error:
                    continue
                ws = mi.rss / MIB
                priv = getattr(mi, "private", mi.vms) / MIB
                role = role_of(name)
                w.writerow([f"{t:.1f}", p.pid, ppid, name, role, f"{ws:.1f}", f"{priv:.1f}"])
                s = sums.setdefault(role, [0.0, 0.0])
                s[0] += ws
                s[1] += priv
                pp = per_proc.setdefault(p.pid, {"name": name, "role": role, "first_s": t, "ws_max": 0.0,
                                                  "private_max": 0.0, "private_last": 0.0, "ws_last": 0.0})
                pp["ws_max"] = max(pp["ws_max"], ws)
                pp["private_max"] = max(pp["private_max"], priv)
                pp["ws_last"] = ws
                pp["private_last"] = priv
                pp["last_s"] = t
            for role, (ws, priv) in sums.items():
                r = per_role.setdefault(role, {"n": 0, "ws_max": 0.0, "private_max": 0.0, "ws_sum": 0.0,
                                               "private_sum": 0.0})
                r["n"] += 1
                r["ws_max"] = max(r["ws_max"], ws)
                r["private_max"] = max(r["private_max"], priv)
                r["ws_sum"] += ws
                r["private_sum"] += priv
                r["ws_last"] = ws
                r["private_last"] = priv
            f.flush()
            time.sleep(a.interval)
    if started is not None and timed_out and started.poll() is None:
        # our own child and the processes it started (exact PIDs), nothing else
        for p in reversed(tree(root)):
            try:
                p.kill()
            except psutil.Error:
                pass
    for r in per_role.values():
        r["ws_mean"] = r.pop("ws_sum") / max(r["n"], 1)
        r["private_mean"] = r.pop("private_sum") / max(r["n"], 1)
    summary = {"seconds": time.time() - t0, "timed_out": timed_out,
               "exit_code": started.returncode if started is not None else None,
               "roles": per_role, "processes": per_proc}
    with open(os.path.join(a.out, "mem_summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=1)
    for role, r in sorted(per_role.items()):
        print(f"{role:10s} ws max {r['ws_max']:8.1f} MiB  private max {r['private_max']:8.1f} MiB  "
              f"ws last {r.get('ws_last', 0):8.1f}  private last {r.get('private_last', 0):8.1f}")
    print(f"done in {summary['seconds']:.0f} s, timed out {timed_out}, exit {summary['exit_code']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
