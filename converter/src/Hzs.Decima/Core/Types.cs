namespace Hzs.Decima.Core;

/// <summary>
/// Type ids of the HZD (PC 2020) RTTI classes this converter reads. A type id is the first u64 of
/// MurmurHash3_x64_128(seed 42) over the type's RTTI signature; values are hand-written here for the few
/// classes we need (no type dump is shipped).
/// </summary>
public static class Types
{
    public const ulong PrefetchList = 0xF34A76FAD0A1E0D7;

    private static readonly Dictionary<ulong, string> Names = typeof(Types)
        .GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
        .Where(f => f.IsLiteral && f.FieldType == typeof(ulong))
        .ToDictionary(f => (ulong)f.GetRawConstantValue()!, f => f.Name);

    public static string NameOf(ulong type) => Names.TryGetValue(type, out var n) ? n : $"0x{type:X16}";

    public static ulong? IdOf(string name) =>
        typeof(Types).GetField(name) is { IsLiteral: true } f && f.FieldType == typeof(ulong) ? (ulong)f.GetRawConstantValue()! : null;
}
