using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Cs2;
using Hzs.Decima;

namespace Hzs.Cli;

/// <summary>hzsconv: converts the player's own CS2 and HZD content into the local cache (docs/ARCHITECTURE.md).</summary>
public static class Program
{
    public const string Version = "0.1.0";

    public static int Main(string[] args)
    {
        if (args.Length == 0 || args[0] is "-h" or "--help")
        {
            Console.WriteLine("""
                hzsconv 0.1.0 - converts your own CS2 and Horizon Zero Dawn content into a local cache
                  hzsconv cs2      --cs2 <dir> --cache <dir>
                  hzsconv machines --hzd <dir> --cache <dir>
                  hzsconv audio    --hzd <dir> --cache <dir>
                  hzsconv index    --hzd <dir> --cache <dir>
                  hzsconv cell     --hzd <dir> --cache <dir> --cell X,Y
                  hzsconv serve    --cs2 <dir> --hzd <dir> --cache <dir> [--workers N]
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
                case "cs2": Report(Cs2Converter.ConvertWeapons(ctx, console)); return 0;
                case "machines": Report(HzdConverter.ConvertMachines(ctx, console)); return 0;
                case "audio": Report(HzdConverter.ConvertAudio(ctx, console)); return 0;
                case "index": Report(HzdConverter.BuildIndex(ctx, console)); return 0;
                case "cell":
                    var (x, y) = opt.Cell ?? throw new ArgumentException("--cell X,Y is required");
                    Report(HzdConverter.ConvertCell(ctx, x, y, console));
                    return 0;
                case "serve":
                    return new Server(ctx, opt.Workers).Run(Console.In, Console.Out);
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

internal sealed record Options(string? Cs2, string? Hzd, string? Cache, string? LogDir, (int, int)? Cell, int Workers)
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
            int.TryParse(Get("--workers"), out var w) ? Math.Max(1, w) : 2);
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
    private readonly SemaphoreSlim _signal = new(0);
    private long _seq;
    private bool _bootstrapped;

    public Server(ConvContext ctx, int workers)
    {
        _ctx = ctx;
        _workers = workers;
        _proto = new Protocol(Console.Out);
        ctx.Log.Events = _proto;
    }

    private sealed record Job(long Id, string Op, int X, int Y, int Radius)
    {
        public int Prio { get; set; }
    }

    public int Run(TextReader input, TextWriter _)
    {
        var threads = Enumerable.Range(0, _workers).Select(i => new Thread(Worker) { IsBackground = true, Name = $"conv{i}" }).ToList();
        threads.ForEach(t => t.Start());
        string? line;
        while ((line = input.ReadLine()) is not null)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonObject req;
            try { req = JsonNode.Parse(line)!.AsObject(); }
            catch (Exception ex) { _proto.Error(-1, $"bad request: {ex.Message}"); continue; }
            var id = req["id"]?.GetValue<long>() ?? -1;
            var op = req["op"]?.GetValue<string>() ?? "";
            switch (op)
            {
                case "bootstrap":
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
                case "status":
                    lock (_lock)
                        _proto.Emit(new JsonObject
                        {
                            ["id"] = id, ["event"] = "status", ["bytes"] = Sizes.DirBytes(_ctx.Cache.Root),
                            ["pending"] = _pendingCells.Count, ["running"] = _runningCells.Count, ["bootstrapped"] = _bootstrapped,
                        });
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
                if (!_queue.TryDequeue(out job, out _)) continue;
                if (job.Op == "cell")
                {
                    // cells wait for bootstrap (index + shared data) to finish
                    if (!_bootstrapped) { _queue.Enqueue(job, (job.Prio, Interlocked.Increment(ref _seq))); Monitor.Wait(_lock, 200); _signal.Release(); continue; }
                    if (!_pendingCells.Remove((job.X, job.Y))) continue; // cancelled
                    _runningCells.Add((job.X, job.Y));
                }
            }
            var sink = new EventProgress(_proto, job.Id);
            try
            {
                long bytes;
                if (job.Op == "bootstrap") bytes = Bootstrap(job, sink);
                else bytes = HzdConverter.ConvertCell(_ctx, job.X, job.Y, sink);
                _proto.Done(job.Id, bytes, job.Op == "cell" ? new JsonObject { ["cell"] = new JsonArray(job.X, job.Y) } : null);
            }
            catch (Exception ex)
            {
                _ctx.Log.Error($"{job.Op} {job.X},{job.Y}: {ex}");
                _proto.Error(job.Id, ex.Message);
                if (job.Op == "bootstrap") lock (_lock) _bootstrapped = false;
            }
            finally
            {
                if (job.Op == "cell") lock (_lock) _runningCells.Remove((job.X, job.Y));
            }
        }
    }

    private long Bootstrap(Job job, IProgressSink sink)
    {
        long bytes = 0;
        bytes += Cs2Converter.ConvertWeapons(_ctx, sink);
        bytes += HzdConverter.ConvertMachines(_ctx, sink);
        bytes += HzdConverter.ConvertAudio(_ctx, sink);
        bytes += HzdConverter.BuildIndex(_ctx, sink);
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
            if (!Directory.Exists(_ctx.Cache.Cell(x, y)))
                bytes += HzdConverter.ConvertCell(_ctx, x, y, sink);
        }
        sink.Report("start-area", cells.Count, cells.Count);
        return bytes;
    }

    private sealed class EventProgress(Protocol proto, long id) : IProgressSink
    {
        public void Report(string stage, int done, int total) => proto.Progress(id, stage, done, total);
    }
}
