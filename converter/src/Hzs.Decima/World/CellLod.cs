using System.Numerics;
using System.Text.Json.Nodes;
using Hzs.Decima.Assets;
using Hzs.Decima.Sheets;
using Hzs.Generated;

namespace Hzs.Decima.World;

/// <summary>An instance of the cell for occluders / HLOD: mesh, Godot world matrix, kind and its HZD source.</summary>
public readonly record struct LodInstance(MeshRef Mesh, Matrix4x4 World, string Kind, string MeshFile, Guid MeshUuid)
{
    /// <summary>World-space axis-aligned extent of the instance's mesh bounds.</summary>
    public Vector3 WorldSize()
    {
        var mn = new Vector3(float.MaxValue); var mx = new Vector3(float.MinValue);
        for (var i = 0; i < 8; i++)
        {
            var c = new Vector3((i & 1) == 0 ? Mesh.Min.X : Mesh.Max.X, (i & 2) == 0 ? Mesh.Min.Y : Mesh.Max.Y, (i & 4) == 0 ? Mesh.Min.Z : Mesh.Max.Z);
            var w = Vector3.Transform(c, World);
            mn = Vector3.Min(mn, w); mx = Vector3.Max(mx, w);
        }
        return mx - mn;
    }
}

/// <summary>
/// Per-cell render helpers for the game's culling and distance rendering:
/// occluders = boxes for big opaque buildings / rocks (mesh bounds shrunk, so they never hide more than the mesh) and a
/// coarse terrain grid sunk below the real surface; hlod.glb = HZD's coarse LODs of the biggest buildings / rocks merged
/// into one mesh with vertex colours (average material colour), within the per-cell triangle budget.
/// </summary>
public static class CellLod
{
    public static JsonObject Occluders(TerrainData t, IEnumerable<LodInstance> instances)
    {
        var minSize = SystemsSheet.RenderOccluderMinSizeM.Value is { } ms ? float.Parse(ms, System.Globalization.CultureInfo.InvariantCulture) : 8f;
        var shrink = (float)HzdNames.Num("geometry.occluder_shrink");
        var maxBoxes = HzdNames.Int("geometry.occluder_max");
        var kinds = HzdNames.List("geometry.occluder_kinds");
        var boxes = new JsonArray();
        foreach (var inst in instances.Where(i => i.Mesh.Opaque && kinds.Contains(i.Kind))
                     .Select(i => (I: i, S: i.WorldSize())).Where(x => MathF.Max(x.S.X, MathF.Max(x.S.Y, x.S.Z)) >= minSize)
                     .OrderByDescending(x => x.S.X * x.S.Y * x.S.Z).Take(maxBoxes).Select(x => x.I))
        {
            var c = (inst.Mesh.Min + inst.Mesh.Max) / 2;
            var size = (inst.Mesh.Max - inst.Mesh.Min) * shrink;
            var g = inst.World;
            var o = Vector3.Transform(c, g);
            boxes.Add(new JsonObject
            {
                ["xf"] = new JsonArray(new[] { g.M11, g.M12, g.M13, g.M21, g.M22, g.M23, g.M31, g.M32, g.M33, o.X, o.Y, o.Z }.Select(v => (JsonNode)Math.Round(v, 4)).ToArray()),
                ["size"] = new JsonArray(Math.Round(size.X, 3), Math.Round(size.Y, 3), Math.Round(size.Z, 3)),
            });
        }
        // terrain grid: minimum height around each node, sunk
        var grid = int.Parse(SystemsSheet.RenderOccluderTerrainGrid.Value);
        var sink = float.Parse(SystemsSheet.RenderOccluderTerrainSinkM.Value, System.Globalization.CultureInfo.InvariantCulture);
        var heights = new JsonArray();
        var res = t.Res;
        var step = (res - 1) / (float)(grid - 1);
        var half = (int)MathF.Ceiling(step / 2);
        for (var r = 0; r < grid; r++)
            for (var c = 0; c < grid; c++)
            {
                int cr = (int)MathF.Round(r * step), cc = (int)MathF.Round(c * step);
                var mn = float.MaxValue;
                for (var dr = -half; dr <= half; dr++)
                    for (var dc = -half; dc <= half; dc++)
                    {
                        int rr = Math.Clamp(cr + dr, 0, res - 1), cc2 = Math.Clamp(cc + dc, 0, res - 1);
                        mn = MathF.Min(mn, t.Heights[rr * res + cc2]);
                    }
                heights.Add(Math.Round(mn - sink, 2));
            }
        return new JsonObject
        {
            ["boxes"] = boxes,
            ["terrain"] = new JsonObject { ["res"] = grid, ["spacing"] = Math.Round(TerrainReader.TileSize / (grid - 1), 4), ["heights"] = heights },
        };
    }

