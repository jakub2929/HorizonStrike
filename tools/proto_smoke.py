"""Dev tool (never packaged): smoke test of the converter server protocol (hzsconv serve, JSON lines over stdio).

  python tools/proto_smoke.py --cs2 <CS2 dir> --hzd <HZD dir> --cache <scratch cache dir> [--exe <hzsconv>] [--timeout 1200]

Runs bootstrap (radius 0), status, a ring of cell requests with priorities, a priority change, a cancel, a re-request
of an already converted cell and quit. Checks: every stdout line is a JSON event, bootstrap and cells finish ok, the
cancelled cell is reported, the re-requested start cell comes back from the cache, two workers convert in parallel,
the throttle op is acknowledged and reported by status,
quit answers bye and the process exits. Prints PROTO OK (exit 0) or PROTO FAIL with reasons (exit 1).
Pure standard library.
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def arg(name, default=None):
    a = sys.argv
    return a[a.index(name) + 1] if name in a and a.index(name) + 1 < len(a) else default


def converter_cmd():
    exe = arg("--exe")
    if exe:
        return [exe] if exe.lower().endswith(".exe") else ["dotnet", exe]
    dist = os.path.join(ROOT, "dist", "converter", "hzsconv.exe")
    if os.path.exists(dist):
        return [dist]
    dll = os.path.join(ROOT, "converter", "src", "Hzs.Cli", "bin", "Release", "net10.0", "hzsconv.dll")
    if os.path.exists(dll):
        return ["dotnet", dll]
    return ["dotnet", "run", "--project", os.path.join(ROOT, "converter", "src", "Hzs.Cli"), "-c", "Release", "--"]


def main():
    cs2, hzd, cache = arg("--cs2"), arg("--hzd"), arg("--cache")
    if not (cs2 and hzd and cache):
        print(__doc__)
        return 2
    timeout = float(arg("--timeout", "1200"))
    os.makedirs(cache, exist_ok=True)
    errlog = open(os.path.join(cache, "proto_smoke_stderr.log"), "w", encoding="utf-8")
    cmd = converter_cmd() + ["serve", "--cs2", cs2, "--hzd", hzd, "--cache", cache, "--workers", "2",
                               "--log-dir", os.path.join(cache, "logs")]  # own log: the default logs/ next to the cache may be held by another converter
    print("starting:", " ".join(cmd))
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errlog, text=True, encoding="utf-8", bufsize=1)
    events = queue.Queue()
    bad_lines = []

    def reader():
        for line in p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                if not isinstance(e, dict) or "event" not in e:
                    bad_lines.append(line)
                else:
                    events.put(e)
            except ValueError:
                bad_lines.append(line)
        events.put({"event": "_eof"})

    threading.Thread(target=reader, daemon=True).start()

    def send(obj):
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()

    seen = []
    fails = []
    max_running = 0

    def wait_for(pred, limit, poll_status=False):
        nonlocal max_running
        end = time.time() + limit
        last_poll = 0
        while time.time() < end:
            if poll_status and time.time() - last_poll > 0.25:
                send({"id": 900, "op": "status"})
                last_poll = time.time()
            try:
                e = events.get(timeout=0.2)
            except queue.Empty:
                continue
            seen.append(e)
            if e.get("event") == "status":
                max_running = max(max_running, e.get("running", 0))
            if e.get("event") == "_eof":
                return None
            if pred(e):
                return e
        return None

    t0 = time.time()
    send({"id": 1, "op": "bootstrap", "radius": 0})
    e = wait_for(lambda e: e.get("id") == 1 and e.get("event") in ("done", "error"), timeout)
    if not e or e.get("event") != "done":
        fails.append("bootstrap: %s" % (e or "timeout"))
    boot_s = time.time() - t0
    print("bootstrap %.1f s -> %s" % (boot_s, e))

    send({"id": 2, "op": "status"})
    st = wait_for(lambda e: e.get("id") == 2 and e.get("event") == "status", 30)
    if not st or not st.get("bootstrapped"):
        fails.append("status after bootstrap: %s" % st)
    print("status", st)

    ring = {10: (5, -3, 5), 11: (3, -3, 4), 12: (4, -2, 3), 13: (4, -4, 2)}
    for rid, (x, y, pr) in ring.items():
        send({"id": rid, "op": "cell", "cell": [x, y], "prio": pr})
    send({"id": 14, "op": "cell", "cell": [11, 6], "prio": 50})
    send({"id": 15, "op": "cell", "cell": [5, -3], "prio": 0})  # priority change of a pending cell
    send({"id": 16, "op": "cancel", "cell": [11, 6]})
    want = {(x, y) for (x, y, _) in ring.values()}
    done = {}
    cancelled = False
    t1 = time.time()
    while want - set(done) and time.time() - t1 < timeout:
        e = wait_for(lambda e: e.get("event") in ("done", "error", "cancelled") and e.get("id") != 1, timeout - (time.time() - t1), poll_status=True)
        if not e:
            break
        if e.get("event") == "cancelled" and e.get("id") == 14:
            cancelled = True
        elif e.get("event") == "error":
            fails.append("cell error: %s" % e)
        elif e.get("event") == "done" and "cell" in e:
            done[tuple(e["cell"])] = (time.time() - t1, e)
    for c in want:
        if c not in done:
            fails.append("cell %s not done" % (c,))
        elif not os.path.exists(os.path.join(cache, "hzd", "cells", "%d_%d" % c, "cell.json")):
            fails.append("cell %s has no cell.json" % (c,))
    if not cancelled:
        fails.append("cancel of pending cell (11,6) not reported")
    if any(e.get("event") == "done" and e.get("cell") == [11, 6] for e in seen):
        fails.append("cancelled cell (11,6) was converted")
    if max_running < 2:
        fails.append("never saw 2 cells converting in parallel (max running %d)" % max_running)
    for c, (t, e) in sorted(done.items(), key=lambda kv: kv[1][0]):
        print("cell %s done after %.1f s bytes %s" % (c, t, e.get("bytes")))

    send({"id": 20, "op": "cell", "cell": [4, -3], "prio": 0})
    e = wait_for(lambda e: e.get("event") in ("done", "error") and e.get("cell") == [4, -3], 60)
    if not e or not e.get("cached"):
        fails.append("re-request of converted start cell not served from cache: %s" % e)

    # throttle (game in the world): 1 job, 2 threads; status reports it; the process runs below normal priority
    send({"id": 30, "op": "throttle", "workers": 1, "threads": 2})
    e = wait_for(lambda e: e.get("id") == 30 and e.get("event") == "throttled", 30)
    if not e or e.get("workers") != 1 or e.get("threads") != 2:
        fails.append("throttle not acknowledged as workers 1 / threads 2: %s" % e)
    send({"id": 31, "op": "status"})
    e = wait_for(lambda e: e.get("id") == 31 and e.get("event") == "status", 60)
    if not e or e.get("workers") != 1:
        fails.append("status after throttle does not report workers 1: %s" % e)
    else:
        print("throttle -> status workers %s threads %s" % (e.get("workers"), e.get("threads")))

    send({"id": 99, "op": "quit"})
    e = wait_for(lambda e: e.get("id") == 99 and e.get("event") == "bye", 30)
    if not e:
        fails.append("no bye")
    try:
        code = p.wait(timeout=30)
    except subprocess.TimeoutExpired:
        p.kill()
        code = None
        fails.append("converter did not exit after quit")
    if code not in (0, None):
        fails.append("exit code %s" % code)
    if bad_lines:
        fails.append("%d non-protocol stdout lines, first: %r" % (len(bad_lines), bad_lines[0][:200]))
    print("events %d, max parallel cells %d, exit %s" % (len(seen), max_running, code))
    if fails:
        print("PROTO FAIL")
        for f in fails:
            print("  -", f)
        return 1
    print("PROTO OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
