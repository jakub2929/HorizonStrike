# MODLOG – Horizon Strike (CS2 × Horizon Zero Dawn Complete Edition)

Journal and decision log (orchestrator-owned). Newest entries at the bottom of each section.

## Setup (2026-10-09)
- CS2: Steam app 730, `C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive`, buildid 25738536
  (StateFlags 6 = update pending; files readable). 506 VPK chunks; `scripts/items/items_game.txt` present.
- HZD Complete Edition: Steam app 1151640, `E:\SteamLibrary\steamapps\common\Horizon Zero Dawn`, buildid 8040161,
  original 2020 PC port (Packed_DX12/*.bin, oo2core_3_win64.dll).
- Melty: CS2 has no loader Melty installs; it is "standalone"-capable (program in `{managed}`, `{game}` = CS2 dir).
  HZD is not in Melty's catalog (`custom-horizon-zero-dawn-complete-edition`, role "secondary").
  Working examples: `spike-rush` (CS2 standalone, one click yes), `kh1-x-cs2` (CS2 primary + custom game secondary).
- Installed tools: Godot 4.7.2 export templates (Windows x64) into `%APPDATA%\Godot\export_templates\4.7.2.stable`;
  ValveResourceFormat CLI 20.0 into `C:\meshy\_tools\vrf`; universal-modder clone (commit 8370faa) into `C:\meshy\_tools`.

## Research findings (HZD, 2026-10-09)
- Archives: all 39 `.bin` magic 0x20304050 (unencrypted). Header 40 B; file entry 32 B (index, key, u64 path hash,
  u64 offset in decompressed space, u32 size, key2); chunk entry 32 B; chunks Oodle-compressed (oo2core_3, max chunk
  0x40000). Path hash = first u64 of MurmurHash3_x64_128(seed 42) over UTF-8 path + ".core" + NUL. Patch.bin overrides.
  Path list obtainable at runtime from `prefetch/fullgame.prefetch.core`.
- Machines: meshes `models/characters/robots/<int>/animation/parts/*.core(.stream)`, skeleton
  `.../animation/skeletons/skeleton_rootbone.core`, textures `.../textures/<int>_set.core`. Internal names: scout =
  Watcher (verified); horse = Strider, antelope = Grazer (to verify).
- Machine animations: Morpheme / EdgeAnim compressed, no public decoder -> procedural animation on the real skeleton.
- World: StreamingTile / PrefabInstance / StaticMeshInstance placements are decodable (Workshop exports them).
  Terrain heightmap: data exists (`tiles/*/worlddata/worlddata_height_terrain.core`, `layers/terrain/terraintiledata.core`,
  `lods/combined_flattened_height`), no public decoder -> research risk. Procedural vegetation `worlddata/placement_*`
  is GPU-generated -> place from density maps.
- Audio: no Wwise; `WaveResource` (PCM/MP3/ADPCM/...) and `MusicResource` (MP3 tracks).
- Licences: Decima Workshop GPL-3.0, HZDCoreEditor/HZDMeshTool unlicensed -> format reference only; own MIT code.

## Decisions
- D1 Host/route: standalone program, CS2 primary (`{managed}/HorizonStrike.exe --game {game}`), HZD secondary,
  auto-detected via Steam libraryfolders. Neither game is launched or written to.
- D2 Engine: Godot 4.7.2 GDScript game + .NET converter `hzsconv` (ValveResourceFormat for CS2, own Decima reader).
- D3 Kill reward = CS2 kill award of the weapon class × machine multiplier (machines sheet); cap $16,000.
- D4 Weak-spot hit = weapon damage × that weapon's CS2 headshot multiplier.
- D5 Shots raise suspicion of machines within a radius; suppressed weapons use a smaller radius.
- D6 Buy wheel: max 12 items, prices from CS2 data: pistols, SMG, rifles, AWP, shotgun, HE, molotov, armor.
- D7 Other machines' sites are populated with v1 machines by site type (variant B); mapping logged below.
- D8 Cells are converted on demand ahead of the player; first launch converts only weapons, machines and the start
  area; cache cap with eviction of distant cells; cache size shown in game.
- D9 In-game UI language: English (Melty audience is international). Listing in English.
- D10 Credits "EM", licence MIT, remix allowed.

## Site mapping (variant B)
(to be filled when spawn sites are decoded)

## Log
