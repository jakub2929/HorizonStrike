"""Dev tool (never packaged): check a converted HZD cell in the cache.

  python tools/cell_info.py <cache>/hzd/cells/<x>_<y> [--seam <other cell dir>] [--preview out.png] [--json]

Prints one summary line: terrain realness, height file size check, NaN count, height range, instance/mesh counts,
missing shared meshes, campfires, spawns (types) and vegetation channels, then one line per channel with its species
(max_instances, effect range). --textures checks the cell's image files and the shared textures it lists (png/jpg
count, DDS formats, full mip chains). --seam compares the shared edge with an
adjacent cell (max height difference in meters). --preview writes a hillshade PNG of the heights (north up).
Pure standard library. Exit code 0 when the cell parses, 1 otherwise.
"""
import json
import math
import os
import struct
import sys
import zlib


def load(cell_dir):
    with open(os.path.join(cell_dir, "cell.json"), encoding="utf-8") as f:
        cell = json.load(f)
    t = cell["terrain"]
    w, h = t["res"]
    path = os.path.join(cell_dir, t["file"])
    data = open(path, "rb").read()
    bytes_ok = len(data) == w * h * 4
    heights = struct.unpack("<%df" % (w * h), data[: w * h * 4]) if bytes_ok else ()
    return cell, w, h, heights, bytes_ok


def edge(heights, w, h, side):
    if side == "north":
        return heights[0:w]
    if side == "south":
        return heights[(h - 1) * w: h * w]
    if side == "west":
        return heights[0::w]
    return heights[w - 1::w]


def seam(a_dir, b_dir):
    ca, wa, ha, hA, _ = load(a_dir)
    cb, wb, hb, hB, _ = load(b_dir)
    (ax, ay), (bx, by) = ca["cell"], cb["cell"]
    if (bx, by) == (ax, ay + 1):
        ea, eb = edge(hA, wa, ha, "north"), edge(hB, wb, hb, "south")
    elif (bx, by) == (ax, ay - 1):
        ea, eb = edge(hA, wa, ha, "south"), edge(hB, wb, hb, "north")
    elif (bx, by) == (ax + 1, ay):
        ea, eb = edge(hA, wa, ha, "east"), edge(hB, wb, hb, "west")
    elif (bx, by) == (ax - 1, ay):
        ea, eb = edge(hA, wa, ha, "west"), edge(hB, wb, hb, "east")
    else:
        raise SystemExit("cells %s and %s are not adjacent" % ((ax, ay), (bx, by)))
    if len(ea) != len(eb):
        raise SystemExit("edge resolutions differ: %d vs %d" % (len(ea), len(eb)))
    d = [abs(x - y) for x, y in zip(ea, eb)]
    return max(d), sum(d) / len(d)


