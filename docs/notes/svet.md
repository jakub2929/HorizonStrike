# svet journal (Decima reader, HZD world, machines, audio)

Format facts and decisions established while building `converter/src/Hzs.Decima`. No game data, path lists or type
dumps here - only the facts needed to read the format (own words) and single values as evidence.

## S1 archive reader (2026-10-09)
- Archives opened read-only: `Packed_DX12/{DLC1,FGRWin32,Initial,Remainder,Patch}.bin`, later ones override
  earlier ones on the same path hash (Patch last). Language bins are not opened.
- Header 40 B: u32 magic 0x20304050 (plain; 0x21304050 = encrypted, not present on PC), u32 key, u64 file size,
  u64 data size, u64 file count, u32 chunk count, u32 max chunk size (0x40000).
- File entry 32 B: u32 index, u32 key, u64 path hash, u64 offset (decompressed space), u32 size, u32 key2.
- Chunk entry 32 B: decompressed span (u64 offset, u32 size, u32 key), compressed span (same). Each chunk is one
  Oodle block; files span consecutive chunks. A small LRU (160 chunks) keeps hot chunks because many small cores
  share a chunk.
- Path hash: first u64 of MurmurHash3_x64_128(seed 42) over UTF-8 `path.core` + NUL (`.core.stream` for streams).
- Oodle: `NativeLibrary.Load(<hzd>/oo2core_3_win64.dll)` in place, `OodleLZ_Decompress` via function pointer
  (fuzzSafe 1, checkCRC 0, threadPhase 3). Positional reads (`RandomAccess.Read`) make the reader thread-safe;
  `hzd-ls --threadcheck models/characters/robots/` read 2856 files x4 on 4 threads identical to sequential.
- Path list: `prefetch/fullgame.prefetch.core` holds one `PrefetchList` object (ObjectUUID, Files: Array<AssetPath>,
  Sizes: Array<int32>, Links: Array<int32>); AssetPath serializes as one String. 146,891 paths on this install,
  182,221 unique archive entries (streams and some cores are not in the prefetch list).
- Core file = sequence of objects: u64 type id, u32 size, data (first the 16-byte ObjectUUID). String = u32 length,
  u32 CRC32C (only if length > 0), UTF-8 bytes. Ref = u8 kind (0 none, 1 internal link + GUID, 2 external link +
  GUID + String path, 3 external ref + GUID + path, 5 internal ref + GUID). Array = u32 count + items. HashMap/Set =
  count, per item u32 hash + item. Class members serialize in ascending member offset order (bases flattened,
  save-state members skipped); classes with a MsgReadBinary handler append extra binary data after the members.
- Type id = first u64 of MurmurHash3_x64_128(seed 42) of the type's RTTI signature string. The ids for the classes
  we read are hand-written in `Core/Types.cs`.

Acceptance (S1):
```
hzd-ls --prefix models/characters/robots/scout/   -> 25 .core paths
hzd-ls --tiles                                    -> 360 tiles, 340 terrain, x -7..12, y -9..7
```

## S2 object reader (2026-10-09)
- Generic decoder (`Core/Layouts.cs`) driven by hand-written layouts (`Core/Layouts.*.cs`): one line per class with
  its type id and the members in serialization order. Partial layouts stop after the last member we need.
  Member types: primitives, `eN` enums (N bytes), `Ref` (any reference kind), `Array<T>`, `Map<T>` (HashMap/Set),
  embedded structs (own layout, no UUID).
- Members serialized BEFORE the ObjectUUID exist (members with offsets below 12): every WorldNode subclass
  (`Orientation: WorldTransform`, 60 bytes: 3 doubles + 3x3 floats), EntityResource (`Lockable`, `ZoomLockable`),
  PhysicsInstance/PhysicsCollisionResource (`CollisionFilterInfo` u32), WaveResource (3 bytes) and a few more.
  `CoreFile` uses the layout's lead size to locate the UUID.
- The order of members with equal offsets follows the engine's own quicksort (LCG-seeded pivot), so it is not
  alphabetical and differs between subclasses (e.g. Lockable/ZoomLockable swap) - layouts list the real order.
- `hzd-dump --member Type[sel].A.B[n].C[SubType].D` follows references (also into other files). `[Name]` on the
  first segment picks the object by its Name (machine files hold a normal and a corrupted variant).
- LocalizedTextResource (binary): after the UUID, one entry per language (English first): u16 length + UTF-8.

### Machine identities (from CharacterDescriptionComponentResource.LocalizedName, English)
| internal | display | AI resource | InitialHealth (normal) |
|---|---|---|---|
| scout | Watcher | ai/characters/scout | 90 |
| horse | Strider | ai/characters/horse | 105 |
| harvester | Grazer | ai/characters/harvester | 150 |
| antelope | Lancehorn | ai/characters/harvester | 275 |
| longhorn | Broadhead | ai/characters/horse | 175 |
| goat | Charger | ai/characters/horse | 325 |
| bison | Trampler | ai/characters/bison | 1200 |
| hyena | Scrapper | ai/characters/hyena | 220 |
| direwolf | Sawtooth | ai/characters/direwolf | 1100 |
| greywolf | Ravager | ai/characters/greywolf | 1300 |
| raptor | Thunderjaw | ai/characters/raptor | 6500 |
| laserscout | Redeye Watcher | ai/characters/scout | 200 |
| longlegbird | Longleg | ai/characters/longlegbird | 750 |
| glider | Glinthawk | ai/characters/glider | 450 |
| thunderhawk | Stormbird | ai/characters/thunderhawk | 5000 |
| beachlizard | Snapmaw | ai/characters/beachlizard | 1450 |
| crab | Shell-Walker | ai/characters/crab | 800 |
| cargorhino | Behemoth | ai/characters/cargorhino | 2700 |
| spraybot | Fire/Freeze Bellowback | ai/characters/spraybot | 1600 |
| mole | Rockbreaker | ai/characters/mole | 3500 |
| stalker | Stalker | ai/characters/stalker | 800 |
| hackbot | (no display name; Corruptor) | ai/characters/hackbot | 1900 |
The planning hypotheses antelope = Grazer, longhorn = Lancehorn, bison = Broadhead, raptor = Sawtooth/Ravager,
mole = Burrower were wrong. Grazer is `harvester`.
- The machine's DestructibilityResource lives in the entity file (`entities/characters/robots/<n>/<n>.core`), not
  in `<n>_destructibility.core` (that file holds the parts). Acceptance for S2 therefore uses `scout.core`.
