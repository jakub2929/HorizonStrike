using System.Diagnostics;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;
using Hzs.Decima.Sheets;

namespace Hzs.Decima.World;

/// <summary>
/// Converts one main-world tile into cache/hzd/cells/X_Y (Godot space: x = east, y = up, z = south).
/// cell.json "origin" is the cell's north-west corner (min x, min z) at height 0; terrain samples (row r, column c)
/// lie at origin + (c * spacing, h, r * spacing).
/// </summary>
public static class CellConverter
{
    /// <summary>cell.json "format"; bump when the cell layout changes so old cells are converted again.</summary>
    public const int Format = 8;

    public static long Convert(ConvContext ctx, Resolver res, int x, int y, IProgressSink progress)
    {
        var texPx = HzdNames.Int("terrain.albedo_px");
        var sw = Stopwatch.StartNew();
        var timers = Assets.Timers.Snapshot();
        var target = ctx.Cache.Cell(x, y);
        var written = new System.Runtime.CompilerServices.StrongBox<long>(); // shared meshes/textures this job wrote
        var tmp = Atomic.BeginDir(target);
        try
        {
            progress.Report("terrain", 0, 1);
            var terrain = TerrainReader.ReadReal(res, x, y);
            if (terrain is null)
            {
                ctx.Log.Warn($"cell {x},{y}: no readable height data, using fallback terrain");
                terrain = TerrainReader.Fallback(x, y);
            }
            File.WriteAllBytes(Path.Combine(tmp, "height.r32"), TerrainReader.ToR32(terrain.Heights));
            string? albedo = null;
            Assets.Image? albedoImg = null;
            try
            {
                albedoImg = TerrainReader.ReadAlbedo(res, x, y, texPx);
                if (albedoImg is not null)
                {
                    File.WriteAllBytes(Path.Combine(tmp, "albedo.dds"), Dds.Encode(albedoImg, Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatAlbedo.Value), true, MipMode.Color));
                    albedo = "albedo.dds";
                }
            }
            catch (Exception ex) { ctx.Log.Warn($"cell {x},{y}: albedo: {ex.Message}"); }
            string? normal = null, normalSource = null;
            try
            {
                var (nimg, nsrc) = TerrainReader.ReadNormal(res, x, y, terrain, HzdNames.Int("terrain.normal_px"));
                File.WriteAllBytes(Path.Combine(tmp, "normal.dds"), Dds.Encode(nimg, Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatNormal.Value), false, MipMode.Normal));
                (normal, normalSource) = ("normal.dds", nsrc);
            }
            catch (Exception ex) { ctx.Log.Warn($"cell {x},{y}: terrain normal: {ex.Message}"); }
            progress.Report("terrain", 1, 1);

