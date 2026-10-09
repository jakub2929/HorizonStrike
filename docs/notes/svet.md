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
