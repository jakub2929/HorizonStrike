using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Cs2;
using Hzs.Decima;

namespace Hzs.Cli;

/// <summary>hzsconv: converts the player's own CS2 and HZD content into the local cache (docs/ARCHITECTURE.md).</summary>
public static class Program
{
    public const string Version = "0.2.0";

    public static int Main(string[] args)
    {
        if (args.Length == 0 || args[0] is "-h" or "--help")
        {
            Console.WriteLine("""
                hzsconv 0.2.0 - converts your own CS2 and Horizon Zero Dawn content into a local cache
                  hzsconv cs2      --cs2 <dir> --cache <dir> [--only-stats] [--force] [--only id,id]
                  hzsconv knives   --cs2 <dir> --cache <dir> [--force] [--only id,id]
                  hzsconv machines --hzd <dir> --cache <dir>
                  hzsconv audio    --hzd <dir> --cache <dir>
                  hzsconv index    --hzd <dir> --cache <dir>
                  hzsconv cell     --hzd <dir> --cache <dir> --cell X,Y
                  hzsconv serve    --cs2 <dir> --hzd <dir> --cache <dir> [--workers N] [--idle-release-s N] [--idle-exit-s N]
                """);
            return args.Length == 0 ? 2 : 0;
        }

        // HZD developer commands (hzd-ls, hzd-dump): read-only inspection, no cache needed
        if (args[0].StartsWith("hzd-", StringComparison.Ordinal))
        {
            try { return HzdDev.Run(args); }
            catch (Exception ex) { Console.Error.WriteLine($"error: {ex.Message}"); return 1; }
        }

        var opt = Options.Parse(args.Skip(1).ToArray());
        if (opt.Cache is null) { Console.Error.WriteLine("--cache <dir> is required"); return 2; }
        var cache = new CachePaths(opt.Cache);
        Directory.CreateDirectory(cache.Root);
        using var log = new Log(opt.LogDir ?? cache.LogDir);
        log.Info($"hzsconv {Version} {args[0]} cs2={opt.Cs2} hzd={opt.Hzd} cache={cache.Root}");
        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
        var ctx = new ConvContext(opt.Cs2, opt.Hzd, cache, log, cts.Token);
        var console = new ConsoleProgress(log);

        try
        {
            switch (args[0])
            {
                case "cs2": Report(Cs2Converter.ConvertWeapons(ctx, console, Cs2Options.Parse(args))); return 0;
                case "knives":
                    var ko = Cs2Options.Parse(args);
                    Report(Knives.ConvertAll(ctx, console, ko.Only, ko.Force));
                    return 0;
                case "machines": Report(HzdConverter.ConvertMachines(ctx, console)); return 0;
                case "audio": Report(HzdConverter.ConvertAudio(ctx, console)); return 0;
                case "index": Report(HzdConverter.BuildIndex(ctx, console)); return 0;
                case "cell":
                    var (x, y) = opt.Cell ?? throw new ArgumentException("--cell X,Y is required");
                    Report(HzdConverter.ConvertCell(ctx, x, y, console));
                    return 0;
                case "serve":
                    return new Server(ctx, opt.Workers, opt.IdleReleaseS, opt.IdleExitS).Run(Console.In, Console.Out);
                default:
                    Console.Error.WriteLine($"unknown command {args[0]}");
                    return 2;
            }
        }
        catch (Exception ex)
        {
            log.Error(ex.ToString());
            Console.Error.WriteLine($"error: {ex.Message}");
            return 1;
        }
    }

    private static void Report(long bytes) => Console.WriteLine($"done: {bytes} bytes written");

    private sealed class ConsoleProgress(Log log) : IProgressSink
    {
        public void Report(string stage, int done, int total) => log.Info($"{stage} {done}/{total}");
    }
}