    /// <summary>Builds hlod.glb (cell-local positions; root node at the cell origin). Returns null when nothing qualifies.</summary>
    public static (byte[] Glb, int Triangles, int Instances)? Hlod(WorldMeshes meshes, Materials colors, IEnumerable<LodInstance> instances, Vector3 origin)
    {
        var budget = int.Parse(SystemsSheet.RenderHlodTrianglesPerCell.Value);
        var minSize = (float)HzdNames.Num("geometry.hlod_min_size_m");
        var lodVerts = HzdNames.Int("geometry.hlod_lod_vertices");
        var kinds = HzdNames.List("geometry.hlod_kinds");
        var lowCache = new Dictionary<string, (MeshData? Md, Vector3[] Cols)>();
        var pos = new List<float>(); var nrm = new List<float>(); var col = new List<float>(); var idx = new List<uint>();
        int tris = 0, count = 0;
        foreach (var inst in instances.Where(i => kinds.Contains(i.Kind)).Select(i => (I: i, S: i.WorldSize()))
                     .Where(x => MathF.Max(x.S.X, MathF.Max(x.S.Y, x.S.Z)) >= minSize)
                     .OrderByDescending(x => x.S.X * x.S.Y * x.S.Z).Select(x => x.I))
        {
            if (!lowCache.TryGetValue(inst.Mesh.Id, out var low))
            {
                var md = meshes.ReadLow(inst.MeshFile, inst.MeshUuid, lodVerts);
                var cols = md?.Prims.Select(p => AverageColor(colors, p.Effect)).ToArray() ?? [];
                lowCache[inst.Mesh.Id] = low = (md, cols);
            }
            if (low.Md is null) continue;
            var t = low.Md.Prims.Sum(p => p.Idx.Length / 3);
            if (t == 0 || tris + t > budget) continue;
            for (var pi = 0; pi < low.Md.Prims.Count; pi++)
            {
                var p = low.Md.Prims[pi];
                var baseV = (uint)(pos.Count / 3);
                var pp = (float[])p.Pos.Clone();
                Space.Points(pp);
                float[]? nn = null;
                if (p.Nrm is { } pn) { nn = (float[])pn.Clone(); Space.Points(nn); }
                var c = low.Cols[pi];
                for (var v = 0; v < p.VertexCount; v++)
                {
                    var w = Vector3.Transform(new Vector3(pp[v * 3], pp[v * 3 + 1], pp[v * 3 + 2]), inst.World) - origin;
                    pos.Add(w.X); pos.Add(w.Y); pos.Add(w.Z);
                    var n = nn is null ? Vector3.UnitY : Vector3.TransformNormal(new Vector3(nn[v * 3], nn[v * 3 + 1], nn[v * 3 + 2]), inst.World);
                    n = n.LengthSquared() > 1e-12f ? Vector3.Normalize(n) : Vector3.UnitY;
                    nrm.Add(n.X); nrm.Add(n.Y); nrm.Add(n.Z);
                    col.Add(c.X); col.Add(c.Y); col.Add(c.Z); col.Add(1f);
                }
                foreach (var i in p.Idx) idx.Add(baseV + i);
            }
            tris += t; count++;
        }
        if (tris == 0) return null;
        var glb = new Glb { Extras = new JsonObject { ["kind"] = "hlod", ["instances"] = count, ["triangles"] = tris } };
        var mat = glb.Material("hlod", null, baseColor: [1f, 1f, 1f, 1f], roughness: 0.9f);
        var attrs = new JsonObject { ["POSITION"] = glb.Floats([.. pos], 3, minMax: true), ["NORMAL"] = glb.Floats([.. nrm], 3), ["COLOR_0"] = glb.Floats([.. col], 4) };
        var mesh = glb.Mesh("hlod", [(attrs, glb.Indices([.. idx], pos.Count / 3), mat)]);
        glb.SceneRoot(glb.Node("hlod", Matrix4x4.CreateTranslation(origin), mesh));
        return (glb.ToBytes(), tris, count);
    }

    /// <summary>Linear average colour of an effect's colour map (stone for colourised assets, grey when none).</summary>
    private static Vector3 AverageColor(Materials colors, Core.Obj? effect)
    {
        var ch = colors.ForEffect(effect);
        if (ch?.Color is not { } img) return new Vector3(0.21f);
        double r = 0, g = 0, b = 0; var n = img.Width * img.Height;
        for (var i = 0; i < n; i++)
        {
            r += Lin(img.Pixels[i * img.Channels]); g += Lin(img.Pixels[i * img.Channels + Math.Min(1, img.Channels - 1)]); b += Lin(img.Pixels[i * img.Channels + Math.Min(2, img.Channels - 1)]);
        }
        return new Vector3((float)(r / n), (float)(g / n), (float)(b / n));
    }

    private static double Lin(byte c) { var s = c / 255.0; return s <= 0.04045 ? s / 12.92 : Math.Pow((s + 0.055) / 1.055, 2.4); }
}
