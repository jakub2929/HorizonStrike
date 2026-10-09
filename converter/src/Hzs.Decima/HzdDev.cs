using System.Diagnostics;
using System.Text.RegularExpressions;
using Hzs.Decima.Archive;
using Hzs.Decima.Core;
using Hzs.Decima.World;

namespace Hzs.Decima;

/// <summary>Developer commands (hzd-ls, hzd-dump). They only read the HZD install; output goes to stdout or --out.</summary>
public static partial class HzdDev
{
    public static int Run(string[] args)
    {
        string? Get(string name)
        {
            var i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
        bool Has(string name) => Array.IndexOf(args, name) >= 0;

        var hzd = Get("--hzd") ?? throw new ArgumentException("--hzd <dir> is required");
        var sw = Stopwatch.StartNew();
        var arc = HzdArchive.Open(hzd);
        switch (args[0])
        {
            case "hzd-ls":
                if (Has("--stats"))
                {
                    foreach (var p in arc.Packs) Console.WriteLine($"{p.Name,-12} files={p.Files.Length}");
                    Console.WriteLine($"unique files {arc.FileCount}, prefetch paths {arc.Paths.Count}, oodle {Oodle.LoadedFrom}, {sw.ElapsedMilliseconds} ms");
                    return 0;
                }
                if (Get("--threadcheck") is { } tcPrefix)
                {
                    // read the same files sequentially and with 4 threads; contents must match
                    var paths = arc.Paths.Where(p => p.StartsWith(tcPrefix, StringComparison.Ordinal))
                        .SelectMany(p => new[] { p, p + ".core.stream" }).Where(p => arc.SizeOf(p) >= 0).ToList();
                    var seq = paths.Select(p => Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(arc.Read(p)))).ToList();
                    var par = new string[paths.Count];
                    Parallel.For(0, paths.Count * 4, new ParallelOptions { MaxDegreeOfParallelism = 4 }, i =>
                    {
                        var h = Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(arc.Read(paths[i % paths.Count])));
                        if (h != seq[i % paths.Count]) throw new InvalidDataException($"mismatch {paths[i % paths.Count]}");
                        par[i % paths.Count] = h;
                    });
                    Console.WriteLine($"threadcheck: {paths.Count} files x4 on 4 threads identical, {sw.ElapsedMilliseconds} ms");
                    return 0;
                }
                if (Has("--tiles"))
                {
                    var t = WorldTiles.Scan(arc);
                    Console.WriteLine($"{t.All.Count} tiles, {t.Terrain.Count} terrain, x {t.MinX}..{t.MaxX}, y {t.MinY}..{t.MaxY}");
                    return 0;
                }
                {
                    var prefix = Get("--prefix") ?? "";
                    var rx = Get("--regex") is { } re ? new Regex(re) : null;
                    var n = 0; var missing = 0;
                    foreach (var p in arc.Paths)
                    {
                        if (!p.StartsWith(prefix, StringComparison.Ordinal)) continue;
                        if (rx is not null && !rx.IsMatch(p)) continue;
                        var size = arc.SizeOf(p);
                        if (size < 0) missing++;
                        var stream = arc.SizeOf(p + ".core.stream");
                        Console.WriteLine($"{p}.core{(size < 0 ? "  (not in archives)" : $"  {size}")}{(stream >= 0 ? $"  +stream {stream}" : "")}");
                        n++;
                    }
                    Console.WriteLine($"{n} .core paths{(missing > 0 ? $", {missing} not in archives" : "")}");
                    return 0;
                }
            case "hzd-dump":
                return Dump(arc, Get, Has);
            case "hzd-extract":
                {
                    // dev only: raw decompressed cores (+ streams) into a scratch folder for format research
                    var prefixes = (Get("--prefix") ?? throw new ArgumentException("--prefix is required")).Split(',');
                    var outDir = Get("--out") ?? throw new ArgumentException("--out <scratch dir> is required");
                    var rx = Get("--regex") is { } re ? new Regex(re) : null;
                    var noStream = Has("--no-stream");
                    long bytes = 0; var n = 0;
                    var list = arc.Paths.Where(p => prefixes.Any(x => p.StartsWith(x, StringComparison.Ordinal)) && (rx is null || rx.IsMatch(p))).ToList();
                    foreach (var x in prefixes)
                        if (!list.Contains(x) && arc.Exists(x)) list.Add(x); // exact paths not in the prefetch list
                    foreach (var p in list)
                    {
                        foreach (var file in noStream ? new[] { p + ".core" } : new[] { p + ".core", p + ".core.stream" })
                        {
                            var d = arc.TryRead(file);
                            if (d is null) continue;
                            var dst = Path.Combine(outDir, file.Replace('/', Path.DirectorySeparatorChar));
                            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
                            File.WriteAllBytes(dst, d);
                            bytes += d.Length; n++;
                        }
                    }
                    Console.WriteLine($"extracted {n} files, {bytes} bytes -> {outDir}");
                    return 0;
                }
            default:
                Console.Error.WriteLine($"unknown command {args[0]}");
                return 2;
        }
    }

    private static int Dump(HzdArchive arc, Func<string, string?> get, Func<string, bool> has)
    {
        var path = get("--path") ?? throw new ArgumentException("--path <core path> is required");
        var data = arc.Read(path);
        if (get("--raw") is { } rawOut)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(rawOut))!);
            File.WriteAllBytes(rawOut, data);
            Console.WriteLine($"{HzdArchive.Normalize(path)}: {data.Length} bytes -> {rawOut}");
            return 0;
        }
        if (path.EndsWith(".stream", StringComparison.Ordinal))
        {
            Console.WriteLine($"{path}: {data.Length} bytes (stream)");
            return 0;
        }
        var core = new CoreFile(HzdArchive.Normalize(path), data);
        if (get("--member") is { } member)
        {
            var value = Members.Resolve(arc, core, member);
            Console.WriteLine(value);
            return 0;
        }
        Console.WriteLine($"{core.Path}: {data.Length} bytes, {core.Objects.Count} objects ({arc.ArchiveOf(path)})");
        foreach (var o in core.Objects)
            Console.WriteLine($"  [{o.Index}] {o.TypeName} size={o.Size} uuid={o.Uuid}");
        return 0;
    }
}
