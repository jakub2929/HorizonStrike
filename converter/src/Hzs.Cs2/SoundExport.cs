using System.Text.RegularExpressions;
using Hzs.Common;
using ValveKeyValue;
using ValveResourceFormat.ResourceTypes;

namespace Hzs.Cs2;

/// <summary>
/// CS2 sound events (soundevents/*.vsndevts_c, KV3: &lt;Event&gt; = { vsnd_files_track_01 = [...] }) -> playable files.
/// File naming: snd/&lt;event&gt;_&lt;n&gt;.(wav|mp3), &lt;event&gt; = lower-case part after the first '.' of the
/// sound event name (Weapon_AK47.Clipout -> clipout), n = variation index from 0.
/// </summary>
internal sealed partial class SoundExport(Cs2Source src, Log log)
{
    private Dictionary<string, List<string>>? _events;

    public static string ShortName(string soundEvent)
    {
        var dot = soundEvent.IndexOf('.');
        var s = (dot >= 0 ? soundEvent[(dot + 1)..] : soundEvent).ToLowerInvariant();
        return NonIdent().Replace(s, "_");
    }

    [GeneratedRegex("[^a-z0-9_]")]
    private static partial Regex NonIdent();

    /// <summary>vsnd paths of a sound event, or null when the event is unknown.</summary>
    public List<string>? Files(string soundEvent)
    {
        _events ??= LoadEvents();
        return _events.TryGetValue(soundEvent, out var f) ? f : null;
    }

    private Dictionary<string, List<string>> LoadEvents()
    {
        var events = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        // game_sounds_weapons first; other files only add events it does not define
        var files = src.List("soundevents/").Where(p => p.EndsWith(".vsndevts_c", StringComparison.OrdinalIgnoreCase))
            .OrderBy(p => p.Contains("game_sounds_weapons", StringComparison.OrdinalIgnoreCase) ? 0 : 1).ThenBy(p => p, StringComparer.Ordinal);
        foreach (var path in files)
        {
            try
            {
                using var res = src.Load(path);
                if (res?.DataBlock is not BinaryKV3 kv) continue;
                foreach (var (name, ev) in kv.Data.Root.Children)
                {
                    if (name is null || !ev.IsCollection || events.ContainsKey(name)) continue;
                    var list = new List<string>();
                    foreach (var key in new[] { "vsnd_files_track_01", "vsnd_files" })
                    {
                        if (!ev.TryGetValue(key, out var v)) continue;
                        if (v.IsArray) list.AddRange(v.Values.Select(x => x.ToString()!).Where(x => !string.IsNullOrEmpty(x)));
                        else if (v.ValueType == KVValueType.String && !string.IsNullOrEmpty(v.ToString())) list.Add(v.ToString()!);
                        if (list.Count > 0) break;
                    }
                    if (list.Count > 0) events[name] = list;
                }
            }
            catch (Exception ex) { log.Warn($"soundevents {path}: {ex.Message}"); }
        }
        log.Info($"sound events indexed: {events.Count}");
        return events;
    }

    /// <summary>Write every variation of a sound event as dir/&lt;shortName&gt;_&lt;n&gt;.ext. Returns files written.</summary>
    public int Write(string soundEvent, string shortName, string dir, List<string> problems)
    {
        var files = Files(soundEvent);
        if (files is null) { problems.Add($"sound event {soundEvent} not found"); return 0; }
        Directory.CreateDirectory(dir);
        var n = 0;
        foreach (var vsnd in files)
        {
            var path = vsnd.EndsWith("_c", StringComparison.OrdinalIgnoreCase) ? vsnd : vsnd + "_c";
            using var res = src.Load(path);
            if (res?.DataBlock is not Sound sound) { problems.Add($"{soundEvent}: {vsnd} not found"); continue; }
            var (bytes, ext) = Encode(sound);
            if (bytes is null) { problems.Add($"{soundEvent}: {vsnd} unsupported format {sound.SoundType}/{sound.AudioFormat}"); continue; }
            File.WriteAllBytes(Path.Combine(dir, $"{shortName}_{n}.{ext}"), bytes);
            n++;
        }
        return n;
    }

    private static (byte[]? Bytes, string Ext) Encode(Sound sound)
    {
        switch (sound.SoundType)
        {
            case Sound.AudioFileType.MP3:
                return (sound.GetSound(), "mp3");
            case Sound.AudioFileType.WAV when sound.AudioFormat == Sound.WaveAudioFormat.PCM:
                return (sound.GetSound(), "wav");
            default:
                return (null, "");
        }
    }
}
