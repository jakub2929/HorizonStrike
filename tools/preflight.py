"""Preflight for Horizon Strike.

Two checks, run before every build:

  python tools/preflight.py sheets            # every row x column cell filled + verified, every ref resolves
  python tools/preflight.py package <dir|zip> # nothing derived from CS2 or HZD is in the release

Exit code 0 = clean, 1 = findings (listed), 2 = usage/IO error.
Sheet convention: see docs/ARCHITECTURE.md and sheets/*.json ("columns", "rows", "_verified", "_evidence").
"""
import json
import os
import struct
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHEETS = os.path.join(ROOT, "sheets")

UNFILLED = (None, "TODO", "", "?")


# ---------------------------------------------------------------- sheets

def load_sheets():
    sheets = {}
    if not os.path.isdir(SHEETS):
        return sheets
    for name in sorted(os.listdir(SHEETS)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(SHEETS, name), encoding="utf-8") as f:
            data = json.load(f)
        sheets[data.get("sheet", name[:-5])] = data
    return sheets


def is_unfilled(value):
    if isinstance(value, str):
        return value.strip() in ("TODO", "", "?") or value.strip().startswith("TODO")
    return value is None


def refs_in(value):
    """Yield ref keys from a ref cell (string or list of strings)."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for v in value:
            if isinstance(v, str):
                yield v


def check_sheets():
    sheets = load_sheets()
    findings = []
    if not sheets:
        return ["no sheets found in sheets/"]
    keys = {}
    for sname, sheet in sheets.items():
        key = sheet.get("key", "id")
        ids = [r.get(key) for r in sheet.get("rows", [])]
        dup = {i for i in ids if ids.count(i) > 1}
        for d in sorted(map(str, dup)):
            findings.append(f"{sname}: duplicate key {d!r}")
        keys[sname] = set(ids)

    total = verified = 0
    for sname, sheet in sheets.items():
        cols = sheet.get("columns", {})
        key = sheet.get("key", "id")
        for row in sheet.get("rows", []):
            rid = row.get(key, "<no key>")
            ver = row.get("_verified", [])
            all_ok = ver == "*"
            for col, spec in cols.items():
                total += 1
                where = f"{sname}[{rid}].{col}"
                if col not in row:
                    findings.append(f"{where}: missing column")
                    continue
                val = row[col]
                if is_unfilled(val):
                    owners = row.get("_owner") if isinstance(row.get("_owner"), dict) else {}
                    owner = owners.get(col) or spec.get("owner", "?")
                    findings.append(f"{where}: unfilled (owner {owner})")
                    continue
                src = spec.get("from")
                if src in ("cs2", "hzd") and not (isinstance(val, dict) and src in val) and not isinstance(val, (int, float)):
                    findings.append(f"{where}: expected a {src} binding object {{\"{src}\": ...}}")
                if spec.get("type") == "ref":
                    target = spec.get("ref")
                    if target not in keys:
                        findings.append(f"{where}: ref to unknown sheet {target!r}")
                    else:
                        for r in refs_in(val):
                            if r not in keys[target]:
                                findings.append(f"{where}: ref {r!r} not found in sheet {target!r}")
                if spec.get("type") == "enum" and "values" in spec:
                    vals = val if isinstance(val, list) else [val]
                    for v in vals:
                        if v not in spec["values"]:
                            findings.append(f"{where}: {v!r} not in enum {spec['values']}")
                if all_ok or (isinstance(ver, list) and col in ver):
                    verified += 1
                else:
                    findings.append(f"{where}: unverified")
            for extra in row:
                if not extra.startswith("_") and extra not in cols:
                    findings.append(f"{sname}[{rid}].{extra}: column not declared in sheet")
    print(f"sheets: {len(sheets)}  cells: {total}  verified: {verified}")
    return findings


# ---------------------------------------------------------------- package

# Magic numbers of game containers / converted formats that must never ship.
MAGICS = {
    b"\x50\x40\x30\x20": "Decima archive (HZD .bin)",
    b"\x50\x40\x30\x21": "Decima archive (encrypted)",
    b"\x34\x12\xaa\x55": "Valve VPK",
    b"glTF": "glTF binary (converted model)",
    b"DDS ": "DDS texture",
    b"RIFF": "RIFF (wav) audio",
    b"BKHD": "Wwise bank",
    b"OggS": "Ogg audio",
}
FORBIDDEN_EXT = {
    ".vpk", ".core", ".stream", ".bin", ".wem", ".bnk", ".glb", ".gltf", ".dds", ".r32",
    ".vmdl_c", ".vtex_c", ".vsnd_c", ".vmat_c", ".vdata_c", ".vpcf_c", ".mp3", ".wav", ".ogg",
}
FORBIDDEN_NAMES = {"oo2core_3_win64.dll", "items_game.txt", "hzd_types.json.gz", "hzd_paths.txt.gz"}
# Files we ship that legitimately match a rule above (own assets), relative paths, lowercase.
ALLOW = set()


def load_allow():
    p = os.path.join(SHEETS, "own_assets.json")
    if os.path.isfile(p):
        with open(p, encoding="utf-8") as f:
            for row in json.load(f).get("rows", []):
                ALLOW.add(row["path"].replace("\\", "/").lower())


def iter_package(target):
    if os.path.isdir(target):
        for base, _, files in os.walk(target):
            for fn in files:
                full = os.path.join(base, fn)
                rel = os.path.relpath(full, target).replace("\\", "/")
                with open(full, "rb") as f:
                    head = f.read(8)
                yield rel, os.path.getsize(full), head, full
    elif zipfile.is_zipfile(target):
        with zipfile.ZipFile(target) as z:
            for info in z.infolist():
                if info.is_dir():
                    continue
                with z.open(info) as f:
                    head = f.read(8)
                yield info.filename, info.file_size, head, None
    else:
        raise SystemExit(f"not a folder or zip: {target}")


def check_project(game_dir, findings):
    """The Godot export only contains files from the project folder: nothing game-derived may be there."""
    if not os.path.isdir(game_dir):
        return 0
    n = 0
    for base, dirs, files in os.walk(game_dir):
        dirs[:] = [d for d in dirs if d not in (".godot", "export")]
        for fn in files:
            n += 1
            full = os.path.join(base, fn)
            rel = "game/" + os.path.relpath(full, game_dir).replace("\\", "/")
            low = rel.lower()
            if low in ALLOW:
                continue
            ext = os.path.splitext(low)[1]
            if ext in FORBIDDEN_EXT or os.path.basename(low) in FORBIDDEN_NAMES:
                findings.append(f"{rel}: forbidden in the Godot project (would be exported)")
            with open(full, "rb") as f:
                head = f.read(8)
            for magic, what in MAGICS.items():
                if head.startswith(magic):
                    findings.append(f"{rel}: looks like {what} (would be exported)")
    return n


def cache_hashes(cache_dirs):
    import hashlib
    hashes = {}
    for cd in cache_dirs:
        for base, _, files in os.walk(cd):
            for fn in files:
                p = os.path.join(base, fn)
                if os.path.getsize(p) < 256:
                    continue
                with open(p, "rb") as f:
                    hashes[hashlib.sha256(f.read()).hexdigest()] = p
    return hashes


def check_package(target, cache_dirs):
    import hashlib
    load_allow()
    findings = []
    known = cache_hashes(cache_dirs) if cache_dirs else {}
    count = 0
    for rel, size, head, full in iter_package(target):
        count += 1
        low = rel.lower()
        name = os.path.basename(low)
        ext = os.path.splitext(low)[1]
        if low in ALLOW:
            continue
        if name in FORBIDDEN_NAMES:
            findings.append(f"{rel}: forbidden file name")
        if ext in FORBIDDEN_EXT:
            findings.append(f"{rel}: forbidden extension {ext}")
        for magic, what in MAGICS.items():
            if head.startswith(magic):
                findings.append(f"{rel}: looks like {what}")
        if "cache" in low.split("/"):
            findings.append(f"{rel}: inside a cache folder")
        if full and known:
            with open(full, "rb") as f:
                h = hashlib.sha256(f.read()).hexdigest()
            if h in known:
                findings.append(f"{rel}: identical to converted cache file {known[h]}")
    nproj = check_project(os.path.join(ROOT, "game"), findings)
    print(f"package: {count} files scanned, {len(known)} cache files compared, {nproj} project files checked")
    return findings


def main(argv):
    if len(argv) < 2 or argv[1] not in ("sheets", "package"):
        print(__doc__)
        return 2
    if argv[1] == "sheets":
        findings = check_sheets()
    else:
        if len(argv) < 3:
            print("usage: preflight.py package <dir|zip> [--cache <dir> ...]")
            return 2
        caches = [argv[i + 1] for i, a in enumerate(argv) if a == "--cache" and i + 1 < len(argv)]
        findings = check_package(argv[2], caches)
    for f in findings:
        print("  -", f)
    print("CLEAN" if not findings else f"{len(findings)} finding(s)")
    return 0 if not findings else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