def write_png(path, w, h, gray):
    raw = b"".join(b"\x00" + bytes(gray[y * w:(y + 1) * w]) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def hillshade(heights, w, h, spacing):
    out = bytearray(w * h)
    lx, ly, lz = -0.5, -0.5, 0.707  # light from north-west, above
    for r in range(h):
        for c in range(w):
            c0, c1 = max(c - 1, 0), min(c + 1, w - 1)
            r0, r1 = max(r - 1, 0), min(r + 1, h - 1)
            dx = (heights[r * w + c1] - heights[r * w + c0]) / ((c1 - c0) * spacing)
            dz = (heights[r1 * w + c] - heights[r0 * w + c]) / ((r1 - r0) * spacing)
            nx, ny, nz = -dx, -dz, 1.0
            n = math.sqrt(nx * nx + ny * ny + nz * nz)
            v = max(0.0, (nx * lx + ny * ly + nz * lz) / n)
            out[r * w + c] = min(255, int(40 + 215 * v))
    return out


DXGI = {71: "BC1", 72: "BC1", 77: "BC3", 78: "BC3", 83: "BC5", 98: "BC7", 99: "BC7"}
SRGB = {72, 78, 99}


def dds_info(path):
    """(format, srgb, w, h, mips, mips_ok) of a DDS written by the converter, or None."""
    with open(path, "rb") as f:
        d = f.read()
    if len(d) < 148 or d[:4] != b"DDS " or d[84:88] != b"DX10":
        return None
    h, w, mips = struct.unpack_from("<III", d, 12)[0], struct.unpack_from("<I", d, 16)[0], struct.unpack_from("<I", d, 28)[0]
    dxgi = struct.unpack_from("<I", d, 128)[0]
    fmt = DXGI.get(dxgi, "dxgi%d" % dxgi)
    bb = 8 if fmt == "BC1" else 16
    size, mw, mh = 0, w, h
    for _ in range(mips):
        size += max(1, (mw + 3) // 4) * max(1, (mh + 3) // 4) * bb
        mw, mh = max(1, mw // 2), max(1, mh // 2)
    full = max(w, h).bit_length()
    return fmt, dxgi in SRGB, w, h, mips, mips == full and len(d) == 148 + size


def textures(cell_dir, cell):
    """--textures: image files of the cell and the shared textures it lists: png/jpg count, DDS formats, mip chains."""
    files = [os.path.join(cell_dir, f) for f in sorted(os.listdir(cell_dir)) if f.lower().endswith((".png", ".jpg", ".jpeg", ".dds"))]
    tex_dir = os.path.normpath(os.path.join(cell_dir, "..", "..", "textures"))
    for t in cell.get("textures") or []:
        for ext in (".dds", ".png"):
            if os.path.exists(os.path.join(tex_dir, t + ext)):
                files.append(os.path.join(tex_dir, t + ext))
                break
    png = [f for f in files if not f.lower().endswith(".dds")]
    formats, bad, total = {}, [], 0
    for f in files:
        if f in png:
            continue
        i = dds_info(f)
        if i is None or not i[5]:
            bad.append(os.path.basename(f))
            continue
        key = "%s%s" % (i[0], "_srgb" if i[1] else "")
        formats[key] = formats.get(key, 0) + 1
        total += os.path.getsize(f)
    print("textures files=%d png_jpg=%d dds=%d formats=%s mips_ok=%s bytes=%d" % (
        len(files), len(png), len(files) - len(png), dict(sorted(formats.items())), not bad, total))
    if bad:
        print("  bad dds:", ", ".join(bad[:10]))


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    cell_dir = args[0]
    cell, w, h, heights, bytes_ok = load(cell_dir)
    t = cell["terrain"]
    nan = sum(1 for v in heights if v != v)
    finite = [v for v in heights if v == v]
    rng = (max(finite) - min(finite)) if finite else 0.0
    meshes = cell.get("meshes") or []
    mesh_dir = os.path.normpath(os.path.join(cell_dir, "..", "..", "meshes"))
    missing = [m for m in meshes if not os.path.exists(os.path.join(mesh_dir, m + ".glb"))]
    spawns = cell.get("spawns") or []
    veg = cell.get("vegetation") or {}
    info = {
        "cell": cell["cell"], "real": bool(t.get("real")), "bytes_ok": bytes_ok, "nan": nan, "range_m": round(rng, 2),
        "min_m": round(min(finite), 2) if finite else None, "max_m": round(max(finite), 2) if finite else None,
        "instances": len(cell.get("instances") or []), "meshes": len(meshes), "meshes_missing": len(missing),
        "campfires": len(cell.get("campfires") or []),
        "spawns": len(spawns), "spawn_types": sorted({"%s(orig %s)" % (s.get("type"), s.get("orig_type")) for s in spawns}),
        "vegetation": veg.get("channels") if isinstance(veg, dict) else None,
        "species": [{"channel": s.get("channel"), "name": s.get("name"), "max_instances": s.get("max_instances"),
                     "effect_range": s.get("effect_range")} for s in (veg.get("species") or [])] if isinstance(veg, dict) else [],
    }
    if "--json" in args:
        print(json.dumps(info))
    else:
        print("cell=%s real=%s bytes_ok=%s nan=%d range_m=%.2f (min %.2f max %.2f) instances=%d meshes=%d meshes_missing=%d "
              "campfires=%d spawns=%d %s vegetation=%s" % (
                  info["cell"], info["real"], bytes_ok, nan, rng, info["min_m"] or 0, info["max_m"] or 0, info["instances"],
                  info["meshes"], info["meshes_missing"], info["campfires"], info["spawns"], info["spawn_types"], info["vegetation"]))
        for ch in info["vegetation"] or []:
            names = ["%s(max %s%s)" % (s["name"], s["max_instances"],
                                        " effect %s..%s" % tuple(s["effect_range"]) if s.get("effect_range") else "")
                     for s in info["species"] if s["channel"] == ch]
            print("  species %s: %s" % (ch, ", ".join(names) if names else "-"))
    if "--seam" in args:
        mx, mean = seam(cell_dir, args[args.index("--seam") + 1])
        print("seam_max_delta_m=%.4f seam_mean_delta_m=%.4f" % (mx, mean))
    if "--textures" in args:
        textures(cell_dir, cell)
    if "--preview" in args:
        out = args[args.index("--preview") + 1]
        step = max(1, w // 512)
        sw, sh = (w + step - 1) // step, (h + step - 1) // step
        small = [heights[(r * step) * w + c * step] for r in range(sh) for c in range(sw)]
        write_png(out, sw, sh, hillshade(small, sw, sh, t.get("spacing", 1.0) * step))
        print("preview", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
