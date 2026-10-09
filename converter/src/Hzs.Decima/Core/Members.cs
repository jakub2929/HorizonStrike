using Hzs.Decima.Archive;

namespace Hzs.Decima.Core;

/// <summary>Resolves "Type.Member.Path" expressions against hand-written type layouts (filled in S2).</summary>
public static class Members
{
    public static string Resolve(HzdArchive arc, CoreFile core, string expr) =>
        throw new NotSupportedException($"member access not implemented yet: {expr}");
}