- Weak spots (DestructibilityPart): Watcher `Scout_EyePart` bone `Eye_helper` (health 50, DamageToEntityMultiplier
  8.0); Strider canister bone `Horse_Goat_Canister_Fuel_helper` (mult 1.5, mesh canisters/.../horse_goat_canister_fuel),
  eye `Eye_Lx_helper` (mult 2.0); Grazer canisters `lfcannisterHelper`, `rfcannisterHelper`, `lbcannisterHelper`,
  `rbcannisterHelper` (mult 1.5, mesh canisters/.../harvester_canister_fuel), rotor blades `DestructablePart14_helper`,
  `DestructablePart15_helper`, eye `DestructablePart13_helper`.
- AIVisualSensor angles are degrees and (from their sizes: direct 12-16, peripheral 78-90) half-angles of the cone.

## S3 machines (2026-10-09)
- Mesh part file: LodMeshResource -> Meshes[] (LOD by Distance; LOD0 = distance 0) -> RegularSkinnedMeshResource or
  StaticMeshResource -> Primitives[] (RenderingPrimitiveResource) + RenderFxResources[]/RenderEffects[] (one effect
  per primitive). DrawFlags bit 3 = shadow-only geometry (skipped).
- VertexArrayResource (binary): u32 vertex count, u32 stream count, u8 streaming; per stream u32 flags, u32 stride,
  u32 element count, elements (u8 offset, u8 EVertexElementStorageType, u8 slots, u8 EVertexElement), 16-byte hash,
  then inline data or a data source (u32 length + "cache:<path>.core.stream", u64 offset, u64 length). All streams of
  one array share the offset field; stream i starts at offset + sum(padded lengths of streams before it).
- IndexArrayResource (binary): u32 count, u32 flags, u32 format (0 = u16, 1 = u32), u32 streaming, hash, data/source.
  Primitive StartIndex..EndIndex select the range, IndexOffset is a base vertex.
- Elements seen: positions Half x3 (stride 8) in model space meters; normals Float x3 or SNorm16 x3; UV0 Half x2 or
  SNorm16 x2 (values outside 0..1, sampler wraps); BlendIndices UByte x4 = joint indices into the mesh skeleton (not
  into JointIndexList); BlendWeights UNorm8 x4 = weights of influences 1..3, influence 0 gets 1 - sum ("3x8").
- SkinnedMeshBoneBindings: JointIndexList + InverseBindMatrices (Mat44, Col3 = translation) -> bind-pose world of the
  joints a mesh uses. Joints no mesh uses get world = parent world x local from the entity's
  SkinnedModelResource.InitialPose (Pose binary: u8 present, u32 n, n x Mat34 local [quat xyzw | t xyz_ | s xyz_],
  n x Mat44 model, u32 m, m x u32). InitialPose is an animated stance, not the bind pose (differs up to 0.67 m).
