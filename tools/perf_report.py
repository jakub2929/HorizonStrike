"""Summarise a perf run (dev tool, owner vykon): probe CSVs from game/dev/perf_probe.gd + tools/perf_mem.py output.

  python tools/perf_report.py <run dir> [--from-ready-s 10] [--json out.json]

Frames: from world_ready + --from-ready-s (default 10 s) to the end, heavy-sample frames excluded. Prints fps avg,
1 % low (1000 / p99 frame time), worst frame, GPU and CPU-render time (avg / p95 / p99), process and physics time,
draw calls; per visited cell the GPU avg; memory: max / last of the game's static memory, video / texture / buffer
memory; process RAM per role (working set, private) from mem_summary.json; the last heavy breakdown.
"""
import argparse
import csv
import glob
import json
import os
import statistics
import sys


def pct(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    k = min(len(s) - 1, max(0, int(round(p / 100.0 * (len(s) - 1)))))
    return s[k]


def load_csv(path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def summarise(run, from_ready_s):
    out = {"run": run}
    frames_files = sorted(glob.glob(os.path.join(run, "**", "frames_*.csv"), recursive=True), key=os.path.getsize)
    if frames_files:
        rows = load_csv(frames_files[-1])   # the biggest = the game process that walked (t15 runs a child)
        out["frames_file"] = frames_files[-1]
        ready_t = None
        for r in rows:
            if r["cells_loaded"] and int(r["cells_loaded"]) > 0:
                ready_t = float(r["t_s"])
                break
        t_from = (ready_t or 0.0) + from_ready_s
        sel = [r for r in rows if float(r["t_s"]) >= t_from and r["heavy"] == "0"]
        ft = [float(r["frame_ms"]) for r in sel]
        gpu = [float(r["gpu_ms"]) for r in sel]
        cpu = [float(r["cpu_render_ms"]) for r in sel]
        proc = [float(r["process_ms"]) for r in sel]
        phys = [float(r["physics_ms"]) for r in sel]
        dc = [float(r["draw_calls"]) for r in sel]
        if ft:
            secs = sum(ft) / 1000.0
            out["frames"] = {
                "n": len(ft), "seconds": round(secs, 1), "fps_avg": round(len(ft) / secs, 1),
                "fps_1pct_low": round(1000.0 / pct(ft, 99), 1), "worst_ms": round(max(ft), 1),
                "frames_over_50ms": sum(1 for x in ft if x > 50.0),
                "gpu_ms_avg": round(statistics.fmean(gpu), 2), "gpu_ms_p95": round(pct(gpu, 95), 2),
                "gpu_ms_p99": round(pct(gpu, 99), 2),
                "cpu_render_ms_avg": round(statistics.fmean(cpu), 2), "cpu_render_ms_p99": round(pct(cpu, 99), 2),
                "process_ms_avg": round(statistics.fmean(proc), 2), "process_ms_p99": round(pct(proc, 99), 2),
                "physics_ms_avg": round(statistics.fmean(phys), 2), "physics_ms_p99": round(pct(phys, 99), 2),
                "draw_calls_avg": round(statistics.fmean(dc)), "draw_calls_max": int(max(dc)),
            }
            per_cell = {}
            for r in sel:
                c = r["cell"] or "?"
                d = per_cell.setdefault(c, [0, 0.0, 0.0])
                d[0] += 1
                d[1] += float(r["gpu_ms"])
                d[2] += float(r["frame_ms"])
            out["per_cell"] = {c: {"frames": v[0], "gpu_ms_avg": round(v[1] / v[0], 2),
                                   "fps_avg": round(v[0] * 1000.0 / max(v[2], 1e-6), 1)} for c, v in per_cell.items()}
    mem_files = sorted(glob.glob(os.path.join(run, "**", "mem_*.csv"), recursive=True), key=os.path.getsize)
    if mem_files:
        rows = load_csv(mem_files[-1])
        def col(name):
            return [float(r[name]) for r in rows if r.get(name) not in (None, "")]
        out["game_memory"] = {k: {"max": round(max(col(k)), 1), "last": round(col(k)[-1], 1)}
                              for k in ("static_mib", "video_mib", "texture_mib", "buffer_mib", "objects", "nodes",
                                        "mesh_entries", "mesh_textures", "mesh_shapes", "cells_loaded", "cells_far")
                              if col(k)}
    bd_files = sorted(glob.glob(os.path.join(run, "**", "breakdown_*.json"), recursive=True), key=os.path.getsize)
    if bd_files:
        with open(bd_files[-1], encoding="utf-8") as f:
            bd = json.load(f)
        heavy = [b for b in bd if "static_mib" in b]
        if heavy:
            out["breakdown_first"] = heavy[0]
            out["breakdown_last"] = heavy[-1]
    ms = os.path.join(run, "mem_summary.json")
    if os.path.isfile(ms):
        with open(ms, encoding="utf-8") as f:
            s = json.load(f)
        out["process_ram"] = {role: {k: round(v, 1) for k, v in r.items() if k != "n"} for role, r in s["roles"].items()}
        out["processes"] = {pid: {k: (round(v, 1) if isinstance(v, float) else v) for k, v in p.items()}
                            for pid, p in s["processes"].items()}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--from-ready-s", type=float, default=10.0)
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    out = summarise(a.run, a.from_ready_s)
    text = json.dumps(out, indent=1)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            f.write(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
