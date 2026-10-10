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

## Viewmodel facts (C2)
- VRF glTF export bakes the conversion: translations x 0.0254 (m), skeleton roots get
  `CreateFromYawPitchRoll(0, -pi/2, -pi/2)` (source +X fwd/+Y left/+Z up -> glTF +Z/+X/+Y), meshes baked; the
  asset faces +Z. We wrap every exported scene in a node turned 180 deg about Y -> Godot -Z forward.
- Clips: `AnimationClip` (vnmclip_c) -> `new ClipAnimation(clip)`, `DecodeFrame(new Frame(skel, []))`, locals in
  source units; `Skeleton.FromSkeletonResource(loader, clip.SkeletonName)`. VRF `ClipAnimation.Fps` = 1 for single
  pose clips (idle): we use 30 fps and write two keys so the clip has a length.
- Clip skeleton viewmodel.vnmskel (56 bones) has its root_motion at the **eye**: view.glb origin = camera position.
  The arms model (weapons/models/shared/arms/weapon_arms.vmdl, 82 bones incl. twist/pelvis/legs) uses the same bone
  names and parents, so clip locals drive its joints by name (bind poses differ, skinning does not care).
- Secondary track (e.g. ak47.vnmskel, attachable prop) is local to the arms bone `wpn`
  (viewmodel.vnmskel m_secondarySkeletons attach bone): its root stays identity. The weapon model's skeleton
  (same bone names) is re-parented under `wpn`, its root written without the axis turn.
- Clip list per weapon = `m_resources` of the weapon graph (`view_anim_graph`, recursing nested graphs). Names:
  draw=draw_*, idle=idle_* (shortest), fire=shoot1_*/light_miss1_* (knife)/throw_overhand_* (grenades),
  fire2=heavy_miss1_* (knife), pullpin=pullpin_*, reload=reload_* (shortest), inspect=lookat01_*.
  Additive clips (e.g. shared idle_from_activity_m249) are composed over the idle pose, never the A-pose bind.
- Clip sound events: `NmSoundEvent` (`StartTime` in seconds, `Name` = soundevent).
- Not done: AnimConstraintTiltTwist (forearm twist bones stay at rest relative to the lower arm).

## Asset facts (C2)
- VRF writes 4096 px PNGs; SharpGLTF/our edits leave the replaced image data orphaned in BIN (AK world.glb 57 MB of
  which 3.7 MB referenced). `Glb.Compact()` rebuilds BIN from referenced buffer views only.
- Textures: downscaled to `cache.texture_max_px` (1024), opaque -> JPEG q90 4:4:4, alpha -> PNG.
- Weapon models carry `body_legacy` + `body_hd`: legacy meshes are filtered (MeshFilter).
- "Failed to find shader csgo_weapon.vfx" (stderr): shader VPKs are not loaded; VRF falls back to texture-name
  channel mapping (base color, normal, ORM come out right).
