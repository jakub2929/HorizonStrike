using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hzs.Decima.Core;

namespace Hzs.Decima.Sheets;

/// <summary>
/// Sheet bindings into an ambience day cycle (file#expression), evaluated at a time of day:
/// <list type="bullet">
/// <item><c>AmbienceCycle.SunElevationAngle@9.0</c>: the cycle's CurveResource sampled at hour 9 (piecewise linear);</item>
/// <item><c>AmbienceCycle.AmbienceKeyFrames[TimeOfDay=9.0].AmbienceSettings.AtmosphereFogSettings.FogDensity</c>: the
/// setting interpolated linearly between the keyframes around hour 9 (wrapping at 24 h); keyframes whose settings
/// resource is missing are skipped. Colours come out as [r, g, b].</item>
/// </list>
/// A file can hold several AmbienceCycles (overrides with one keyframe); the one with the most keyframes is the day cycle.
/// </summary>
public static partial class Ambience
{
    [GeneratedRegex(@"^AmbienceCycle\.(\w+)@([0-9.]+)$")]
    private static partial Regex CurveAt();

    [GeneratedRegex(@"^AmbienceCycle\.AmbienceKeyFrames\[TimeOfDay=([0-9.]+)\]\.AmbienceSettings\.(\w+)\.(\w+)$")]
    private static partial Regex SettingAt();

    public static bool Handles(string expr) => expr.StartsWith("AmbienceCycle.", StringComparison.Ordinal);

    public static JsonNode? Evaluate(Resolver res, CoreFile file, string expr)
    {
        var cycle = file.All("AmbienceCycle").OrderByDescending(c => c.Refs("AmbienceKeyFrames").Length).FirstOrDefault()
                    ?? throw new InvalidDataException($"{file.Path}: no AmbienceCycle");
        if (CurveAt().Match(expr) is { Success: true } cm)
        {
            var t = float.Parse(cm.Groups[2].Value, CultureInfo.InvariantCulture);
            var curve = res.Deref(cycle, cycle.Ref(cm.Groups[1].Value)) ?? throw new InvalidDataException($"{expr}: curve not found");
            return Math.Round(Sample(curve, t), 4);
        }
        if (SettingAt().Match(expr) is { Success: true } sm)
        {
            var t = float.Parse(sm.Groups[1].Value, CultureInfo.InvariantCulture);
            var (resource, field) = (sm.Groups[2].Value, sm.Groups[3].Value);
            var keys = new List<(float Time, object Value)>();
            foreach (var kr in cycle.Refs("AmbienceKeyFrames").Distinct())
            {
                var kf = res.Deref(cycle, kr);
                var settings = kf is null ? null : res.Deref(kf, kf.Ref("AmbienceSettings"));
                var resObj = settings is null ? null : res.Deref(settings, settings.Ref(resource));
                if (resObj is null) continue;
                var holder = resObj.Has(field) ? resObj : resObj.Has("Settings") ? resObj.Struct("Settings") : null;
                if (holder is null || !holder.Has(field)) continue;
                keys.Add((kf!.Float("TimeOfDay"), holder[field]!));
            }
            if (keys.Count == 0) throw new InvalidDataException($"{expr}: no keyframe has {resource}.{field}");
            keys.Sort((a, b) => a.Time.CompareTo(b.Time));
            var i1 = keys.FindIndex(k => k.Time > t);
            var (k0, k1) = i1 < 0 ? (keys[^1], keys[0]) : i1 == 0 ? (keys[^1], keys[0]) : (keys[i1 - 1], keys[i1]);
            var span = (k1.Time - k0.Time + 24f) % 24f;
            var w = span < 1e-4f ? 0f : ((t - k0.Time + 24f) % 24f) / span;
            return Lerp(k0.Value, k1.Value, w);
        }
        throw new InvalidDataException($"unsupported ambience expression {expr}");
    }

    private static JsonNode? Lerp(object a, object b, float w)
    {
        if (a is float fa && b is float fb) return Math.Round(fa + (fb - fa) * w, 4);
        if (a is Obj ca && b is Obj cb && ca.Has("R"))
            return new JsonArray(new[] { "R", "G", "B" }.Select(c => (JsonNode)Math.Round(ca.Float(c) + (cb.Float(c) - ca.Float(c)) * w, 4)).ToArray());
        return HzdBindings.ToJson(w < 0.5f ? a : b);
    }

    private static float Sample(Obj curve, float x)
    {
        var pts = curve.Structs("Points").Select(p => (X: p.Float("X"), Y: p.Float("Y"))).OrderBy(p => p.X).ToArray();
        if (pts.Length == 0) return 0;
        if (x <= pts[0].X) return pts[0].Y;
        if (x >= pts[^1].X) return pts[^1].Y;
        var k = 1;
        while (pts[k].X < x) k++;
        var (a, b) = (pts[k - 1], pts[k]);
        return b.X - a.X < 1e-6f ? b.Y : a.Y + (b.Y - a.Y) * (x - a.X) / (b.X - a.X);
    }
}
