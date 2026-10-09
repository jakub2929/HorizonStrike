using System.Diagnostics;
using System.Text.RegularExpressions;
using Hzs.Decima.Archive;
using Hzs.Decima.Core;
using Hzs.Decima.World;

namespace Hzs.Decima;

/// <summary>Developer commands (hzd-ls, hzd-dump). They only read the HZD install; output goes to stdout or --out.</summary>
public static partial class HzdDev
{
    // default cell of the dev commands = sheet systems streaming.start_cell
    private static int[] Start => System.Text.Json.JsonSerializer.Deserialize<int[]>(Hzs.Generated.SystemsSheet.StreamingStartCell.Value)!;
    private static int StartX => Start[0];
    private static int StartY => Start[1];

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
            case "hzd-world":
                {
                    // dev: convert many cells (ring around the start or --all) and report time/size/failures per cell
                    var cacheDir = Get("--cache") ?? throw new ArgumentException("--cache <dir>");
                    var cache = new Hzs.Common.CachePaths(cacheDir);
                    using var log = new Hzs.Common.Log(Get("--log-dir") ?? Path.Combine(cache.Root, "logs"));
                    var ctx = new Hzs.Common.ConvContext(null, hzd, cache, log, CancellationToken.None);
                    var res = new Resolver(arc);
                    var tiles = WorldTiles.Scan(arc).Terrain.ToList();
                    var ring = int.TryParse(Get("--ring"), out var rr) ? rr : 1;
                    var cells = tiles.Where(t => Has("--all") || Math.Max(Math.Abs(t.X - StartX), Math.Abs(t.Y - StartY)) <= ring)
                        .OrderBy(t => Math.Max(Math.Abs(t.X - StartX), Math.Abs(t.Y - StartY))).ThenBy(t => t.X).ThenBy(t => t.Y).ToList();
                    var workers = int.TryParse(Get("--workers"), out var ww) ? ww : 1;
                    var results = new System.Collections.Concurrent.ConcurrentBag<string>();
                    var sink = new NullSink();
                    var fails = 0;
                    Parallel.ForEach(cells, new ParallelOptions { MaxDegreeOfParallelism = workers }, c =>
                    {
                        var t0 = Stopwatch.StartNew();
                        try
                        {
                            CellConverter.Convert(ctx, res, c.X, c.Y, sink);
                            var cj = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(Path.Combine(cache.Cell(c.X, c.Y), "cell.json")))!;
                            var line = $"{c.X},{c.Y} ok {t0.ElapsedMilliseconds} ms real={cj["terrain"]!["real"]} instances={cj["instances"]!.AsArray().Count} campfires={cj["campfires"]!.AsArray().Count} spawns={cj["spawns"]!.AsArray().Count} cell_bytes={Hzs.Common.Sizes.DirBytes(cache.Cell(c.X, c.Y))}";
                            results.Add(line);
                            Console.WriteLine(line);
                        }
                        catch (Exception ex)
                        {
                            Interlocked.Increment(ref fails);
                            var line = $"{c.X},{c.Y} FAIL {t0.ElapsedMilliseconds} ms {ex.GetType().Name}: {ex.Message}";
                            results.Add(line);
                            Console.WriteLine(line);
                        }
                    });
                    Console.WriteLine($"cells {cells.Count}, failed {fails}, total {sw.Elapsed.TotalSeconds:F0} s, cache hzd {Hzs.Common.Sizes.DirBytes(cache.Hzd)} bytes");
                    return fails == 0 ? 0 : 1;
                }
            case "hzd-sites":
                {
                    // variant-B site table for the whole main world (markdown)
                    using var log = new Hzs.Common.Log(null);
                    var res = new Resolver(arc);
                    var tiles = WorldTiles.Scan(arc).All;
                    var rows = new List<string>();
                    var byType = new SortedDictionary<string, (int Sites, int Orig, int New, string Machine, string Rule)>(StringComparer.Ordinal);
                    foreach (var (tx, ty) in tiles)
                        foreach (var s in new RobotSites(res, log).ForTile(tx, ty))
                        {
                            rows.Add($"| {tx},{ty} | {s.Site} | {s.OrigType} | {s.OrigMin}-{s.OrigMax} | {(s.Populate ? s.Type : "(not populated)")} | {s.Count} | {s.Rule} |");
                            var e = byType.GetValueOrDefault(s.OrigType);
                            byType[s.OrigType] = (e.Sites + 1, e.Orig + (s.OrigMin + s.OrigMax) / 2, e.New + s.Count, s.Type ?? "-", s.Rule);
                        }
                    Console.WriteLine("| tile | site | original | orig count | v1 machine | count | rule |");
                    Console.WriteLine("|---|---|---|---|---|---|---|");
                    foreach (var r in rows) Console.WriteLine(r);
                    Console.WriteLine();
                    Console.WriteLine("| original | groups | orig machines (mean) | v1 machine | v1 machines | rule |");
                    Console.WriteLine("|---|---|---|---|---|---|");
                    foreach (var (k, v) in byType) Console.WriteLine($"| {k} | {v.Sites} | {v.Orig} | {v.Machine} | {v.New} | {v.Rule} |");
                    Console.WriteLine($"{rows.Count} site groups in {tiles.Count} tiles, {sw.ElapsedMilliseconds} ms");
                    return 0;
                }
            case "hzd-meshinfo":
                {
                    // dev: LOD chain and effect texture bindings of one mesh resource (--path core [--index n])
                    var res = new Resolver(arc);
                    var f = res.File(Get("--path") ?? throw new ArgumentException("--path"));
                    var idx = int.TryParse(Get("--index"), out var ix) ? ix : f.Objects.FindIndex(o => o.TypeName is "LodMeshResource" or "StaticMeshResource");
                    var o = f.Objects[idx];
                    var obj = f.Decode(o);
                    Console.WriteLine($"{f.Path}#{idx} {obj.Type} \"{obj.Str("Name")}\"");
                    var meshes = obj.Type == "LodMeshResource" ? obj.Structs("Meshes").Select(p => res.Deref(f, p.Ref("Mesh"))).ToList() : [obj];
                    foreach (var m in meshes.Where(m => m is not null))
                    {
                        Console.WriteLine($"  {m!.Type} \"{m.Str("Name")}\" verts {Assets.MeshReader.CountVertices(res, m)}");
                        if (!m.Has("Primitives")) continue;
                        var effs = m.Type == "StaticMeshResource" ? m.Refs("RenderEffects") : m.Refs("RenderFxResources");
                        foreach (var er in effs.Take(3))
                        {
                            var e = res.Deref(m, er);
                            if (e is null) continue;
                            Console.WriteLine($"    effect \"{e.Str("Name")}\"");
                            foreach (var ts in e.Structs("TechniqueSets"))
                                foreach (var t in ts.Structs("RenderTechniques"))
                                    foreach (var tb in t.Structs("TextureBindings"))
                                    {
                                        var r = tb.Ref("TextureResource");
                                        if (!r.IsNull) Console.WriteLine($"      tex {r.Path} -> {res.Target(e.File!, r)?.TypeName}");
                                    }
                        }
                        break;
                    }
                    return 0;
                }
            case "hzd-meshes":
                {
                    // dev: why do meshes of a tile come out empty? prints the LOD structure of the first N failures
                    var c = (Get("--cell") ?? $"{StartX},{StartY}").Split(',').Select(int.Parse).ToArray();
                    using var log = new Hzs.Common.Log(null);
                    var res = new Resolver(arc);
                    var pl = new Placements(res, log).ForTile(c[0], c[1]);
                    var shown = 0; var ok = 0; var bad = 0;
                    foreach (var u in pl.Select(p => (p.MeshFile, p.MeshUuid)).Distinct())
                    {
                        var f = res.File(u.MeshFile);
                        var o = f.Find(u.MeshUuid)!;
                        var (md, lod, lods) = Assets.MeshReader.ReadBudget(res, f, o, 12000);
                        if (md is not null && md.Prims.Count > 0) { ok++; continue; }
                        bad++;
                        if (shown++ >= (int.TryParse(Get("--top"), out var tt) ? tt : 5)) continue;
                        var obj = f.Decode(o);
                        Console.WriteLine($"{u.MeshFile}#{o.Index} {obj.Type} \"{obj.Str("Name")}\" lod {lod}/{lods}");
                        if (obj.Type == "LodMeshResource")
                            foreach (var part in obj.Structs("Meshes"))
                            {
                                var m = res.Deref(f, part.Ref("Mesh"));
                                var flags = m?.Has("DrawFlags") == true ? (uint)m.Struct("DrawFlags").Long("Data") : 0;
                                Console.WriteLine($"   d={part.Float("Distance")} {m?.Type} verts={(m is null ? -1 : Assets.MeshReader.CountVertices(res, m))} drawflags={flags:X} prims={(m?.Has("Primitives") == true ? m.Refs("Primitives").Length : -1)}");
                            }
                    }
                    Console.WriteLine($"ok {ok} empty {bad}");
                    return 0;
                }
            case "hzd-cellstats":
                {
                    var c = (Get("--cell") ?? $"{StartX},{StartY}").Split(',').Select(int.Parse).ToArray();
                    using var log = new Hzs.Common.Log(null);
                    var res = new Resolver(arc);
                    var pl = new Placements(res, log).ForTile(c[0], c[1]);
                    Console.WriteLine($"placements {pl.Count}, unique meshes {pl.Select(p => (p.MeshFile, p.MeshUuid)).Distinct().Count()}, {sw.ElapsedMilliseconds} ms");
                    foreach (var g in pl.GroupBy(p => p.Layer).OrderByDescending(g => g.Count()))
                        Console.WriteLine($"  {g.Key,-60} {g.Count(),6} instances {g.Select(p => (p.MeshFile, p.MeshUuid)).Distinct().Count(),5} meshes");
                    var inside = pl.Count(p => WorldXf.TileOf(p.World.Translation) == (c[0], c[1]));
                    var dup = pl.GroupBy(p => (p.MeshFile, p.MeshUuid, (int)MathF.Round(p.World.M41 * 20), (int)MathF.Round(p.World.M42 * 20), (int)MathF.Round(p.World.M43 * 20)))
                        .Where(g => g.Count() > 1).ToList();
                    Console.WriteLine($"  duplicates (same mesh within 5 cm): {dup.Sum(g => g.Count() - 1)}; layer pairs: {string.Join(", ", dup.Select(g => string.Join("+", g.Select(p => p.Layer).Distinct().Order())).GroupBy(x => x).Select(g => $"{g.Key} x{g.Count()}").Take(6))}");
                    Console.WriteLine($"  origin inside the tile: {inside} of {pl.Count}");
                    foreach (var g in pl.GroupBy(p => p.MeshFile).OrderByDescending(g => g.Count()).Take(int.TryParse(Get("--top"), out var t) ? t : 10))
                        Console.WriteLine($"  {g.Count(),6}  {g.Key}");
                    return 0;
                }
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
            case "hzd-veg":
                {
                    // dev only: placement layers of a tile -> density channel and placement target type
                    var c = (Get("--cell") ?? $"{StartX},{StartY}").Split(',').Select(int.Parse).ToArray();
                    var res = new Resolver(arc);
                    var f = res.File(Vegetation.PlacementPath(c[0], c[1]));
                    var rows = new List<string>();
                    foreach (var layer in f.All("PlacementLayer"))
                    {
                        var proc = res.Deref(layer, layer.Ref("ProcData"));
                        var pref = proc?.Type == "PlacementProceduralData" ? proc.Ref("Placement") : default;
                        var t = pref.Path is null ? null : res.Target(proc!.File!, pref)?.TypeName;
                        rows.Add($"{proc?.Type ?? "-",-26} {t ?? "-",-22} {Vegetation.ChannelOf(pref.Path ?? "") ?? "-",-14} {pref.Path}");
                    }
                    foreach (var g in rows.GroupBy(r => r).OrderByDescending(g => g.Count()).Take(int.TryParse(Get("--top"), out var tp) ? tp : 60))
                        Console.WriteLine($"{g.Count(),4} {g.Key}");
                    Console.WriteLine($"layers {rows.Count}");
                    using var vlog = new Hzs.Common.Log(Get("--log-dir"));
                    foreach (var s in new Vegetation(res, vlog).Species(c[0], c[1], 100))
                        Console.WriteLine($"  species {s.Channel,-14} layers {s.Layers,3} {s.Name,-40} {s.MeshFile}");
                    return 0;
                }
            case "hzd-tex":
                {
                    // dev only: every Texture object of a core file decoded to PNG in a scratch folder (format research)
                    var path = Get("--path") ?? throw new ArgumentException("--path <core path> is required");
                    var outDir = Get("--out") ?? throw new ArgumentException("--out <scratch dir> is required");
                    var px = int.TryParse(Get("--px"), out var pv) ? pv : 1024;
                    var res = new Resolver(arc);
                    var f = res.File(path);
                    Directory.CreateDirectory(outDir);
                    foreach (var o in f.Objects.Where(o => o.TypeName == "Texture"))
                    {
                        var tex = Assets.HzdTexture.Parse(f.Decode(o));
                        var img = tex.Decode(arc, tex.MipFor(px));
                        var dst = Path.Combine(outDir, $"{Path.GetFileName(path)}_{o.Index}.png");
                        File.WriteAllBytes(dst, img.ToPng());
                        Console.WriteLine($"#{o.Index} {tex.Name} {tex.Width}x{tex.Height} fmt {tex.Format} -> {img.Width}x{img.Height}x{img.Channels} {dst}");
                    }
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

internal sealed class NullSink : Hzs.Common.IProgressSink
{
    public void Report(string stage, int done, int total) { }
}
