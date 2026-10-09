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