            // static geometry: placements -> shared meshes
            var placements = Assets.Timers.Time("placements", () => new Placements(res, ctx.Log).ForTile(x, y));
            var unique = placements.Select(p => (p.MeshFile, p.MeshUuid)).Distinct().ToList();
            var meshes = Meshes(ctx, res);
            var ids = new System.Collections.Concurrent.ConcurrentDictionary<(string, Guid), MeshRef?>();
            var done = 0;
            Parallel.ForEach(unique, new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = ctx.Ct }, u =>
            {
                ids[u] = meshes.Ensure(u.MeshFile, u.MeshUuid, written);
                var d = Interlocked.Increment(ref done);
                if (d % 50 == 0) progress.Report("meshes", d, unique.Count);
            });
            progress.Report("meshes", unique.Count, unique.Count);
            var instances = new JsonArray();
            var usedMeshes = new SortedSet<string>(StringComparer.Ordinal);
            var usedTex = new SortedSet<string>(StringComparer.Ordinal);
            var tint = albedoImg is null ? null : new GroundTint(albedoImg, x, y);
            var lodInstances = new List<LodInstance>();
            foreach (var p in placements)
            {
                if (ids.GetValueOrDefault((p.MeshFile, p.MeshUuid)) is not { } m) continue;
                usedMeshes.Add(m.Id);
                foreach (var t in m.Textures) usedTex.Add(t);
                var g = Assets.Space.M(p.World);
                var kind = KindOf(p.MeshFile);
                lodInstances.Add(new LodInstance(m, g, kind, p.MeshFile, p.MeshUuid));
                var inst = new JsonObject { ["mesh"] = m.Id, ["kind"] = kind, ["xf"] = new JsonArray(Assets.Space.Xf(g).Select(v => (JsonNode)Math.Round(v, 4)).ToArray()) };
                if (m.Colorized && tint?.At(g.M41, g.M43) is { } c)
                    inst["tint"] = new JsonArray(Math.Round(c.X, 3), Math.Round(c.Y, 3), Math.Round(c.Z, 3));
                instances.Add(inst);
            }

            // campfires
            var campfires = new JsonArray(Campfires.Read(res, x, y).Select(c => (JsonNode)new JsonObject
            {
                ["id"] = c.Id,
                ["pos"] = new JsonArray(Math.Round(c.GodotPos.X, 3), Math.Round(c.GodotPos.Y, 3), Math.Round(c.GodotPos.Z, 3)),
                ["yaw_deg"] = Math.Round(c.YawDeg, 1),
            }).ToArray());

            // procedural vegetation: density map + species (the game scatters)
            JsonNode? vegetation = null;
            try
            {
                var veg = new Vegetation(res, ctx.Log);
                var density = veg.Density(x, y);
                if (density is not null)
                {
                    var maskFormat = Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatMasks.Value);
                    File.WriteAllBytes(Path.Combine(tmp, "veg_density.dds"), Dds.Encode(density, maskFormat, false, MipMode.Data));
                    var effect = veg.Effect(x, y, density.Width);
                    if (effect is not null) File.WriteAllBytes(Path.Combine(tmp, "veg_effect.dds"), Dds.Encode(effect, maskFormat, false, MipMode.Data));
                    var species = new JsonArray();
                    // a species is usable when its mesh exports with a colour texture (an untextured opaque card is never right)
                    var sp = veg.Pick(x, y, density, effect, usable: s => meshes.Ensure(s.MeshFile, s.MeshUuid, written) is { Textures.Length: > 0 });
                    var scale = HzdNames.Num("vegetation.density_scale");
                    var maxPer = HzdNames.Int("vegetation.max_instances_per_species");
                    var cluster = HzdNames.Json("vegetation.cluster");
                    var vids = new System.Collections.Concurrent.ConcurrentDictionary<int, MeshRef?>();
                    Parallel.For(0, sp.Count, new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = ctx.Ct }, i => vids[i] = meshes.Ensure(sp[i].Species.MeshFile, sp[i].Species.MeshUuid, written));
                    for (var i = 0; i < sp.Count; i++)
                    {
                        if (vids.GetValueOrDefault(i) is not { } m) continue;
                        usedMeshes.Add(m.Id);
                        foreach (var t in m.Textures) usedTex.Add(t);
                        var s = sp[i].Species;
                        var o = new JsonObject
                        {
                            ["channel"] = s.Channel,
                            ["mesh"] = m.Id,
                            ["name"] = s.Name,
                            ["per_m2"] = Math.Round(scale * s.PerM2, 5),
                            ["hzd_per_m2"] = Math.Round(s.PerM2, 5),
                            ["expected"] = (long)Math.Round(scale * sp[i].Expected),
                            ["max_instances"] = (int)Math.Min(maxPer, Math.Round(scale * sp[i].Expected)),
                            ["cluster"] = cluster[s.Channel]?.DeepClone(),
                            ["footprint_m"] = Math.Round(s.Footprint, 3),
                            ["wander_m"] = Math.Round(s.Wander, 3),
                            ["scale"] = Math.Round(s.Scale, 3),
                            ["scale_variance"] = Math.Round(s.ScaleVariance, 3),
                            ["max_slope_deg"] = Math.Round(s.MaxSlope, 1),
                        };
                        if (s.EffectLo > 0 || s.EffectHi < 1) o["effect_range"] = new JsonArray(Math.Round(s.EffectLo, 3), Math.Round(s.EffectHi, 3));
                        species.Add(o);
                    }
                    vegetation = new JsonObject
                    {
                        ["density"] = "veg_density.dds",
                        ["effect"] = effect is null ? null : "veg_effect.dds",
                        ["channels"] = new JsonArray(Vegetation.Channels.Select(c => (JsonNode)c).ToArray()),
                        ["density_scale"] = scale,
                        ["species"] = species,
                    };
                }
            }
            catch (Exception ex) { ctx.Log.Warn($"cell {x},{y}: vegetation: {ex.Message}"); }

            // water surfaces: the tile's water layer (StaticMeshInstances of water meshes; the game applies its water shader)
            JsonObject? water = null;
            try
            {
                var wp = new Placements(res, ctx.Log).ForLayerFile($"{WorldTiles.TileDir(x, y)}/{HzdNames.Fill("water.layer", ("x", x.ToString()), ("y", y.ToString()))}");
                if (wp.Count > 0)
                {
                    var wids = new System.Collections.Concurrent.ConcurrentDictionary<(string, Guid), MeshRef?>();
                    Parallel.ForEach(wp.Select(q => (q.MeshFile, q.MeshUuid)).Distinct(), new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = ctx.Ct },
                        u => wids[u] = meshes.Ensure(u.MeshFile, u.MeshUuid, written));
                    var winst = new JsonArray();
                    foreach (var q in wp)
                    {
                        if (wids.GetValueOrDefault((q.MeshFile, q.MeshUuid)) is not { } m) continue;
                        usedMeshes.Add(m.Id);
                        foreach (var t in m.Textures) usedTex.Add(t);
                        var g = Assets.Space.M(q.World);
                        winst.Add(new JsonObject { ["mesh"] = m.Id, ["xf"] = new JsonArray(Assets.Space.Xf(g).Select(v => (JsonNode)Math.Round(v, 4)).ToArray()) });
                    }
                    if (winst.Count > 0)
                        water = new JsonObject
                        {
                            ["instances"] = winst,
                            ["source"] = HzdNames.Fill("water.layer", ("x", x.ToString()), ("y", y.ToString())),
                        };
                }
            }
            catch (Exception ex) { ctx.Log.Warn($"cell {x},{y}: water: {ex.Message}"); }

            // terrain material layers: shared layer textures + per-cell blend masks (fallback from HZD world data)
            JsonObject? layers = null;
            try
            {
                var mpx = HzdNames.Int("terrain.mask_px");
                var veg2 = new Vegetation(res, ctx.Log);
                var roads = WorldData.Channel(res, x, y, HzdNames.Str("terrain.roads_map"), HzdNames.Str("terrain.roads_type"), mpx);
                var masks = TerrainLayers.Masks(terrain, veg2.Effect(x, y, mpx), veg2.Density(x, y),
                    Array.IndexOf(Vegetation.Channels, HzdNames.Str("terrain.grass_channel")), roads, mpx);
                File.WriteAllBytes(Path.Combine(tmp, "masks.dds"), Dds.Encode(masks, Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatMasks.Value), false, MipMode.Data));
                layers = new JsonObject
                {
                    ["masks"] = "masks.dds",
                    ["channels"] = new JsonArray(TerrainLayers.MaskChannels.Select(c => (JsonNode)c).ToArray()),
                    ["layers"] = TerrainLayers.EnsureShared(ctx.Cache, res, written),
                    ["source"] = "fallback: snow = ecotope effect, rock = slope, grass = undergrowth density, dirt = roads + rest",
                };
            }
            catch (Exception ex) { ctx.Log.Warn($"cell {x},{y}: terrain layers: {ex.Message}"); }

            // culling and distance rendering: occluders + merged coarse LOD proxy (hlod.glb)
            JsonObject? occluders = null, hlod = null;
            try
            {
                occluders = CellLod.Occluders(terrain, lodInstances);
                var origin = new System.Numerics.Vector3(x * TerrainReader.TileSize, 0f, -(y + 1) * TerrainReader.TileSize);
                if (CellLod.Hlod(meshes, new Materials(res, 16), lodInstances, origin) is { } h)
                {
                    File.WriteAllBytes(Path.Combine(tmp, "hlod.glb"), h.Glb);
                    hlod = new JsonObject { ["file"] = "hlod.glb", ["triangles"] = h.Triangles, ["instances"] = h.Instances };
                }
            }
            catch (Exception ex) { ctx.Log.Warn($"cell {x},{y}: occluders / hlod: {ex.Message}"); }

            // machine sites (variant B)
            var sites = new RobotSites(res, ctx.Log).ForTile(x, y);
            JsonObject SpawnJson(Spawn sp) => new()
            {
                ["site"] = sp.Site,
                ["orig_type"] = sp.OrigType,
                ["orig_count"] = new JsonArray(sp.OrigMin, sp.OrigMax),
                ["type"] = sp.Type,
                ["count"] = sp.Count,
                ["pos"] = new JsonArray(Math.Round(sp.GodotPos.X, 3), Math.Round(sp.GodotPos.Y, 3), Math.Round(sp.GodotPos.Z, 3)),
                ["radius"] = Math.Round(sp.Radius, 1),
                ["rule"] = sp.Rule,
            };
            var spawns = new JsonArray(sites.Where(sp => sp.Populate && sp.Count > 0).Select(sp => (JsonNode)SpawnJson(sp)).ToArray());
            var skipped = new JsonArray(sites.Where(sp => !(sp.Populate && sp.Count > 0)).Select(sp => (JsonNode)SpawnJson(sp)).ToArray());

            var cell = new JsonObject
            {
                ["format"] = Format,
                ["cell"] = new JsonArray(x, y),
                ["origin"] = new JsonArray(x * TerrainReader.TileSize, 0f, -(y + 1) * TerrainReader.TileSize),
                ["size"] = TerrainReader.TileSize,
                ["terrain"] = new JsonObject
                {
                    ["file"] = "height.r32",
                    ["res"] = new JsonArray(terrain.Res, terrain.Res),
                    ["spacing"] = Math.Round(terrain.Spacing, 6),
                    ["min"] = Math.Round(terrain.Min, 3),
                    ["max"] = Math.Round(terrain.Max, 3),
                    ["real"] = terrain.Real,
                    ["albedo"] = albedo,
                    ["normal"] = normal,
                    ["normal_space"] = normal is null ? null : "world_xz",
                    ["normal_source"] = normalSource,
                    ["layers"] = layers,
                    ["source"] = terrain.Source,
                },
                ["instances"] = instances,
                ["vegetation"] = vegetation,
                ["water"] = water,
                ["occluders"] = occluders,
                ["hlod"] = hlod,
                ["campfires"] = campfires,
                ["spawns"] = spawns,
                ["spawns_skipped"] = skipped,
                ["meshes"] = new JsonArray(usedMeshes.Select(m => (JsonNode)m).ToArray()),
                ["textures"] = new JsonArray(usedTex.Select(t => (JsonNode)t).ToArray()),
            };
            Atomic.WriteJson(Path.Combine(tmp, "cell.json"), cell);
            Atomic.CommitDir(tmp, target);
        }
        catch
        {
            try { Directory.Delete(tmp, true); } catch (IOException) { }
            throw;
        }
        var bytes = Sizes.DirBytes(target) + Interlocked.Read(ref written.Value);
        ctx.Log.Info($"cell {x},{y}: {bytes} bytes (cell + new shared meshes/textures), {sw.ElapsedMilliseconds} ms; cpu ms {Assets.Timers.Since(timers)}");
        return bytes;
    }

    private static readonly (string Kind, string[] Contains)[] KindRules = HzdNames.Json("geometry.kind_rules").AsArray()
        .Select(r => (r!["kind"]!.GetValue<string>(), r["contains"]!.AsArray().Select(c => c!.GetValue<string>()).ToArray())).ToArray();

    /// <summary>instances[].kind (rock, vegetation, building, prop) from the sheet rules on the mesh's core path.</summary>
    public static string KindOf(string meshFile)
    {
        foreach (var (kind, contains) in KindRules)
            if (contains.Any(c => meshFile.Contains(c, StringComparison.OrdinalIgnoreCase))) return kind;
        return "prop";
    }

    private static readonly object MeshesLock = new();
    private static WorldMeshes? _meshes;
    private static string? _meshesRoot;

    /// <summary>One shared-mesh exporter per cache root (dedupes meshes across cells and workers).</summary>
    private static WorldMeshes Meshes(ConvContext ctx, Resolver res)
    {
        lock (MeshesLock)
        {
            if (_meshes is null || _meshesRoot != ctx.Cache.Root) { _meshes = new WorldMeshes(new Resolver(res.Archive), ctx.Cache, ctx.Log); _meshesRoot = ctx.Cache.Root; }
            return _meshes;
        }
    }
}
