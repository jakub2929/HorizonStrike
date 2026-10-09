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
