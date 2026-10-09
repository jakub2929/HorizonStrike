"""Dev tool (never packaged): summarize a .glb from the cache.

  python tools/glb_info.py <file.glb> [--nodes] [--anims] [--json]

Prints one line per check: animations (names + duration), skins (joint counts), meshes, materials, textures
(max edge px read from the embedded PNG/JPEG headers), bounds of POSITION accessors (meters) and node count.
Exit code 0 when the file parses, 1 otherwise. Pure standard library.
"""
import json
import struct
import sys


def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, version, length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise ValueError("not a glTF 2.0 binary")
    off = 12
    gltf, binchunk = None, b""
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            gltf = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            binchunk = chunk
        off += 8 + clen
    if gltf is None:
        raise ValueError("no JSON chunk")
    return gltf, binchunk


def image_size(b):
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", b[16:24])
        return w, h
    if b[:2] == b"\xff\xd8":
        i = 2
        while i < len(b):
            if b[i] != 0xFF:
                i += 1
                continue
            marker = b[i + 1]
            if marker in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack(">HH", b[i + 5:i + 9])
                return w, h
            seglen = struct.unpack(">H", b[i + 2:i + 4])[0]
            i += 2 + seglen
    return None


def accessor_floats(gltf, binchunk, idx):
    acc = gltf["accessors"][idx]
    bv = gltf["bufferViews"][acc["bufferView"]]
    if acc.get("componentType") != 5126:
        return None
    n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}.get(acc["type"])
    if n is None:
        return None
    stride = bv.get("byteStride", 4 * n)
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    out = []
    for i in range(acc["count"]):
        out.append(struct.unpack_from("<" + "f" * n, binchunk, base + i * stride))
    return out


def summarize(path):
    gltf, binchunk = read_glb(path)
    info = {"file": path}
    anims = []
    for a in gltf.get("animations", []):
        dur = 0.0
        for s in a.get("samplers", []):
            acc = gltf["accessors"][s["input"]]
            if "max" in acc:
                dur = max(dur, acc["max"][0])
        anims.append({"name": a.get("name", ""), "duration": round(dur, 4), "channels": len(a.get("channels", []))})
    info["animations"] = anims
    info["skins"] = [{"name": s.get("name", ""), "joints": len(s.get("joints", []))} for s in gltf.get("skins", [])]
    info["meshes"] = len(gltf.get("meshes", []))
    info["materials"] = [m.get("name", "") for m in gltf.get("materials", [])]
    info["nodes"] = len(gltf.get("nodes", []))
    sizes = []
    for img in gltf.get("images", []):
        if "bufferView" in img:
            bv = gltf["bufferViews"][img["bufferView"]]
            o = bv.get("byteOffset", 0)
            sz = image_size(binchunk[o:o + min(bv["byteLength"], 65536)])
            sizes.append(sz)
        else:
            sizes.append(None)
    info["textures"] = len(sizes)
    info["max_texture_px"] = max((max(s) for s in sizes if s), default=0)
    lo, hi = [float("inf")] * 3, [float("-inf")] * 3
    for m in gltf.get("meshes", []):
        for p in m.get("primitives", []):
            a = gltf["accessors"][p["attributes"]["POSITION"]]
            if "min" in a and "max" in a:
                lo = [min(x, y) for x, y in zip(lo, a["min"])]
                hi = [max(x, y) for x, y in zip(hi, a["max"])]
    info["bounds_m"] = [[round(x, 4) for x in lo], [round(x, 4) for x in hi]] if lo[0] != float("inf") else None
    return gltf, binchunk, info


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if not args:
        print(__doc__)
        return 2
    rc = 0
    for path in args:
        try:
            gltf, binchunk, info = summarize(path)
        except Exception as e:  # noqa: BLE001 - report and continue with the next file
            print(f"{path}: ERROR {e}")
            rc = 1
            continue
        if "--json" in flags:
            print(json.dumps(info))
            continue
        print(path)
        print("  animations " + " ".join(a["name"] for a in info["animations"]))
        for a in info["animations"]:
            print(f"    {a['name']}: {a['duration']} s, {a['channels']} channels")
        print(f"  skins={len(info['skins'])} " + " ".join(f"{s['name']}:{s['joints']}" for s in info["skins"]))
        print(f"  meshes={info['meshes']} nodes={info['nodes']} materials={len(info['materials'])} textures={info['textures']} max_texture_px={info['max_texture_px']}")
        print(f"  bounds_m={info['bounds_m']}")
        if "--nodes" in flags:
            nodes = gltf.get("nodes", [])
            parent = {}
            for i, n in enumerate(nodes):
                for c in n.get("children", []):
                    parent[c] = i

            def depth(i):
                d = 0
                while i in parent:
                    i = parent[i]
                    d += 1
                return d

            for i, n in enumerate(nodes):
                extra = []
                if "mesh" in n:
                    extra.append(f"mesh={n['mesh']}")
                if "skin" in n:
                    extra.append(f"skin={n['skin']}")
                if "translation" in n:
                    extra.append("t=" + ",".join(f"{x:.4f}" for x in n["translation"]))
                if "rotation" in n:
                    extra.append("r=" + ",".join(f"{x:.3f}" for x in n["rotation"]))
                print(f"    {'  ' * depth(i)}[{i}] {n.get('name', '')} {' '.join(extra)}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