- Sound events: soundevents/*.vsndevts_c (21063 events), `vsnd_files_track_01` = list; child events (distant
  layers) are skipped. vsnd: PCM WAV (header synthesized by VRF) or MP3. File name = lower(after first '.').
- Godot 4.7.2 runtime GLTFDocument loads view.glb as one Skeleton3D (90 bones) with 5 animations; screenshots of
  idle/reload/inspect show the arms holding the gun with the real CS2 clips (C:\meshy\_tools\cache-cs2work\shots).

## Log
- C1 2026-10-09: `cs2 --only-stats` -> `36 2700 [0.0006, 0.0005] 650 0`; all 470 bound cells type-check against
  the sheet column types and match every `_evidence` number.
- C2 2026-10-09: AK-47 slice: view.glb (draw idle fire reload inspect, skins 2, max_texture_px 1024, 5.3 MB),
  world.glb 3.2 MB, anim_events.json, icon.svg, snd/ 14 files (single x3, clipout, clipin, boltpull, draw, ...).
- C3 2026-10-09: all 14 rows in 59 s: 27 glb (13 view + 14 world) pass glb_info, `_errors` [], 0 asset problems,
  cs2/ = 115 MiB. cs2/ui: armor.svg, kevlar.svg, snd/buy_0..2.wav. Godot 4.7.2: 16 SVGs load
  (Image.load_svg_from_buffer), 288 sounds load (AudioStreamWAV/MP3.load_from_file), all 12 viewmodels render
  holding their weapon (contact sheets in C:\meshy\_tools\cache-cs2work\shots).
- C4 2026-10-09: manifest.json gets `cs2_build` (appmanifest_730.acf buildid, fallback steam.inf ClientVersion) and
  `cs2_format` (= Cs2Converter.Format, bump on output changes); merged through Hzs.Common ManifestFile (lock +
  atomic write, other fields kept: checked with a pre-seeded hzd_build). A full conversion first removes the cs2
  stamp, so an interrupted run is redone. 2nd run: `cs2 up to date (25815307)`, `done: 0 bytes`, 350 files unchanged.
  serve bootstrap during a full CS2 conversion: 0 non-JSON stdout lines (StdoutGuard).
- C5 2026-10-09: tools/build.ps1 `Build-Converter` (self-contained win-x64 publish, not trimmed/single-file,
  no pdb/xml; libSkiaSharp.pdb 89 MB removed; licenses/ from the packages) + THIRD_PARTY_NOTICES.txt.
  dist/converter = 97 MB; `dist\converter\hzsconv.exe --help` exit 0; the published exe converts ak47.
  Note: the worktree guard refuses to launch powershell from the agent's Bash tool, so build.ps1 itself was not
  executed by cs2; its exact publish command and copies were run by hand with the same arguments.
- Content contract 2026-10-09 (CLAUDE.md "Content is data, not code"): sheets/weapons.json columns content_model
  ({view, world} cache-relative), bone_roles (camera/root, attach, hand_r, hand_l, weapon, mag, bolt, trigger, pin)
  and points (muzzle, eject, mag_drop, flame: {bone, offset m bone-local, rotation, forward, kind}) with evidence;
  the converter writes cs2/weapons/<id>/meta.json from the models (arms skeleton, weapon skeleton, vmdl attachments
  muzzle_flash / muzzle_flash2 for the suppressed M4A1-S / shell_eject / mag_drop / molotov_particle, attach bone
  from viewmodel.vnmskel m_secondarySkeletons; knives/grenades are not listed there -> the one bone all 13 listed
  entries use) and reports any difference to the sheet as a problem: 14 items, 0 problems. Attachment offsets are
  bone-local inches -> x 0.0254; bone-local frames are unchanged by the glTF conversion (only roots turn).
  Points render on the muzzle / ejection port / P250 mag / molotov rag in Godot (BoneAttachment3D + offset).
  cs2_format 2 (meta.json). Bones and points refer to view.glb; world.glb stays a static mesh.
- 0.3 knives 2026-10-10: `hzsconv knives` / serve op `knives` (sheets systems knives.selection, hooks cs2.localization,
  cs2.knife_graphs, cache.knives, proto.knives). items_game: 23 items with prefab chain `melee`; weapon_knifegg (41)
  has no used_by_classes -> 22 knives. Knife vdata blocks are keyed by def index ("507") with m_szAnimSkeleton;
  graph names do not follow item names (gypsy_jackknife -> +navajo, widowmaker -> viewmodel_knife_talon), so the graph
  is found by the secondary skeleton of its draw clip (largest graph wins: the +variation over the base graph).
  Knife idles are `idle1_*` (clip rule fallback); inspect2/3 = lookat02/03 (knives only, weapons unchanged).
  csgo_english.txt has `\"` escapes ValveKeyValue's KV1 parser rejects (line 3097) -> line regex for Tokens.
  Result (fresh cache E:\meshy_work\cs2-knives-1): 22/22 ok, 45 s incl. index, 132.2 MiB; second run cached (0 bytes).
  Knives have no fx attachments (holster/inventory/stattrak/nametag only) -> points {} like the sheet knife row.
  Finishes: CS2 paint kits are composite materials (weapons/paints/**.vcompmat: include chain + loose variables,
  assembled by CS2's composite shaders from pattern, wear and grunge inputs); VRF 20 does not evaluate them -> not
  converted, default finish only (3 attempts: paint kit data, vcompmat decompile, VRF composite support).
- 0.3 K2 2026-10-10: cs2/ui/snd feedback sounds = every systems fx.sound_* event (game_sounds_player /
  game_sounds_physics / game_sounds_weapons), named with ShortName like weapon snd/; null.vsnd tracks are skipped
  (none in these 7 events). cs2_format 3. Fresh cache E:\meshy_work\cs2-k2-1: 35 new files (+3 buy), all PCM WAV,
  2.3 MiB for ui/snd, Godot loads 38/38; weapons 14 items 0 problems; second run up to date.
- 0.3 knife dedupe 2026-10-10: serve keeps one job per knife (queued or running); a later knives request adds its
  request id to that job (and raises its priority) and gets the same done event; ConvertKnife re-checks the index
  inside the session lock. Overlap test (selected "knife" prio -1 + all prio 100, fresh E:\meshy_work\cs2-knifedup-1):
  22 conversions, none twice, "knife" done for both requests at 7.4 s, 0 non-JSON lines.
- 0.3 memory 2026-10-10 (CLI cs2, fresh caches E:\meshy_work\cs2-mem-*, output SHA-256 identical in every run):
  base 79566b7 A/B median 67.3 s / 1955 MB private peak (single runs up to 2581 MB). Changes: parsed items_game/vdata
  released after the stats; ProcessMemory.CollectNow (Hzs.Common: finalizers for VRF's undisposed SkiaSharp bitmaps +
  aggressive LOH compaction) after every VRF export and every item/knife; Glb keeps added views out of BIN until
  Compact (no whole-buffer copy per texture); VRF export on a ConcurrentExclusiveScheduler with TextureSlots + 1
  threads (VRF texture tasks continue on TaskScheduler.Current); re-encoded images cached by input hash per item (world
  and skinned exports of a weapon share textures), re-encode 2 in parallel. A/B 2 vs 3 slots (quiet machine):
  2 slots 81.6 s / 1224 MB, 3 slots 59.5 s / 1378 MB -> 3 slots (faster than before, -30 % peak).
