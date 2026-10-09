using System.Text.RegularExpressions;
using Hzs.Decima.Archive;

namespace Hzs.Decima.Core;

/// <summary>
/// Resolves sheet binding member paths: <c>Type.Member.Member[n].Member[SubType].Member</c>. The first segment
/// names the class of the first matching object in the file; references are followed (also into other files);
/// <c>[n]</c> indexes an array, <c>[Type]</c> picks the first array element whose object is of that class.
/// </summary>
public static partial class Members
{
    [GeneratedRegex(@"^(\w+)((?:\[[^\]]+\])*)$")]
    private static partial Regex Segment();

    public static string Resolve(HzdArchive arc, CoreFile core, string expr) => Obj.Format(Evaluate(new Resolver(arc), core, expr), 0);

    public static object? Evaluate(Resolver res, CoreFile core, string expr)
    {
        var parts = expr.Split('.');
        // first segment: Type, Type[n] (n-th object of that type) or Type[Name] (object whose Name member matches)
        var head = Segment().Match(parts[0]);
        if (!head.Success) throw new ArgumentException($"bad member segment '{parts[0]}'");
        var type = head.Groups[1].Value;
        var sel0 = head.Groups[2].Value.Trim('[', ']');
        var candidates = core.OfType(type).ToList();
        CoreObject? pick = sel0.Length == 0 ? candidates.FirstOrDefault()
            : int.TryParse(sel0, out var nth) ? candidates.ElementAtOrDefault(nth)
            : candidates.FirstOrDefault(c => core.Decode(c) is { } d && d.Has("Name") && d.Str("Name") == sel0);
        object? cur = pick is null ? throw new KeyNotFoundException($"{core.Path}: no {parts[0]} object") : core.Decode(pick);
        foreach (var part in parts.Skip(1))
        {
            var m = Segment().Match(part);
            if (!m.Success) throw new ArgumentException($"bad member segment '{part}'");
            cur = Follow(res, core, cur);
            if (cur is not Obj o) throw new InvalidDataException($"'{part}': parent is not an object");
            cur = o[m.Groups[1].Value];
            foreach (var sel in Regex.Matches(m.Groups[2].Value, @"\[([^\]]+)\]").Select(x => x.Groups[1].Value))
            {
                var arr = cur switch
                {
                    object?[] a => a,
                    Array a => a.Cast<object?>().ToArray(),
                    _ => throw new InvalidDataException($"'{part}': [{sel}] on a non-array"),
                };
                if (int.TryParse(sel, out var idx)) cur = arr[idx];
                else
                {
                    cur = null;
                    foreach (var e in arr)
                    {
                        var eo = Follow(res, (o.File ?? core), e);
                        if (eo is Obj x && x.Type == sel) { cur = x; break; }
                        if (eo is null && e is Ref rr && res.Target(o.File ?? core, rr) is { } t && t.TypeName == sel) { cur = res.Deref(o.File ?? core, rr); break; }
                    }
                    if (cur is null) throw new KeyNotFoundException($"'{part}': no element of type {sel}");
                }
            }
            if (cur is Ref r2) cur = Follow(res, o.File ?? core, r2);
        }
        return cur;
    }

    private static object? Follow(Resolver res, CoreFile file, object? v) => v is Ref r ? res.Deref(file, r) : v;
}
