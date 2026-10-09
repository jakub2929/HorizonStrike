namespace Hzs.Decima.Core;

/// <summary>
/// Type ids of HZD (PC 2020) RTTI classes. A type id is the first u64 of MurmurHash3_x64_128(seed 42) over the
/// type's RTTI signature; the ids of the classes we read are hand-written next to their layouts (Layouts.*.cs).
/// </summary>
public static class Types
{
    public static string NameOf(ulong type) => Layouts.NameOf(type) ?? $"0x{type:X16}";

    public static ulong Id(string name) => Layouts.IdOf(name);
}