internal sealed record Options(string? Cs2, string? Hzd, string? Cache, string? LogDir, (int, int)? Cell, int Workers, int IdleReleaseS = 5, int IdleExitS = 0)
{
    public static Options Parse(string[] a)
    {
        string? Get(string name)
        {
            var i = Array.IndexOf(a, name);
            return i >= 0 && i + 1 < a.Length ? a[i + 1] : null;
        }
        (int, int)? cell = null;
        if (Get("--cell") is { } c)
        {
            var p = c.Split(',');
            cell = (int.Parse(p[0]), int.Parse(p[1]));
        }
        return new Options(Get("--cs2"), Get("--hzd"), Get("--cache"), Get("--log-dir"), cell,
            int.TryParse(Get("--workers"), out var w) ? Math.Max(1, w) : 2,
            int.TryParse(Get("--idle-release-s"), out var ir) ? Math.Max(0, ir) : 5,
            int.TryParse(Get("--idle-exit-s"), out var ie) ? Math.Max(0, ie) : 0);
    }
}

/// <summary>JSON-lines server for the game: bootstrap first, then cell requests by priority.</summary>
internal sealed class Server
{
    private readonly ConvContext _ctx;
    private readonly int _workers;
    private readonly Protocol _proto;
    private readonly object _lock = new();
    private readonly PriorityQueue<Job, (int, long)> _queue = new();
    private readonly Dictionary<(int, int), Job> _pendingCells = new();
    private readonly HashSet<(int, int)> _runningCells = new();
    private readonly Dictionary<string, Job> _knifeJobs = new(); // knife id -> its queued or running job (one per knife)
    private readonly SemaphoreSlim _signal = new(0);
    private long _seq;
    private int _allowed;  // jobs that may run at once (op "throttle"); <= _workers
    private int _running;  // jobs running now
    private readonly int _idleReleaseS, _idleExitS;
    private long _lastActivity = Environment.TickCount64; // last request or finished job
    private bool _released = true;                          // caches already released since the last activity
    private bool _bootstrapped;
    private int _bootstrapActive; // queued or running bootstrap jobs: cells wait for them (start area first)

    public Server(ConvContext ctx, int workers, int idleReleaseS = 5, int idleExitS = 0)
    {
        _idleReleaseS = idleReleaseS;
        _idleExitS = idleExitS;
        _ctx = ctx;
        _workers = workers;
        _allowed = workers;
        _proto = new Protocol(Console.Out);
        ctx.Log.Events = _proto;
    }

    private sealed record Job(long Id, string Op, int X, int Y, int Radius)
    {
        public int Prio { get; set; }
        public string? Name { get; init; }                // op knife: knife id
        public List<long> Waiters { get; } = [];          // op knife: request ids that get this knife's done event
        public IReadOnlyList<string>? Names { get; init; } // op knives: requested ids (null = all)
    }

