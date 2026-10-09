# cs2 journal (converter, CS2 side)

## Versions
- ValveResourceFormat NuGet 20.0.6980 (net10.0, MIT). Closure: ValvePak 5.0.2.177, ValveKeyValue 0.70.0.499,
  SharpGLTF.Core/Runtime/Toolkit 1.0.6, SkiaSharp 4.151.1 (+ NativeAssets Win32/macOS/Linux.NoDependencies),
  K4os.Compression.LZ4 1.3.8, ZstdSharp.Port 0.8.8, Blake3 3.0.2, KeyValues2 0.8.0 (Datamodel.NET), TinyBCSharp 0.1.2,
  TinyEXR.NET 1.1.0, Vortice.SPIRV 1.0.5, Vortice.SpirvCross 1.5.4, System.IO.Hashing 10.0.10.
- API reference: VRF source tag 20.0 (tarball in C:\meshy\_tools\research\vrf_src_20.0, read only), ValvePak master.
- CS2 build 25815307 (steamapps/appmanifest_730.acf).

## API facts (checked in the 20.0 source / package XML docs)
- `BinaryKV3.Data` is a ValveKeyValue `KVDocument` (`.Root` KVObject). KVObject: `ValueType` (Collection, Array,
  Boolean, Int*, UInt*, FloatingPoint (f32), FloatingPoint64, String, ...), `Children` (key, value) pairs,
  `Values`, `TryGetValue`, `ToInt32/ToDouble/ToSingle/ToBoolean`; string values with flags (resource_name:,
  soundevent:) return the bare string from `ToString()`.
- KV1 text: `KVSerializer.Create(KVSerializationFormat.KeyValues1Text).Deserialize(stream)` -> KVDocument
  (`Name` = root key, list-backed children, duplicates kept).
- `GameFileLoader(package, fileName)`: with a fileName it walks up to gameinfo.gi and prints to **stdout**
  ("Found ...", "Preloading vpk"). We pass `null` and add game/core/pak01_dir.vpk with `AddPackageToSearch(Package)`.
- Several VRF code paths `Console.WriteLine` (bone constraints, unknown frame attributes, ...). In serve mode
  stdout is the protocol, so `StdoutGuard` redirects Console.Out into the log while CS2 code runs (the Protocol
  object holds the original writer).
- ValvePak opens the dir VPK and chunk files with `FileAccess.Read` (FileStream / MemoryMappedFileAccess.Read).

## Data facts
- weapons.vdata_c blocks are flattened (every key present; `_base` kept for reference). Absent keys: knife
  m_bReserveAmmoAsClips/m_bReloadsSingleShells/m_flThrowVelocity, guns m_bReloadsSingleShells/m_flThrowVelocity,
  grenades m_bReserveAmmoAsClips/m_bReloadsSingleShells, molotov m_nRecoilSeed -> resolved null + log warning
  (column default), not an `_errors` entry (hooks.json cs2.vdata).
- Pair keys: a vdata key is a [mode0, mode1] pair when any block stores it as a 2-number array; scalar values of
  pair keys are normalized to [v, v] (AK m_flCycleTime 0.1 -> [0.1, 0.1]). Floats are float32 in KV3 for some
  keys: converted through the shortest round-trip text so 0.0006f stays 0.0006.
- items_game.txt is raw KV1 text in the VPK (272k lines); kevlar = items/"50" name item_kevlar,
  attributes/"in game price" "650", model_world models/weapons/w_eq_armor.vmdl.
- gamemode_competitive.cfg: `cvar<tabs>value`, `//` comments.

## Log
- C1 2026-10-09: `cs2 --only-stats` -> `36 2700 [0.0006, 0.0005] 650 0`; all 470 bound cells type-check against
  the sheet column types and match every `_evidence` number.
