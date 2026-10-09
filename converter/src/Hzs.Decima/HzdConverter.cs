using System.Diagnostics;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Archive;
using Hzs.Decima.Core;
using Hzs.Decima.Machines;
using Hzs.Decima.Sheets;
using Hzs.Generated;

namespace Hzs.Decima;

/// <summary>HZD side of the converter (owner: "svet"). Reads the player's HZD install, writes cache/hzd/.</summary>
public static class HzdConverter
{
    /// <summary>Bump when the HZD cache layout or conversion changes (forces re-conversion of hzd/ assets).</summary>
    public const int HzdFormat = 1;

    /// <summary>Steam build id of the HZD install (&lt;lib&gt;/steamapps/appmanifest_1151640.acf), or null.</summary>
    public static string? HzdBuild(string hzdDir)
    {
        try
        {
            var acf = Path.GetFullPath(Path.Combine(hzdDir, "..", "..", "appmanifest_1151640.acf"));
            if (!File.Exists(acf)) return null;
            foreach (var line in File.ReadLines(acf))
            {
                var parts = line.Split('"', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Where(x => x.Length > 0).ToArray();
                if (parts.Length >= 2 && parts[0] == "buildid") return parts[1];
            }
        }
        catch (IOException) { }
        return null;
    }

    /// <summary>True when the cache was converted from this HZD build with this converter format.</summary>
    private static bool Stamped(ConvContext ctx)
    {
        var m = ManifestFile.Read(ctx.Cache);
        return m["hzd_build"]?.ToString() == (HzdBuild(ctx.HzdDir!) ?? "unknown") && m["hzd_format"]?.ToString() == HzdFormat.ToString();
    }

    private static void Stamp(ConvContext ctx) => ManifestFile.Update(ctx.Cache, m =>
    {
        var b = HzdBuild(ctx.HzdDir!);
        m["hzd_build"] = long.TryParse(b, out var n) ? n : b ?? "unknown";
        m["hzd_format"] = HzdFormat;
    });

    private static HzdArchive Archive(ConvContext ctx) =>
        HzdArchive.Open(ctx.HzdDir ?? throw new ArgumentException("--hzd <dir> is required"));

    /// <summary>Optional dev filter: --only id1,id2 on the command line.</summary>
    private static HashSet<string>? Only()
    {
        var a = Environment.GetCommandLineArgs();
        var i = Array.IndexOf(a, "--only");
        return i >= 0 && i + 1 < a.Length ? a[i + 1].Split(',').ToHashSet(StringComparer.Ordinal) : null;
    }

    private static readonly HashSet<string> MachineListColumns = ["model_parts", "textures", "sound_banks", "weak_spot_bones", "leg_chains"];

    /// <summary>Watcher, Strider, Grazer: skinned models with the real skeleton, textures, meta, sounds.</summary>
    public static long ConvertMachines(ConvContext ctx, IProgressSink progress)
    {
        var arc = Archive(ctx);
        var res = new Resolver(arc);
        long bytes = 0;
        var only = Only();
        var rows = MachinesSheet.All.Where(r => only is null || only.Contains(r.Id)).ToList();
        var force = Environment.GetCommandLineArgs().Contains("--force");
        if (!force && Stamped(ctx) && File.Exists(Path.Combine(ctx.Cache.Hzd, "machines.json"))
            && rows.All(r => File.Exists(Path.Combine(ctx.Cache.Machine(r.Id), "model.glb")) && File.Exists(Path.Combine(ctx.Cache.Machine(r.Id), "meta.json"))))
        {
            ctx.Log.Info($"hzd machines up to date ({HzdBuild(ctx.HzdDir!)})");
            progress.Report("machines", rows.Count, rows.Count);
            return 0;
        }

        // resolved sheet bindings (hzd/machines.json, hzd/systems.json)
        var resolved = HzdBindings.ResolveRows(res, MachinesSheet.All, r => r.Id, MachineListColumns);
        foreach (var e in resolved["_errors"]!.AsArray()) ctx.Log.Warn($"machines binding: {e}");
        Atomic.WriteJson(Path.Combine(ctx.Cache.Hzd, "machines.json"), resolved);
        var systems = HzdBindings.ResolveSystems(res, SystemsSheet.All);
        Atomic.WriteJson(Path.Combine(ctx.Cache.Hzd, "systems.json"), systems);

        var i = 0;
        foreach (var row in rows)
        {
            ctx.Ct.ThrowIfCancellationRequested();
            progress.Report("machines", i++, rows.Count);
            var sw = Stopwatch.StartNew();
            var target = ctx.Cache.Machine(row.Id);
            var tmp = Atomic.BeginDir(target);
            var builder = new MachineBuilder(res, row, resolved[row.Id] as JsonObject, ctx.Log);
            var result = builder.Build();
            // leg chains are derived from the bound skeleton + bind pose: the resolved value is the derived list
            if (resolved[row.Id] is JsonObject rr)
                rr["leg_chains"] = new JsonArray(builder.LegChains().Select(c => (JsonNode)string.Join(">", c)).ToArray());
            File.WriteAllBytes(Path.Combine(tmp, "model.glb"), result.Glb);
            var meta = result.Meta;
            if (resolved[row.Id] is JsonObject rv)
            {
                meta["hzd_health"] = rv["hzd_health"]?.DeepClone();
                meta["perception"] = new JsonObject
                {
                    ["sight_range_m"] = rv["sight_range_m"]?.DeepClone(),
                    ["sight_half_angle_deg"] = rv["sight_fov_deg"]?.DeepClone(),
                    ["peripheral_range_m"] = rv["peripheral_range_m"]?.DeepClone(),
                    ["hearing_range_m"] = rv["hearing_range_m"]?.DeepClone(),
                    ["immediate_suspicion_m"] = rv["immediate_suspicion_m"]?.DeepClone(),
                    ["immediate_alert_m"] = rv["immediate_alert_m"]?.DeepClone(),
                };
            }
            Audio.MachineSounds.Export(res, row.HzdInternalName, JsonNode.Parse(row.SoundRoles)!.AsArray().Select(x => x!.GetValue<string>()), tmp, ctx.Log);
            Atomic.WriteJson(Path.Combine(tmp, "meta.json"), meta);
            Atomic.CommitDir(tmp, target);
            Atomic.WriteJson(Path.Combine(ctx.Cache.Hzd, "machines.json"), resolved);
            var size = Sizes.DirBytes(target);
            bytes += size;
            ctx.Log.Info($"machine {row.Id}: {result.Vertices} vertices, {result.Joints} joints, height {result.HeightM:F2} m, {size} bytes, {sw.ElapsedMilliseconds} ms");
        }
        Stamp(ctx);
        progress.Report("machines", rows.Count, rows.Count);
        return bytes;
    }

    /// <summary>World index: cell grid, start cell, campfires, spawn sites (hzd/index.json).</summary>
    public static long BuildIndex(ConvContext ctx, IProgressSink progress) =>
        World.WorldIndex.Build(ctx, new Resolver(Archive(ctx)), progress);

    /// <summary>Start cell from hzd/index.json (after BuildIndex).</summary>
    public static (int X, int Y) StartCell(ConvContext ctx) => World.WorldIndex.StartCell(ctx.Cache);

    /// <summary>One world cell: terrain, instances, vegetation, campfires, spawns (hzd/cells/X_Y/).</summary>
    public static long ConvertCell(ConvContext ctx, int x, int y, IProgressSink progress)
    {
        var bytes = World.CellConverter.Convert(ctx, new Resolver(Archive(ctx)), x, y, progress);
        if (!Stamped(ctx)) Stamp(ctx);
        return bytes;
    }

    /// <summary>True when the cell exists in the cache, has the current cell format and the cache is stamped with this HZD build.</summary>
    public static bool CellUpToDate(ConvContext ctx, int x, int y)
    {
        var path = Path.Combine(ctx.Cache.Cell(x, y), "cell.json");
        if (!File.Exists(path) || !Stamped(ctx)) return false;
        try
        {
            var cell = JsonNode.Parse(File.ReadAllText(path));
            if (cell?["format"]?.GetValue<int>() != World.CellConverter.Format) return false;
            // the game's cache GC may have deleted shared meshes/textures the cell uses: then convert it again
            var meshes = cell["meshes"]?.AsArray().Select(m => Path.Combine(ctx.Cache.Meshes, $"{m}.glb")) ?? [];
            var textures = cell["textures"]?.AsArray().Select(t => Path.Combine(ctx.Cache.Hzd, "textures", $"{t}.png")) ?? [];
            return meshes.Concat(textures).All(File.Exists);
        }
        catch (Exception) { return false; }
    }

    /// <summary>Horizon music and ambience used by the game.</summary>
    public static long ConvertAudio(ConvContext ctx, IProgressSink progress)
    {
        var arc = Archive(ctx);
        var res = new Resolver(arc);
        var root = Path.Combine(ctx.Cache.Hzd, "audio");
        var force = Environment.GetCommandLineArgs().Contains("--force");
        if (!force && Stamped(ctx) && File.Exists(Path.Combine(root, "audio.json")))
        {
            ctx.Log.Info("hzd audio up to date");
            return 0;
        }
        var tmp = Atomic.BeginDir(root);
        var index = new JsonObject();
        long bytes = 0;
        progress.Report("audio", 0, 3);

        // music cues from sheet hzd_content audio.music_cues (exact names, ends_with, family ordered by suffix/name, max)
        var music = new Audio.Music(res);
        var cues = new List<(string File, Audio.Music.Track[] Tracks)>();
        foreach (var (cue, spec) in HzdNames.Json("audio.music_cues").AsObject())
        {
            var list = new List<Audio.Music.Track>();
            foreach (var n in spec?["exact"]?.AsArray() ?? [])
            {
                var name = n!.GetValue<string>();
                if (name.StartsWith('@')) name = SystemsSheet.All.First(r => r.Id == name[1..]).Value.Trim('"'); // @systems row
                if (music.Tracks.FirstOrDefault(t => t.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) is { } tr) list.Add(tr);
            }
            foreach (var n in spec?["ends_with"]?.AsArray() ?? [])
                if (music.Tracks.FirstOrDefault(t => t.Name.EndsWith(n!.GetValue<string>(), StringComparison.OrdinalIgnoreCase)) is { } tr) list.Add(tr);
            if (spec?["family"]?.GetValue<string>() is { } fam)
            {
                var famTracks = music.Tracks.Where(t => t.Name.Contains(fam, StringComparison.OrdinalIgnoreCase));
                famTracks = spec["order"]?.GetValue<string>() == "suffix"
                    ? famTracks.OrderBy(t => t.Name[(t.Name.LastIndexOf('-') + 1)..], StringComparer.Ordinal)
                    : famTracks.OrderBy(t => t.Name, StringComparer.Ordinal);
                if (spec["max"]?.GetValue<int>() is { } max) famTracks = famTracks.Take(max);
                list.AddRange(famTracks);
            }
            cues.Add((cue, list.ToArray()));
        }
        var mj = new JsonObject();
        Directory.CreateDirectory(Path.Combine(tmp, "music"));
        foreach (var (file, tracks) in cues)
        {
            if (tracks.Length == 0) { ctx.Log.Warn($"music cue {file}: no tracks"); continue; }
            var data = music.Join(tracks);
            File.WriteAllBytes(Path.Combine(tmp, "music", file + ".mp3"), data);
            bytes += data.Length;
            mj[file] = new JsonObject { ["file"] = $"music/{file}.mp3", ["tracks"] = new JsonArray(tracks.Select(t => (JsonNode)t.Name).ToArray()) };
        }
        index["music"] = mj;
        index["music_explore"] = HzdNames.Str("audio.cue_explore");
        index["music_combat"] = HzdNames.Str("audio.cue_combat");
        progress.Report("audio", 1, 3);

        // ambience: the conifer-forest environment's bird calls (the wind/rain beds are 6-channel ATRAC9) + campfire loop
        var amb = new JsonArray();
        Directory.CreateDirectory(Path.Combine(tmp, "ambience"));
        var counters = new Dictionary<string, int>();
        var minSeconds = HzdNames.Num("audio.ambience_min_seconds");
        var perBank = HzdNames.Int("audio.ambience_per_bank");
        void ExportFolder(string folder, string prefix, int max)
        {
            var n = 0;
            foreach (var p in arc.Paths.Where(p => p.StartsWith(folder, StringComparison.Ordinal)).OrderBy(p => p, StringComparer.Ordinal))
            {
                if (n >= max) break;
                var f = res.TryFile(p);
                if (f is null) continue;
                foreach (var w in f.All("WaveResource"))
                {
                    if (n >= max) break;
                    var e = Audio.Waves.Export(arc, w);
                    if (e is null || e.Seconds < minSeconds) continue;
                    n++;
                    var k = counters.GetValueOrDefault(prefix);
                    counters[prefix] = k + 1;
                    var fn = $"{prefix}_{k}.{e.Ext}";
                    File.WriteAllBytes(Path.Combine(tmp, "ambience", fn), e.Data);
                    bytes += e.Data.Length;
                    amb.Add(new JsonObject { ["file"] = $"ambience/{fn}", ["kind"] = prefix, ["source"] = p, ["seconds"] = Math.Round(e.Seconds, 2) });
                }
            }
        }
        var envPath = SystemsSheet.AudioAmbienceTrack.Value.Trim('"'); // sheet systems audio.ambience_track
        var env = res.TryFile(envPath);
        if (env is not null)
            foreach (var es in env.All("EnvironmentSound").Take(HzdNames.Int("audio.ambience_banks_max")))
            {
                var bank = es.Ref("Sound").Path;
                if (bank is null) continue;
                var folder = bank[..(bank.LastIndexOf('/') + 1)];
                ExportFolder(folder, HzdNames.Str("audio.ambience_kind"), perBank);
            }
        foreach (var extra in HzdNames.Json("audio.ambience_extra").AsArray())
            ExportFolder(extra!["folder"]!.GetValue<string>(), extra["kind"]!.GetValue<string>(), perBank);
        index["ambience"] = amb;
        index["ambience_source"] = envPath;
        progress.Report("audio", 2, 3);

        var json = System.Text.Encoding.UTF8.GetBytes(index.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        File.WriteAllBytes(Path.Combine(tmp, "audio.json"), json);
        Atomic.CommitDir(tmp, root);
        progress.Report("audio", 3, 3);
        ctx.Log.Info($"audio: {mj.Count} music cues, {amb.Count} ambience sounds, {bytes} bytes");
        return Sizes.DirBytes(root);
    }
}