- SkeletonHelpers (robot_modelhelpers, skeletons/*_helpers): OrientationHelper {Mat44 local to joint Index, Name}.
  Rigid parts (plates, eye, canisters) are StaticMeshResources in helper space; DestructibilityPart.BoneName names
  the helper. glb: helpers become extra joints; rigid parts are skinned 100% to their helper (one skin per machine).
- Texture (binary): header u16 type, u16 w, u16 h, u16 depth, u8 mips, u8 EPixelFormat, ...; u32 remaining,
  u32 internal size, u32 external size, u32 external mips, data source, inline data. Stream = largest mips,
  inline = the rest, mip-major. TextureSetEntry.PackingInfo: one byte per output channel, low nibble = source
  ETextureSetType (1 Color, 3 Normal, 6 Roughness), high nibble = source channel, 0x80 unused. Machine colour maps
  are BC1, normal/roughness BC7. Decoded with TinyBCSharp 0.1.2 (MIT, already a ValveResourceFormat dependency).
- Space: HZD characters face +Y, right +X, up +Z; godot = (x, z, -y) keeps handedness (det +1); machines face -Z.
- Results (bind pose top): Watcher 1.45 m, Strider 1.99 m, Grazer 3.71 m (incl. rotor blades). Units are meters
  (checked against an Aloy headdress top at 1.73 m). ~0.2-0.6 s per machine, 9-12 MB glb each.
- Leg chains derived from the skeleton: grounded leaf joints walked up while the ancestor leads to one grounded leaf.

## S4 terrain (2026-10-09) - REAL terrain
- First attempt `lods/combined_flattened_height`: one Texture 4096x4096 BC6U (13 mips) for the whole world = 4 m/px;
  usable for distant terrain but too coarse for play. Per tile data is better and decodes cleanly:
- `tiles/tile_xXX_yYY/worlddata/worlddata_height_terrain.core` = WorldDataTextureMap (+ entry + result Texture).
  SurfaceCacheData = 1024 x 1024 R_UNORM_16 (2 MiB). Heights in meters = raw / 32: tile (4,-3) raw 5641..13684 ->
  176.3..427.6 m, exactly its TerrainTileData.MappedHeightRange 176..428 (the global Terrain.TerrainHeightRange 0..644
  does NOT fit: it would give 55..134 m). Neighbours share edge samples bit-exactly (seam delta 0.0 m) -> 1024 samples
  span 512 m inclusive, spacing 512/1023 = 0.5005 m.
- Orientation: row 0 = north edge (HZD Y max), rows go south; column 0 = west edge (X min). Tile (x,y) covers HZD
  X 512x..512(x+1), Y 512y..512(y+1) (TerrainTileData.BoundingBox).
- World axes (landmark check): Meridian tiles are at x = -1, y = -3..-2, Sunfall at x = -3, y = 0..-1, Mother's Heart
  at (4,-3): Meridian lies west of the Embrace and Sunfall north-west of Meridian, as in the game -> HZD X = east,
  Y = north, Z = up, right-handed (also machines: R_ legs at +X when facing +Y). Godot = (x, z, -y): east +X, north -Z.
- `worlddata_flattened_albedo` (Texture 2048 px, streamed) is the terrain colour seen from above, same orientation as
  the heights (ravine, river and plateau line up with the hillshade). Exported at <= 1024 px (0.5 m/px).
- All 340 terrain tiles have both files. Cell terrain converts in ~0.1 s.

## S5 index (2026-10-09)
- `leveldata/locationmarkers.core` = ObjectCollection of three hunting-ground marker files only (no Mother's Heart).
  Mother's Heart village markers are AIMarkers in `tiles/tile_x04_y-03/layers/gameplay/markers.core`
  (M_Area_Marketplace, M_Area_Entrance, M_Area_AloyHome ...). Start position = M_Area_Marketplace.
- Campfires: `layers/gameplay/campfires.core` SceneInstances with Prefab
  `levels/worlds/world/scenes/campfire_save/scene_campfire_save_resource`; id = Name. Tile (4,-3): 3 campfires,
  start campfire Campfire_x04_y-03_01 (47 m from the marketplace). Their Z matches the terrain within 0.33 m - an
  independent check of the height scale (raw/32), the row/column orientation and the world placement.
- Acceptance: `python -c "...index.json..."` -> `340 512.0 [4, -3] True`.

## S6 full cells (2026-10-09)
- Static geometry = layer files `tiles/<t>/layers/geometry/*.core` (skipping cinematic/quest/lighting/skybox dressing).
  StaticMeshInstance (lead WorldTransform) -> Resource: LodMeshResource / StaticMeshResource / MultiMeshResource
  (Parts: [{Mesh, Transform}] composed with the instance). PrefabInstance -> PrefabResource.ObjectCollection,
  recursive, Overrides {RuntimeObject uuid, IsRemoved, IsTransformOverridden + Mat44}. Transforms compose
  child * parent (row-vector), ChildTransformsRelative honoured.
- Building blocks have three chains: *_VisualLodChain (placed), *_ShadowLodChain (DrawFlags bit 3 = shadow caster
  only) and *_OccluderLodChain (*_occ_L1 boxes). Also *_ShadowGeo, ProxyShadowMesh*. Compound buildings (Mother's
  Heart entrance, lodge, bridge) are LodMeshResources whose LOD0 is a MultiMeshResource -> expanded.
  generated_content/ holds merged far-LOD proxies and a baked copy of hand-placed vegetation (2131/2141 identical in
  tile 4,-3) -> skipped.
- Unknown types with members before ObjectUUID break UUID lookups; CoreFile.Find falls back to UUIDs at the usual
  lead offsets (60, 64, 4, 2, 3, 16, 48, 5, 8).
- Shared meshes: LOD = finest within 12k vertices; textures shared in hzd/textures at 512 px. Rocks have no colour
  map (coloured by the ecotope shader): neutral stone x AO channel of their own set. Foliage cut-outs come from an
  Alpha (type 2) channel of the set. Base colour sources by tier: models/ sets, shader_libraries/ sets, textures/.
- Campfires and machine sites per tile (see S5 / hooks hzd.tile_robots). Fixed machine sites: 80 groups in the main
  world (layers/scenes/robot encounters + robot_placement; random world encounters skipped). Vegetation: density map
  (512^2 RGBA, north up - best correlation with albedo greenness) + up to 6 species per channel from placement.core.
- Mother's Heart cell (4,-3): 23,093 instances, 768 meshes, 3 campfires, 3.1 s conversion; the first cell writes
  ~160 MB (13 MB cell + shared meshes 84 MB + textures 60 MB); later cells reuse most meshes.
- Visual check (dev Godot viewer in scratch): village huts, trees, rock cliffs, snow and the campfire land where they
  belong on the real terrain.

### Variant B site table (fixed sites, main world; produced by `hzsconv hzd-sites`)
| original | groups | orig machines (mean) | v1 machine | v1 machines | rule |
|---|---|---|---|---|---|
| antelope | 5 | 44 | grazer | 28 | type:antelope |
| beachlizard | 1 | 3 | watcher | 3 | type:beachlizard |
| bison | 1 | 5 | strider | 5 | type:bison |
| cargorhino | 1 | 2 | strider | 2 | type:cargorhino |
| crab | 2 | 7 | strider | 7 | type:crab |
| direwolf | 1 | 1 | watcher | 2 | type:direwolf |
| glider | 1 | 4 | watcher | 3 | type:glider |
| goat | 12 | 60 | strider | 53 | type:goat |
| harvester | 4 | 16 | grazer | 17 | type:harvester |
| horse | 20 | 74 | strider | 76 | type:horse |
| hyena | 2 | 7 | watcher | 6 | type:hyena |
| longhorn | 23 | 88 | grazer | 89 | type:longhorn |
| longleg | 1 | 2 | watcher | 2 | type:longlegbird |
| mole | 1 | 2 | watcher | 2 | type:mole |
| scout | 2 | 5 | watcher | 5 | type:scout |
| spraybot | 3 | 5 | strider | 7 | type:spraybot |
80 site groups in 360 tiles, 930 ms

## S7 Strider, Grazer, sounds, music, ambience (2026-10-09)
- Internal names confirmed from CharacterDescriptionComponentResource (table in S2): Strider = horse, Grazer =
  harvester (not antelope). Strider/Grazer convert with the same builder (165 / 157 joints).
- WaveResource: lead members EncodingQuality (e4), IsStreaming, UseVBR before the ObjectUUID; WaveData inline or data
  source. EWaveDataEncoding 0 PCM, 3 ATRAC9, 4 MP3. Machine effects: 934 MP3 + 64 PCM + 1 ATRAC9 (scout/horse/harvester).
  Roles assigned from wave names (no soundbank graph evaluation); every role of the three machines has files.
- Music: world.core MusicResource -> Echo bank (ECHO/MEDA(PICD)/STRL) -> 746 MP3 tracks in 3 streaming banks.
  Cues exported: explore_nora (exploration_nora_02_flutetheme, 299 s), explore_nora_2, combat (robot_fight_v4 intro +
  high-01..12, 143 s), sneak. Concatenated MP3 frames play as one file (ffprobe ok).
- Ambience: outdoor wind/rain beds are 6-channel ATRAC9 (RIFF extensible with the ATRAC9 sub-format GUID) - not
  decodable. Used instead: bird calls of sounds/environments/senv_fauna_forestconiferous (MP3) + campfire loop.
- World sweep (hzsconv hzd-world --all --workers 2): 340/340 cells, 0 failures, all real terrain, 52 s total,
  median 0.1 s / max 5.7 s per cell; 131 cells have placed objects (1.63 M instances), 209 outer cells only terrain +
  procedural vegetation; 167 campfires, 80 machine sites; cache hzd 4.2 GB (cells 2.6 GB, meshes 1.1 GB,
  textures 0.39 GB).

## Content contract (D32, 2026-10-09)
- sheets/machines.json columns content_model / bone_roles / points (owner svet), all 3 rows filled. meta.json now has
  model, up "y", forward "-z", scale_m 1.0, bone_roles (role -> bone, only bones present in the converted skeleton),
  points ({bone, offset, radius?, kind weak_spot|attack_origin|fx, part?}), leg_chains as role names
  (leg_<id>_upper/lower/foot/toe; biped watcher: leg_l/leg_r, quadrupeds leg_fl/fr/bl/br) and leg_chains_bones.
- Weak-spot points: watcher weak_eye (Eye_helper), strider weak_canister, grazer weak_canister_1..4.
- Converter audio choice comes from systems audio.music_explore_track / audio.ambience_track. Still in converter code:
  combat/sneak music track families, the start marker name, layer-name skip lists, sound-role name patterns
  (converter-side mapping of HZD data; the game never sees them).
- S8: tools/proto_smoke.py -> PROTO OK (bootstrap 70 s on an empty cache incl. CS2, 4 ring cells, priority change,
  cancel, cached re-request, 2 parallel workers, bye + exit 0).

## D32 follow-up: HZD names out of code (2026-10-09)
- New sheet sheets/hzd_content.json (52 rows; groups archive, world, terrain, geometry, campfires, start, sites,
  vegetation, machines, audio, materials). Converter reads it through Hzs.Generated.HzdContentSheet via
  Sheets/HzdNames.cs (Str/Num/Int/List/Json/Fill/StripStream). Music explore track and ambience source stay in
  systems (audio.music_explore_track, audio.ambience_track; music_cues references the former as "@..."), tile size via
  the systems streaming.cell_size_m binding, start cell via systems streaming.start_cell (also the dev commands).
- What stays in code: RTTI type/member names of the hand-written layouts and file-format conventions (.core,
  .core.stream, .bin, ECHO/MEDA/STRL/PICD chunk tags) - format facts, not content.
- Verified identical output (sha1 of every file) before/after: cell 4_-3 (4 files), shared meshes (1542 files),
  textures (140), machines (137), audio (23), index.json.
- proto_smoke.py now passes --log-dir inside the test cache: the default log (logs/ next to the cache root) can be
  held open by another converter process, and Hzs.Common.Log opens it exclusively (FileShare.Read) -> the second
  converter crashed at start (reported to main).

## Fix round (F6 + visuals, 2026-10-09)
- F6: cell done.bytes was cell dir + WorldMeshes.BytesWritten (process-wide cumulative). Ensure now takes a per-job
  counter; a mesh another job is exporting is counted by that job. Check: sum over 5 cells of (logged - cell dir) ==
  hzd/meshes + hzd/textures on disk (384623522 bytes).
- TinyBCSharp writes 4 bytes per pixel for every format (BC4: R replicated to RGB + A 255; BC5: R, G, 0, 255). We
  labelled BC4/BC5 images 1/2 channels without repacking -> garbage (fine grid) in every BC4/BC5 read: foliage masks,
  AO of rocks. HzdTexture.Decode now keeps the first channels.
- Foliage cut-out = the channel of PackingInfo type Alpha (2), usually its own BC4 entry ("AlphaToCoverageBC4",
  values ~0.55-0.65 inside, soft edge); cutoff 0.5 gives the real thin needles/blades (lower cutoffs give blobs).
  Any other colour-map alpha (unused / translucency / height) is dropped (RGB PNG) - before, bark got holes.
  PackingInfo byte: low nibble type, bits 4-5 source channel, bit 7 set for single-channel sources (0x80 = none).
- Grass (carex etc.): colour is a standalone Texture "*_clr_tra" (BC3, A = translucency) outside any set, the mask is
  an alpha-only TextureSet bound to the same effect -> sheet materials.standalone_color + effect-level alpha set.
- Shared meshes: glb asset.extras.format = WorldMeshes.Format (2); older meshes are re-exported under the same id
  (textures rewritten once per process). cell.json format 2.
- Terrain: per-tile ShaderResources in layers/terrain/terraintiledata.core are HZD's compiled terrain shader (ecotope
  rules + shaders/ecotope/texturesetarrays/terrain_texture_array, 155 MB TextureList) - not reproducible from data.
  worlddata_flattened_albedo is the engine's bake of it (2048^2 BC1, alpha 255): now exported at full res
  (hzd_content terrain.albedo_px, RGB, ~8 MB per cell instead of ~3). Tile 4,-3 is snowy in HZD: the topo map
  channel A (ecotope_effect, placement curves: > 0.6 snow, 0.54-0.6 frost) marks 67% snow, and the tile's
  layers/ingamemap texture is white in the same area. worlddata_terrain_normal = 2048^2 BC5 (not exported: the
  game's terrain mesh has no tangents for a tangent-space map).
- Rocks: colourised assets (no colour map) are coloured in HZD by shaders/ecotope/colorize_maps/colorize_array_64
  (2DArray 128x8 x 64 RGBA ramps; Ecotope.EcotopeIndex probably selects the slice) inside compiled shaders - lookup
  not verifiable. Approximation: cell.json instances[].tint (linear multiplier) on meshes flagged #colorized =
  stone pulled towards the terrain bake around the instance (5x5 samples within 2 m, weight materials.ground_tint 0.5).
  4_-3: 5874 of 23093 instances tinted, median tint ~1.3 (snow).
- Procedural species (fixed in the vegetation round below).

## Vegetation round (2026-10-09)
- Most MeshPlacements have Mesh null and PlacementTargets -> PrefabResource -> ObjectCollection -> StaticMeshInstance
  (+ a *_ShadowGeo instance, skipped by geometry.skip_mesh_names); Placements.ForTarget expands them like world prefabs.
  4_-3: 241 placement layers -> 118 species (was 3).
- Layers point at single MeshPlacements inside the node file; the enclosing PlacementSets' DensityGraph / DensityScale
  apply too (parents found through the sets' Children in the same file).
- Density graphs: snow / frost / no-snow variants are gated by the ecotope effect map (worlddata/ecotope_effect = topo
  map channel A): DensityCurveLookup(Map = DensityWorldDataMap ecotope_effect, step Curve), DensityWorldDataMap with its
  own Curve, DensityInvert of it, DensityMultiply = intersection. Curve range = inputs where the curve >= 0.5
  (carex: snow > 0.601, frost 0.541..0.6, no snow < 0.54; aspen snow > 0.551). Other nodes (slope, height, variance,
  forest maps) are ignored. Hand-written layouts: CurveResource, DensityCurveLookup, DensityMultiply,
  DensityWorldDataMap, DensityInvert.
- HZD density per species = DensityScale product / Footprint^2 (Footprint = spacing; ground cover 0.5 m -> 4 per m2).
  expected = that x sum over the 512^2 density map (1 px = 1 m2) of channel density x effect in range.
- Choice per channel (vegetation.species_per_channel = 6): most placement layers, then most expected; the best of every
  distinct effect range first (so snow and no-snow variants both exist), species whose mesh has no colour texture are
  skipped (frost grass: "frost" is in materials.never_base_color -> opaque card).
- cell.json format 3: vegetation.effect (veg_effect.png), density_scale, species[].hzd_per_m2 / expected /
  max_instances / cluster / wander_m / effect_range. Sheet: vegetation.effect_map, effect_type, density_scale (0.25),
  max_instances_per_species (3000), cluster (design, per channel).
- 4_-3 picks: trees Colorado pinyon x2, quaking aspen (snow / no snow), lodgepole pine (snow / no snow); blockbush beaked
  willow; undergrowth fourwing saltbush, Payson's sedge (snow / no snow), carex, common weeds, white aster; stealth
  cover grass (snow / no snow).

## Shared files deleted by the game's cache GC (2026-10-09)
- WorldMeshes kept a per-process Lazy per mesh/texture and never wrote it again, so a cell converted again after the
  game's GC deleted its meshes referenced missing files. Now Ensure checks at use time that the glb, its sidecar and
  every texture the sidecar lists exist; if not, the cached Lazy is swapped atomically (TryUpdate) and exported
  again (one worker exports, others wait on the same Lazy; bytes count for the job that writes). Textures likewise,
  and the material `known` shortcut requires the PNG on disk.
- HzdConverter.CellUpToDate also requires every mesh/texture listed in cell.json to exist, so a cell whose shared
  files were collected is not answered `cached` but converted again.
- Check (scratch gc_regen.py, one serve session): 5,-3 converted, its 1194 glb + 223 png (+ half the sidecars)
  deleted, re-requested -> cached false, missing 0/0; 4,-3 same with the cell dir deleted too -> missing 0/0.

## 0.2 V0 texture audit + encoder (2026-10-09)
- Start area 3x3 around 4,-3 (cache-svetwork/c24, scratch texaudit.py; machines from cache-dev):
  albedo 307 (62.1 MPix, mostly 512^2), albedo_alpha 119 (25.4 MPix), terrain albedo 9 x 2048^2, veg maps 18 x 512^2,
  machine colour 9. textures: 462, VRAM est 690 MiB uncompressed (RGBA8 + mips) -> 109 MiB BC.
- Encoder benchmark (hzsconv hzd-bcbench, 24 nora building colour maps, 5.37 MPix, 1 thread):
  BCnEncoder.Net 2.3.0 (MIT OR Unlicense): BC1 fast 32 ms/MPix 24.6 dB, balanced 150 ms/MPix 29.4 dB; BC5 65 ms 46.9 dB;
  BC7 fast 5977 ms/MPix 36.9 dB, balanced 13796 ms/MPix 41.2 dB -> BC7 far too slow for on-demand cells.
  Own encoders (Assets/BcEncode.cs, no dependency): BC1 249 ms/MPix 30.4 dB, BC3 284 ms 31.7 dB, BC5 115 ms 44.6 dB,
  BC7 (mode 6 only) 304 ms/MPix 32.7 dB. Choice: own encoders; BCnEncoder not kept.
- Per-cell conversion before V1 (c24, 2 workers, cold): 0.4 - 4.2 s per cell, 9 cells in 13 s.

## 0.2 V1 + V2 (2026-10-09)
- V1: every image the converter writes for the world is DDS (Assets/Dds.cs): "DDS " + DDS_HEADER (124 bytes; flags
  CAPS|HEIGHT|WIDTH|PIXELFORMAT|MIPMAPCOUNT|LINEARSIZE = 0xA1007; pitchOrLinearSize = top mip bytes; mipMapCount =
  full chain to 1x1; ddspf FourCC "DX10"; caps 0x401008) + DDS_HEADER_DXT10 (dxgiFormat, dimension 3 = TEXTURE2D,
  miscFlag 0, arraySize 1, miscFlags2 0), then mips largest first, ceil(w/4) x ceil(h/4) blocks each, rows top-down.
  DXGI: BC1 71 / 72 sRGB, BC3 77 / 78 sRGB, BC5 83, BC7 98 / 99 sRGB. Godot 4.7.2 editor (headless)
  Image.load_dds_from_buffer: BC1 -> FORMAT_DXT1 (17), BC7 -> FORMAT_BPTC_RGBA (22), mipmaps 11 for 2048 (= 12 levels),
  ImageTexture ok, decompress ok (release template: hra H3).
  Mesh colour BC1 sRGB / cut-out BC7 sRGB (mip alpha scaled so the 0.5 cut keeps the top mip's coverage); cell
  albedo.dds BC1 sRGB; veg_density/veg_effect.dds BC7 linear (CPU-side maps, game decompresses).
  Whole world after V1 (cache-svetwork/c25, 2 workers): 340 cells, 0 failed, 134 s, median 485 ms, p90 1.26 s, max 8.4 s.
- V2: HZD texture-set channel types per entry (PackingInfo low nibble; high nibble bits 4-5 = source channel):
  normal X/Y = type 3 source 0/1 (mostly channels 0/1 of a BC7 / BC1 / BC5 / BC6U map, B = AO or roughness);
  AO = 5, roughness = 6 (often a 1x1 RGBA_8888 constant), no metallic (Reflectance = 4 is not used).
  Normal maps are +Y up (glTF): integrability test (curl of the implied gradient) prefers +Y up on 59/60 building,
  40/40 rock and 40/40 eco-asset maps -> stored as-is, BC5 linear. ORM (R AO, G roughness, B 0) BC1 linear at half the
  colour size; colourised meshes keep occlusion 1 (AO is in the stone colour). BC6U/BC6S decode added (some snow
  vegetation normal maps).
  Terrain normal.dds: HZD worlddata_terrain_normal is world space (R east, G north; corr with height gradients
  -0.87 / +0.71, slope scale 0.96) -> Godot world XZ (G flipped), BC5, 1024^2; fallback from the heights.
  instances[].kind from hzd_content geometry.kind_rules. 4_-3: normalTexture on rock meshes 100 %, building 98.2 %,
  vegetation 84 %, props 100 %.
- Encoder speed after projection indices (palette collinear): BC1 91, BC3 64, BC5 40, BC7 116 ms/MPix (same PSNR).
- Per-cell after V2 (c31, 3x3, 2 workers, cold): 0.7 - 10.1 s, 9 cells in 22 s (before 0.2: 13 s). Log line now
  carries cpu ms per phase (bc_encode dominates: 4,-3 = 8.5 s CPU of ~150 MPix colour + normal + ORM incl. mips).
- VRAM start 3x3 (sum of DDS = GPU bytes): mesh BC1 707 / 52.9 MiB, BC5 414 / 110.5 MiB, BC7 119 / 32.3 MiB, cell
  albedo 24 MiB, cell normal 12 MiB -> 232 MiB GPU textures (+ ~7 MiB machines, still PNG in model.glb). Before
  (V0 audit): 690 MiB if uploaded as RGBA8 + mips, without any normal / ORM maps.
- Whole world after V2 (c33, 2 workers): 340 cells, 0 failed, 159 s, median 518 ms, p90 1.72 s, max 10.6 s,
  cache hzd 5.15 GB (after V1 134 s / 4.36 GB).

## 0.2 V3 new machines (2026-10-09)
- hzd_health: direwolf.core DireWolfDestructibilityResource 1100 (Corrupted 1650), hyena.core Hyena_DefaultDestructibilityResource
  220 (Corrupted 330), longhorn.core LongHornDestructibilityResource 175 (Corrupted 263); grazer's 150 unchanged.
- Weak spots (DestructibilityPart BoneName, DamageToEntityMultiplier 1.5): Sawtooth DireWolf_CanisterPart ->
  DireWolf_Canister_Fuel_helper; Scrapper Hyena_BatteryPart -> Battery_helper (power cell), Hyena_RadarPart ->
  Radar_helper; Broadhead Canister_{Left,Right}_01Part -> {L,R}_Longhorn_Canister_Fuel_helper. Eyes 2.0x (fx points).
- The Sawtooth (direwolf) mesh is skinned to the greywolf (Ravager) rig; its own helpers (canister, eye, plates) are in
  direwolf/animation/skeletons/*_helpers. MachineBuilder now reads helpers from the sheet skeleton folder first, then
  from the mesh skeleton's folder, maps helper parent indices by joint name through the folder's own skeleton and
  matches DestructibilityPart bones case-insensitively (Eye_helper vs eye_helper). Before: plates at Ravager positions.
  Watcher / Strider / Grazer meta (bones, positions, chains, weak spots, points, roles) unchanged.
- The longhorn entity uses ai/characters/horse (Strider's AI): perception 45 m / 12 deg / 96 m / hearing 20 m.
  Sawtooth and Scrapper resolve 45 / 25 / 96 / 100 / 30 / 15 from their own AI files.
- Leg chains: paws with three toes on the ground (direwolf/hyena rigs) break the one-grounded-leaf derivation; then the
  chains are the joint paths of the bone_roles legs (upper .. toe). Roles: foot = joint carrying the toes, toe = middle toe.
- Sounds: machine sound folders = own + every robot folder of the sheet sound banks (Broadhead body sounds = horse);
  patterns + scavenge, vox_hit, vox_hr_, footdown.
- site_map prepared (merge last): type:direwolf -> sawtooth, type:hyena -> scrapper, type:longhorn -> broadhead (x1.0).

Sites of the new machines (svet 0.2 V3, hzsconv hzd-sites after site_map type:direwolf/hyena/longhorn -> sawtooth/scrapper/broadhead):

| tile | site | original | orig count | 0.2 machine | count | rule |
|---|---|---|---|---|---|---|
| -3,-3 | FE_Horse | longhorn | 6-8 | broadhead | 6 | type:longhorn |
| -3,0 | FE_Longhorn | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| -2,0 | FE_Longhorn | longhorn | 4-4 | broadhead | 4 | type:longhorn |
| -2,1 | FE_Longhorn_01 | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| -1,-2 | FE_Longhorn | longhorn | 6-8 | broadhead | 6 | type:longhorn |
| -1,0 | FE_Longhorn_01 | longhorn | 3-5 | broadhead | 4 | type:longhorn |
| 0,-2 | Longhorn_01 | longhorn | 3-4 | broadhead | 4 | type:longhorn |
| 0,-2 | Horse_03 | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| 0,-2 | Longhorn_02 | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| 0,0 | Longhorn_01 | longhorn | 3-5 | broadhead | 4 | type:longhorn |
| 1,-3 | Longhorn_01 | longhorn | 4-4 | broadhead | 4 | type:longhorn |
| 1,-2 | Longhorn_02 | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| 1,-1 | Horse | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| 1,-1 | Longhorn_03 | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| 1,0 | Longhorn_02 | longhorn | 3-5 | broadhead | 4 | type:longhorn |
| 2,-1 | Horse | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| 2,-1 | Longhorn_2 | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| 2,0 | Horse_01 | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| 2,0 | Longhorn_01 | longhorn | 3-5 | broadhead | 4 | type:longhorn |
| 3,-4 | FE_Hyena_Scene | hyena | 4-4 | scrapper | 4 | type:hyena |
| 3,-2 | Longhorn_Scene | longhorn | 6-8 | broadhead | 6 | type:longhorn |
| 3,-1 | DireWolf_Mountain_Scene | direwolf | 1-1 | sawtooth | 1 | type:direwolf |
| 4,-4 | FE_Hyena | hyena | 3-3 | scrapper | 3 | type:hyena |
| 6,-1 | FE_Longhorn | longhorn | 3-3 | broadhead | 3 | type:longhorn |
| 6,0 | FE_Longhorn_01 | longhorn | 4-4 | broadhead | 4 | type:longhorn |
| 6,0 | FE_Longhorn | longhorn | 3-3 | broadhead | 3 | type:longhorn |

| original | sites | orig machines | 0.2 machine | machines | rule |
|---|---|---|---|---|---|
| direwolf | 1 | 1 | sawtooth | 1 | type:direwolf |
| hyena | 2 | 7 | scrapper | 7 | type:hyena |
| longhorn | 23 | 88 | broadhead | 86 | type:longhorn |

## 0.2 V4 terrain layers (2026-10-09)
- HZD's terrain material per ecotope (shaders/ecotope/<eco>/terrain/terrainmaterial_*) = RenderEffectResource + compiled
  ShaderResource sampling texturesetarrays/terrain_texture_array (TextureList); layer choice and weights live in shader
  code -> not readable. Only shaders/ecotope/21-southernrockies/terrain/textures (start region) and two single sets
  (19 soil_deep_03, 20 soil_sand_02) are per-layer sets. Fallback (plan V4): sheet terrain.layers = snow_heavyfresh_01,
  soil_grassy_02, soil_dry_02, rock_sedimentary_04 (colour BC1, normal BC5, ORM from AO / roughness), shared
  hzd/terrain_layers/<name>_{albedo,normal,orm}.dds 1024^2.
- masks.dds per cell (BC7 512^2, R snow, G grass, B dirt, A rock): rock = smoothstep(32, 48 deg) of the height slope,
  snow = (1 - rock) x smoothstep(0.50, 0.62) of the ecotope effect (frost 0.54-0.6 / snow > 0.6 like the placement
  curves), grass = rest x clamp(undergrowth density x 1.5 - roads), dirt = rest. 4_-3: snow 0.48, grass 0.13,
  dirt 0.02, rock 0.37; after BC7 |sum - 1| mean 0.005, 0.5 % of pixels > 0.05 (max 0.19) -> the shader normalises.

## 0.2 V5 water (2026-10-09)
- Per tile levels/worlds/world/tiles/tile_x<X>_y<Y>/layers/water/tile_<X>_<Y>_water.core: ObjectCollection of
  StaticMeshInstances -> LodMeshResources (river / lake surfaces, vertices in absolute height, instance origin y 0) +
  water RenderEffects / ShaderResources (compiled water shading). Tile 4,-3: 31 surfaces, 182-299 m, following the
  valleys and the river (Godot render cache-svetwork/shots/water_4_-3_0.png). cell.json format 7 water.instances
  (meshes exported like the world meshes; hzd_content water.layer); systems render.water filled.

## 0.2 V6 occluders + HLOD (2026-10-09)
- MeshRef carries the glb POSITION bounds and "all materials opaque" (read from the exported glb JSON, cached).
- occluders: boxes for opaque building / rock instances with a world edge >= 8 m (render.occluder_min_size_m),
  mesh bounds x 0.8, largest 256; terrain grid 33 x 33 (16 m) = local minimum of the heights - 1 m.
- hlod.glb: per instance the finest HZD LOD with <= 400 vertices (LodMeshResource chain; else the coarsest), largest
  buildings / rocks >= 4 m first until 20000 triangles; vertex colour = linear average of the material colour map at
  16 px (stone for colourised rocks). 4_-3: 256 boxes, hlod 19998 triangles from 108 instances (mostly the big rocks,
  the village's parts are smaller than the rocks).
- hra's DDS test (release-hra-h3) runs hzsconv from this worktree's bin; while it runs, builds go to
  scratchpad/hzsout (no overwrite of DLLs in use).

## 0.2 V7 ATRAC9 (2026-10-09)
- Attempt 1: no ATRAC9 package on NuGet; LibAtrac9 (Alex Barney, MIT) C# sources vendored into
  Hzs.Decima/Audio/LibAtrac9 (+ LICENSE, header + '#nullable disable' only) and listed in THIRD_PARTY_NOTICES.
  Inline mono weather spot sounds decoded at once (AT9 RIFF inside WaveData).
- Attempt 2: streamed bank waves read 0 bytes: the stream data source length is 0 for waves inside soundbanks ->
  length = WaveDataSize. AT9 RIFF: fmt WAVEFORMATEXTENSIBLE (mask +20), version +40, 4-byte config +44; fact =
  samples, overlap delay, encoder delay; data = superframes. 6 channels -> stereo by the extensible mask (ITU-like
  0.707 centre / surround, LFE dropped, scaled only against clipping).
- hzd/audio/ambience/wind_0/1.wav (OpenMountain_wind_heavy/medium, 34 / 32 s) and rain_0/1.wav (rain_mountain_low/high)
  from weather_mountain.soundbank (hzd_content audio.ambience_extra with name_contains). Wind spectral centroid
  ~950 Hz, rain ~6.8 kHz (not decoder noise). HzdFormat 2 (machines V3 + audio change: caches re-convert them).

## 0.2 render.* sky / fog / sun bindings (2026-10-09)
- ambience/cycles/regions/nora/nora_mothers_heart_cycle.core holds several AmbienceCycles (one-keyframe overrides +
  the day cycle with 9 keyframes: 4.7, 5, 10, 16, 20, 21, 21.3 h). Hand-written layouts AmbienceCycle,
  AmbienceSettingsKeyFrame, AmbienceSettings, Atmosphere{Fog,Haze,Sky}SettingsResource + settings structs.
- Sheets/Ambience.cs evaluates "AmbienceCycle.<Curve>@T" (CurveResource, X = hours, linear; the curves are flagged
  Smooth with tangents, not used) and "AmbienceCycle.AmbienceKeyFrames[TimeOfDay=T].AmbienceSettings.<Res>.<Field>"
  (linear between the surrounding keyframes, 24 h wrap, keyframes without the resource skipped).
- At 9.0 h: sun elevation 17.5 deg, azimuth 90 deg, fog density 87.5 (HZD units), start 50 m, end 950 m,
  height 220 m, falloff 0.1625, fog colour [1,1,1], sky colour [0.141, 0.624, 1.0] (linear), zenith 0.0625,
  horizon 16, sun shape 0.5. No keyframe has haze settings -> render.haze_* use their fallbacks.

## 0.2 follow-up: converter next to the running game (2026-10-10)
- serve: process BelowNormal priority, worker threads BelowNormal. Protocol op (hooks proto.throttle):
    {"id":N,"op":"throttle","workers":1,"threads":2}  -> {"id":N,"event":"throttled","workers":1,"threads":2}
  workers = jobs at once (1..--workers, takes effect for the next job), threads = parallel-loop threads of one job
  (ConversionLimits; default 2 for 1 worker, else half the logical cores). status reports workers / threads.
  Game side (hra): workers 1 / threads 2 while the player is in the world, workers 2 on the loading screen.
- Every converter Parallel loop uses ConversionLimits (mesh export, species, water, BC encoding of big maps; before:
  4 per job + ProcessorCount for big maps).
- Timing (scratch cpu_share.py, 6 cells around 4,-3, new caches, 12 logical cores): unthrottled 16.7 s, converter CPU
  mean 27.9 % / p95 43.0 % / max 45.6 %; throttled (1 / 2) 43.3 s, mean 9.6 % / p95 14.6 % / max 17.2 %;
  priority class 16384 = BELOW_NORMAL.
- DDS: the top level is resampled to a multiple of 4 (1x1 constants became 4x4); WorldMeshes.Format 5 so old tiny
  textures are rewritten. Before: 2 of 932 textures in a 3x3 cache not divisible by 4, after 0 of 1065.
- cell.json "sheets" = hash of site_map, hzd_content, machines id / herd sizes, systems render.* / streaming.* values
  (not descriptions); CellUpToDate requires the same hash. Check: a cell with a changed hash is converted again
  (cached false), an unchanged one is served cached.

## 0.2 t14 building normal maps (2026-10-10)
- t14 / F8: buildings 72.8 % with a normal map (same 72.6 % recomputed from cache-svetwork/c33, 5x5 around 4,-3).
  Causes: (1) Cauldron walls / floors (foundry wall_b025/b026, floor_b005: ~45 k instances) use a procedural material
  that binds plain textures, no texture set: wall_b0xx_cmp = composite map with RG = normal XY (B / A masks), next to
  *_cmp_02 masks and tiling granite *_nmt details; (2) invisible helper geometry was exported: *_occ_L1 /
  *_occlusion LOD chains (effect Z_Prime_PlaneOccluders@IBL or DoubleSided, 12-55 vertices) and collision quads
  (effect Coll_Mat); (3) moss sprigs on ruin dressing bind moss_sprigs_2016_nmt_msk as a plain texture.
- Fix: materials.standalone_normal (_cmp, _nmt) plain textures whose R, G average ~0.5 and stay in the unit circle
  (checked on the 64 px mip) are the normal map when no set has a normal channel (_cmp_02 masks fail the check);
  geometry.skip_effect_names (Coll_Mat, Occluder) drop primitives; geometry.skip_mesh_names + _occlusion.
  WorldMeshes.Format 6. Materials still without a normal carry extras {hzd_normal: "none"} (e.g. dressing_b128_c001 m0
  SDF_Layered effect with no texture bindings, RF_FloorGlass wedges, BSP tunnel / cradle pieces, snow drifts).
- After (cache-svetwork/c54, 5x5 around 4,-3): building 312 078 / 314 160 = 99.3 % (100 % with the hzd_normal none
  materials excluded), rock 100.0 %, vegetation 100.0 %; 35 997 fewer building instances (invisible helpers).
