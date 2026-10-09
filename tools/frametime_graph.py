"""Frame-time graph (dev tool, no dependencies): one or more frametimes.csv from the t15 autotest
(columns t_s,frame_ms,phase,cell,event,vram_mb) -> one SVG with a line per run and a legend with avg fps,
1 % low (1000 / 99th percentile frame time) and the worst frame (overall and inside cell-load windows).

  python tools/frametime_graph.py baseline/frametimes.csv t15/frametimes.csv -o frametime_0.1_vs_0.2.svg \
      --labels 0.1.1 0.2 --phase route
"""
import argparse
import csv
import html
import math
import sys

COLORS = ["#d9534f", "#2a7fd4", "#3c9a3c", "#a05ec9"]


def load(path, phase):
    t, ms, loads = [], [], []
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if phase and row["phase"] != phase:
                continue
            ts, v = float(row["t_s"]), float(row["frame_ms"])
            t.append(ts)
            ms.append(v)
            if "cell_loaded" in (row.get("event") or "") or "cell_insert_started" in (row.get("event") or ""):
                loads.append(ts)
    if t:
        t0 = t[0]
        t = [x - t0 for x in t]
        loads = [x - t0 for x in loads]
    return t, ms, loads


def stats(t, ms, loads, before=1.0, after=0.25):
    if not ms:
        return {}
    s = sorted(ms)
    p99 = s[min(len(s) - 1, math.ceil(len(s) * 0.99) - 1)]
    worst_load = 0.0
    j = 0
    for ts, v in zip(t, ms):
        for lt in loads:
            if lt - before <= ts <= lt + after:
                worst_load = max(worst_load, v)
                break
    total = sum(ms) / 1000.0
    return {"frames": len(ms), "seconds": total, "fps_avg": len(ms) / total if total else 0.0,
            "fps_1pct_low": 1000.0 / p99 if p99 else 0.0, "worst_ms": max(ms), "worst_load_ms": worst_load, "loads": len(loads)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("csv", nargs="+")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--labels", nargs="*")
    ap.add_argument("--phase", default="route", help="phase to plot (empty = all rows)")
    ap.add_argument("--max-ms", type=float, default=0.0, help="y axis top (default: 1.1 x worst, at least 60)")
    a = ap.parse_args()
    labels = a.labels or [p for p in a.csv]
    runs = []
    for i, p in enumerate(a.csv):
        t, ms, loads = load(p, a.phase)
        if not ms:
            print(f"{p}: no rows for phase '{a.phase}'", file=sys.stderr)
            return 2
        runs.append((labels[i] if i < len(labels) else p, t, ms, loads, stats(t, ms, loads)))
    W, H, L, R, T, B = 1400, 620, 70, 20, 40, 150
    pw, ph = W - L - R, H - T - B
    tmax = max(r[1][-1] for r in runs) or 1.0
    ymax = a.max_ms or max(60.0, 1.1 * max(max(r[2]) for r in runs))
    X = lambda x: L + pw * x / tmax
    Y = lambda y: T + ph * (1.0 - min(y, ymax) / ymax)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Segoe UI, Arial, sans-serif" font-size="13">',
           f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
           f'<text x="{L}" y="24" font-size="16" font-weight="bold">Frame time ({html.escape(a.phase or "all")}) - lower is better</text>']
    # grid + reference lines
    step = 10 if ymax <= 120 else 25
    y = 0.0
    while y <= ymax + 0.01:
        out.append(f'<line x1="{L}" y1="{Y(y):.1f}" x2="{L + pw}" y2="{Y(y):.1f}" stroke="#eeeeee"/>')
        out.append(f'<text x="{L - 8}" y="{Y(y) + 4:.1f}" text-anchor="end" fill="#666">{y:g}</text>')
        y += step
    for ref, col, name in ((1000 / 60, "#999999", "16.7 ms = 60 fps"), (50.0, "#e0a000", "50 ms load limit")):
        if ref <= ymax:
            out.append(f'<line x1="{L}" y1="{Y(ref):.1f}" x2="{L + pw}" y2="{Y(ref):.1f}" stroke="{col}" stroke-dasharray="6,4"/>')
            out.append(f'<text x="{L + pw - 4}" y="{Y(ref) - 4:.1f}" text-anchor="end" fill="{col}">{name}</text>')
    tick = 10 ** math.floor(math.log10(tmax)) if tmax > 0 else 1
    if tmax / tick < 4:
        tick /= 2
    x = 0.0
    while x <= tmax + 0.01:
        out.append(f'<text x="{X(x):.1f}" y="{T + ph + 18}" text-anchor="middle" fill="#666">{x:g}</text>')
        x += tick
    out.append(f'<text x="{L + pw / 2}" y="{T + ph + 36}" text-anchor="middle" fill="#444">time on route (s)</text>')
    out.append(f'<text x="18" y="{T + ph / 2}" transform="rotate(-90 18 {T + ph / 2})" text-anchor="middle" fill="#444">frame time (ms)</text>')
    for i, (name, t, ms, loads, st) in enumerate(runs):
        col = COLORS[i % len(COLORS)]
        for lt in loads:
            out.append(f'<line x1="{X(lt):.1f}" y1="{T + ph}" x2="{X(lt):.1f}" y2="{T + ph + 6}" stroke="{col}"/>')
        # decimate to at most ~3 points per pixel column, keeping the maximum (spikes stay visible)
        cols = {}
        for ts, v in zip(t, ms):
            k = int(X(ts))
            cols[k] = max(cols.get(k, 0.0), v)
        pts = " ".join(f"{k},{Y(v):.1f}" for k, v in sorted(cols.items()))
        out.append(f'<polyline fill="none" stroke="{col}" stroke-width="1" points="{pts}"/>')
        ly = T + ph + 60 + i * 22
        out.append(f'<rect x="{L}" y="{ly - 10}" width="14" height="10" fill="{col}"/>')
        out.append(f'<text x="{L + 22}" y="{ly}">{html.escape(name)}: avg {st["fps_avg"]:.1f} fps, 1 % low {st["fps_1pct_low"]:.1f} fps, '
                   f'worst frame {st["worst_ms"]:.1f} ms, worst while a cell loads {st["worst_load_ms"]:.1f} ms '
                   f'({st["loads"]} cell loads, {st["frames"]} frames, {st["seconds"]:.0f} s)</text>')
    out.append("</svg>")
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    for name, *_r, st in runs:
        print(f"{name}: avg {st['fps_avg']:.1f} fps, 1% low {st['fps_1pct_low']:.1f}, worst {st['worst_ms']:.1f} ms, worst load {st['worst_load_ms']:.1f} ms")
    print("wrote", a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
