using Hzs.Common;
using SharpGLTF.Schema2;
using SkiaSharp;
using ValveResourceFormat.IO;
using ValveResourceFormat.ResourceTypes;

namespace Hzs.Cs2;

/// <summary>Model -> GLB through the ValveResourceFormat glTF exporter, then textures downscaled to the cache limit.</summary>
internal static class ModelExport
{
    /// <summary>sheets/systems.json cache.texture_max_px (literal, read from the generated sheet).</summary>
    public static readonly int TextureMaxPx =
        int.TryParse(Hzs.Generated.SystemsSheet.CacheTextureMaxPx.Value, out var px) && px > 0 ? px : 1024;

    private const string NoAnimations = "__hzs_no_animations__";

    /// <summary>
    /// Export a vmdl (path without _c) to GLB bytes. withSkeleton = joints + skinning (no embedded animations);
    /// otherwise a static mesh in bind pose. Mesh names containing "legacy" are dropped when other meshes exist
    /// (CS2 weapon models carry both body_legacy and body_hd).
    /// </summary>
    public static byte[] Export(Cs2Source src, string vmdlPath, string tmpDir, bool withSkeleton, Log log, CancellationToken ct)
    {
        using var res = src.Load(vmdlPath + "_c") ?? throw new FileNotFoundException($"model not found in the CS2 VPK: {vmdlPath}");
        if (res.DataBlock is not Model model) throw new InvalidDataException($"not a model: {vmdlPath}");

        var exporter = new GltfModelExporter(src.Loader)
        {
            ProgressReporter = new LogProgress(log),
            ExportMaterials = true,
            AdaptTextures = true,
            SatelliteImages = false,
            ExportAnimations = withSkeleton,
        };
        if (withSkeleton) exporter.AnimationFilter.Add(NoAnimations);
        foreach (var keep in MeshesToKeep(model)) exporter.MeshFilter.Add(keep);

        Directory.CreateDirectory(tmpDir);
        var tmp = Path.Combine(tmpDir, $"_export_{Guid.NewGuid():N}.glb");
        try
        {
            exporter.Export(res, tmp, ct);
            var glb = Glb.Parse(File.ReadAllBytes(tmp));
            glb.TransformImages(bytes => Reencode(bytes, TextureMaxPx));
            glb.Compact();
            return glb.ToBytes();
        }
        finally
        {
            foreach (var f in Directory.EnumerateFiles(tmpDir, Path.GetFileNameWithoutExtension(tmp) + "*")) File.Delete(f);
        }
    }

    private static IEnumerable<string> MeshesToKeep(Model model)
    {
        var lod = model.LodInfo.LowestLevel;
        var names = model.GetEmbeddedMeshesForLod(lod).Select(m => m.Name)
            .Concat(model.GetReferenceMeshNamesForLod(lod).Select(m => Path.GetFileNameWithoutExtension(m.MeshName)))
            .ToList();
        var nonLegacy = names.Where(n => !n.Contains("legacy", StringComparison.OrdinalIgnoreCase)).ToList();
        // an empty filter exports everything
        return nonLegacy.Count > 0 && nonLegacy.Count < names.Count ? nonLegacy : [];
    }

    /// <summary>
    /// Downscale to maxPx (aspect kept). Opaque images become JPEG (quality 90; 4:4:4 so normal maps keep their
    /// X/Y channels), images with alpha stay PNG. Returns null to keep tiny or already small JPEG/PNG data.
    /// </summary>
    public static (byte[] Data, string Mime)? Reencode(byte[] bytes, int maxPx)
    {
        using var src = SKBitmap.Decode(bytes);
        if (src is null) return null;
        var resize = Math.Max(src.Width, src.Height) > maxPx;
        var opaque = IsOpaque(src);
        if (!resize && (bytes.Length < 64 * 1024 || !opaque)) return null;

        var bmp = src;
        SKBitmap? scaled = null;
        if (resize)
        {
            var scale = (float)maxPx / Math.Max(src.Width, src.Height);
            var w = Math.Max(1, (int)MathF.Round(src.Width * scale));
            var h = Math.Max(1, (int)MathF.Round(src.Height * scale));
            scaled = new SKBitmap(new SKImageInfo(w, h, SKColorType.Rgba8888, opaque ? SKAlphaType.Opaque : SKAlphaType.Unpremul));
            if (!src.ScalePixels(scaled, new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear)))
                throw new InvalidOperationException($"texture resize failed ({src.Width}x{src.Height})");
            bmp = scaled;
        }
        try
        {
            using var pixmap = bmp.PeekPixels();
            if (opaque)
            {
                using var jpg = pixmap.Encode(new SKJpegEncoderOptions(90, SKJpegEncoderDownsample.Downsample444, SKJpegEncoderAlphaOption.Ignore))
                    ?? throw new InvalidOperationException("JPEG encode failed");
                return (jpg.ToArray(), "image/jpeg");
            }
            using var png = pixmap.Encode(new SKPngEncoderOptions(SKPngEncoderFilterFlags.AllFilters, zLibLevel: 6))
                ?? throw new InvalidOperationException("PNG encode failed");
            return (png.ToArray(), "image/png");
        }
        finally
        {
            scaled?.Dispose();
        }
    }

    private static bool IsOpaque(SKBitmap bmp)
    {
        if (bmp.AlphaType == SKAlphaType.Opaque) return true;
        if (bmp.ColorType != SKColorType.Rgba8888 && bmp.ColorType != SKColorType.Bgra8888) return false;
        var span = bmp.GetPixelSpan();
        for (var i = 3; i < span.Length; i += 4)
            if (span[i] != 255) return false;
        return true;
    }

    private sealed class LogProgress(Log log) : IProgress<string>
    {
        public void Report(string value) => log.Info("vrf: " + value);
    }
}