    public int Run(TextReader input, TextWriter _)
    {
        // the game runs next to us: never compete with its main / render threads
        try { System.Diagnostics.Process.GetCurrentProcess().PriorityClass = System.Diagnostics.ProcessPriorityClass.BelowNormal; }
        catch (Exception ex) { _ctx.Log.Warn($"process priority: {ex.Message}"); }
        var threads = Enumerable.Range(0, _workers).Select(i => new Thread(Worker) { IsBackground = true, Name = $"conv{i}", Priority = ThreadPriority.BelowNormal }).ToList();
        threads.ForEach(t => t.Start());
        new Thread(IdleWatch) { IsBackground = true, Name = "idle", Priority = ThreadPriority.BelowNormal }.Start();
        Hzs.Decima.Memory.StartGovernor(_ctx.Log.Info); // private memory soft cap (perf.converter_soft_cap_mb)
        string? line;
        while ((line = input.ReadLine()) is not null)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonObject req;
            try { req = JsonNode.Parse(line)!.AsObject(); }
            catch (Exception ex) { _proto.Error(-1, $"bad request: {ex.Message}"); continue; }
            var id = req["id"]?.GetValue<long>() ?? -1;
            var op = req["op"]?.GetValue<string>() ?? "";
            lock (_lock) { _lastActivity = Environment.TickCount64; _released = false; }
            switch (op)
            {
                case "bootstrap":
                    lock (_lock) _bootstrapActive++;
                    Enqueue(new Job(id, "bootstrap", 0, 0, req["radius"]?.GetValue<int>() ?? 1) { Prio = int.MinValue });
                    break;
                case "cell":
                    var cell = req["cell"]!.AsArray();
                    var key = (cell[0]!.GetValue<int>(), cell[1]!.GetValue<int>());
                    var prio = req["prio"]?.GetValue<int>() ?? 0;
                    lock (_lock)
                    {
                        if (_pendingCells.TryGetValue(key, out var existing)) { existing.Prio = prio; Requeue(); break; }
                        if (_runningCells.Contains(key)) break;
                    }
                    Enqueue(new Job(id, "cell", key.Item1, key.Item2, 0) { Prio = prio });
                    break;
                case "cancel":
                    var cc = req["cell"]!.AsArray();
                    lock (_lock)
                    {
                        if (_pendingCells.Remove((cc[0]!.GetValue<int>(), cc[1]!.GetValue<int>()), out var j))
                        {
                            Requeue();
                            _proto.Emit(new JsonObject { ["id"] = j.Id, ["event"] = "cancelled" });
                        }
                    }
                    break;
                case "knives":
                    {
                        // {"op":"knives","ids":[..],"prio":100}: index first, then one job per knife (default prio after cells)
                        var ids = req["ids"] is JsonArray ia ? ia.Select(x => x!.GetValue<string>()).ToList() : null;
                        Enqueue(new Job(id, "knives", 0, 0, 0) { Prio = req["prio"]?.GetValue<int>() ?? 100, Names = ids });
                    }
                    break;
                case "throttle":
                    {
                        // {"op":"throttle","workers":1,"threads":2}: in the world 1 job with 2 threads, loading screen up to
                        // the --workers count with more threads; takes effect for the next job / parallel loop
                        var w = Math.Clamp(req["workers"]?.GetValue<int>() ?? _workers, 1, _workers);
                        var t = req["threads"]?.GetValue<int>() ?? (w <= 1 ? 2 : Math.Max(1, Environment.ProcessorCount / 2));
                        Hzs.Decima.ConversionLimits.Threads = t;
                        lock (_lock) { _allowed = w; Monitor.PulseAll(_lock); }
                        _proto.Emit(new JsonObject { ["id"] = id, ["event"] = "throttled", ["workers"] = w, ["threads"] = Hzs.Decima.ConversionLimits.Threads });
                    }
                    break;
                case "status":
                    {
                        var bytes = Sizes.DirBytes(_ctx.Cache.Root); // outside the lock: can take a while on a big cache
                        lock (_lock)
                            _proto.Emit(new JsonObject
                            {
                                ["id"] = id, ["event"] = "status", ["bytes"] = bytes,
                                ["pending"] = _pendingCells.Count, ["running"] = _runningCells.Count, ["bootstrapped"] = _bootstrapped,
                                ["workers"] = _allowed, ["threads"] = Hzs.Decima.ConversionLimits.Threads,
                            });
                    }
                    break;
                case "quit":
                    _proto.Emit(new JsonObject { ["id"] = id, ["event"] = "bye" });
                    return 0;
                default:
                    _proto.Error(id, $"unknown op '{op}'");
                    break;
            }
        }
        return 0; // stdin closed: the game exited
    }

    private void Enqueue(Job job)
    {
        lock (_lock)
        {
            if (job.Op == "cell") _pendingCells[(job.X, job.Y)] = job;
            _queue.Enqueue(job, (job.Prio, Interlocked.Increment(ref _seq)));
        }
        _signal.Release();
    }

    // Re-sort after a priority change or cancel (queue is small: cells near the player).
    private void Requeue()
    {
        var jobs = new List<Job>();
        while (_queue.TryDequeue(out var j, out _)) jobs.Add(j);
        foreach (var j in jobs)
            if (j.Op != "cell" || _pendingCells.ContainsKey((j.X, j.Y)))
                _queue.Enqueue(j, (j.Prio, Interlocked.Increment(ref _seq)));
    }

    private void Worker()
    {
        while (!_ctx.Ct.IsCancellationRequested)
        {
            _signal.Wait(_ctx.Ct);
            Job? job;
            lock (_lock)
            {
                // throttle: wait until fewer than the allowed number of jobs run (the signal is passed on)
                while (_running >= _allowed && !_ctx.Ct.IsCancellationRequested) Monitor.Wait(_lock, 200);
                if (!_queue.TryDequeue(out job, out _)) continue;
                if (job.Op is "knives" or "knife" && _bootstrapActive > 0 && !_bootstrapped)
                {
                    // knife work waits for the bootstrap too (the start of play comes first)
                    _queue.Enqueue(job, (job.Prio, Interlocked.Increment(ref _seq))); Monitor.Wait(_lock, 200); _signal.Release(); continue;
                }
                if (job.Op == "cell")
                {
                    // cells wait while a bootstrap (index + shared data + start cell) is queued or running
                    if (_bootstrapActive > 0 && !_bootstrapped) { _queue.Enqueue(job, (job.Prio, Interlocked.Increment(ref _seq))); Monitor.Wait(_lock, 200); _signal.Release(); continue; }
                    if (!_pendingCells.Remove((job.X, job.Y))) continue; // cancelled
                    _runningCells.Add((job.X, job.Y));
                }
                _running++;
            }
            var sink = new EventProgress(_proto, job.Id);
            try
            {
                long bytes;
                var cached = false;
                if (job.Op == "bootstrap") bytes = Bootstrap(job, sink);
                else if (job.Op == "knives") { KnivesIndex(job, sink); continue; }
                else if (job.Op == "knife")
                {
                    List<long> waiters;
                    try
                    {
                        var (state, reason, wasCached, kb) = Knives.ConvertKnife(_ctx, job.Name!);
                        lock (_lock) { _knifeJobs.Remove(job.Name!); waiters = [.. job.Waiters]; }
                        foreach (var w in waiters)
                            _proto.Done(w, kb, new JsonObject { ["knife"] = job.Name, ["state"] = state, ["reason"] = reason, ["cached"] = wasCached });
                    }
                    catch (Exception kex)
                    {
                        lock (_lock) { _knifeJobs.Remove(job.Name!); waiters = [.. job.Waiters]; }
                        _ctx.Log.Error($"knife {job.Name}: {kex}");
                        foreach (var w in waiters) _proto.Error(w, kex.Message);
                    }
                    continue;
                }
                else if (HzdConverter.CellUpToDate(_ctx, job.X, job.Y)) { bytes = 0; cached = true; } // converted by this HZD build already
                else bytes = HzdConverter.ConvertCell(_ctx, job.X, job.Y, sink);
                _proto.Done(job.Id, bytes, job.Op == "cell" ? new JsonObject { ["cell"] = new JsonArray(job.X, job.Y), ["cached"] = cached } : null);
            }
            catch (Exception ex)
            {
                _ctx.Log.Error($"{job.Op} {job.X},{job.Y}: {ex}");
                _proto.Error(job.Id, ex.Message);
                if (job.Op == "bootstrap") lock (_lock) _bootstrapped = false;
            }
            finally
            {
                AfterJob(job.Op);
                lock (_lock) { _running--; _lastActivity = Environment.TickCount64; _released = false; Monitor.PulseAll(_lock); }
                if (job.Op == "cell") lock (_lock) _runningCells.Remove((job.X, job.Y));
                if (job.Op == "bootstrap") lock (_lock) { _bootstrapActive--; Monitor.PulseAll(_lock); }
            }
        }
    }

    // index.json (cheap), done event with the counts, then one queued "knife" job per requested knife
    private void KnivesIndex(Job job, IProgressSink sink)
    {
        var index = Knives.BuildIndex(_ctx, sink);
        var ids = Knives.ConvertibleIds(_ctx).Where(i => job.Names is null || job.Names.Contains(i)).ToList();
        _proto.Done(job.Id, 0, new JsonObject
        {
            ["knives"] = index["knives"]!.AsArray().Count, ["knives_ok"] = Knives.Count(index, "ok"),
            ["knives_failed"] = Knives.Count(index, "failed"), ["knives_pending"] = Knives.Count(index, "pending"), ["queued"] = ids.Count,
        });
        foreach (var k in ids) EnqueueKnife(job.Id, k, job.Prio);
    }

    // One job per knife: a knife already queued or running only gains the request (and a higher priority if asked)
    private void EnqueueKnife(long requestId, string knife, int prio)
    {
        Job job;
        lock (_lock)
        {
            if (_knifeJobs.TryGetValue(knife, out var existing))
            {
                existing.Waiters.Add(requestId);
                if (prio < existing.Prio) { existing.Prio = prio; Requeue(); }
                return;
            }
            job = new Job(requestId, "knife", 0, 0, 0) { Prio = prio, Name = knife };
            job.Waiters.Add(requestId);
            _knifeJobs[knife] = job;
        }
        Enqueue(job);
    }

    /// <summary>
    /// Nothing queued, nothing running: after --idle-release-s seconds the converter releases its caches (archive set,
    /// mesh exporter, compacted heap, trimmed working set; the next job re-opens the archives). With --idle-exit-s N
    /// (default 0 = never) it then announces {"event":"idle_exit","idle_s":N} and exits with code 0; the game starts it
    /// again on its next request.
    /// </summary>
    private void IdleWatch()
    {
        while (!_ctx.Ct.IsCancellationRequested)
        {
            Thread.Sleep(1000);
            lock (_lock)
            {
                var idle = _queue.Count == 0 && _running == 0 && _pendingCells.Count == 0 && _bootstrapActive == 0;
                if (!idle) continue;
                var idleS = (Environment.TickCount64 - _lastActivity) / 1000.0;
                if (!_released && _idleReleaseS > 0 && idleS >= _idleReleaseS)
                {
                    // under the lock: no worker can start a job while the caches go away
                    var before = System.Diagnostics.Process.GetCurrentProcess().PrivateMemorySize64;
                    Hzs.Decima.Memory.ReleaseCaches();
                    var after = System.Diagnostics.Process.GetCurrentProcess().PrivateMemorySize64;
                    _released = true;
                    _ctx.Log.Info($"idle {idleS:F0} s: released caches, private bytes {before >> 20} -> {after >> 20} MB");
                }
                if (_idleExitS > 0 && idleS >= _idleExitS)
                {
                    _proto.Emit(new JsonObject { ["event"] = "idle_exit", ["idle_s"] = _idleExitS });
                    _ctx.Log.Info($"idle {idleS:F0} s: exit (idle_exit)");
                    Console.Out.Flush();
                    Environment.Exit(0);
                }
            }
        }
    }

    // the job's garbage is freed now (perf.converter_soft_cap_mb), not at the next gen-2 budget
    private void AfterJob(string what)
    {
        var (before, after) = Hzs.Decima.Memory.AfterJob();
        if (after != before) _ctx.Log.Info($"{what}: private {before} -> {after} MB (compacted)");
    }

    private long Bootstrap(Job job, IProgressSink sink)
    {
        using var cap = Hzs.Decima.ConversionLimits.BeginBootstrap(); // loading screen: the larger memory soft cap
        long bytes = 0;
        bytes += Cs2Converter.ConvertWeapons(_ctx, sink);
        AfterJob("weapons");
        bytes += HzdConverter.ConvertMachines(_ctx, sink);
        AfterJob("machines");
        bytes += HzdConverter.ConvertAudio(_ctx, sink);
        AfterJob("audio");
        bytes += HzdConverter.BuildIndex(_ctx, sink);
        AfterJob("index");
        lock (_lock) { _bootstrapped = true; Monitor.PulseAll(_lock); }
        var (sx, sy) = HzdConverter.StartCell(_ctx);
        var r = job.Radius;
        var cells = new List<(int, int)>();
        for (var dy = -r; dy <= r; dy++)
            for (var dx = -r; dx <= r; dx++)
                cells.Add((sx + dx, sy + dy));
        var i = 0;
        foreach (var (x, y) in cells.OrderBy(c => Math.Abs(c.Item1 - sx) + Math.Abs(c.Item2 - sy)))
        {
            sink.Report("start-area", i++, cells.Count);
            if (!HzdConverter.CellUpToDate(_ctx, x, y))
            {
                bytes += HzdConverter.ConvertCell(_ctx, x, y, sink);
                AfterJob($"start-area cell {x},{y}");
            }
        }
        sink.Report("start-area", cells.Count, cells.Count);
        return bytes;
    }

    private sealed class EventProgress(Protocol proto, long id) : IProgressSink
    {
        public void Report(string stage, int done, int total) => proto.Progress(id, stage, done, total);
    }
}
