# Horizon Strike – rules for every agent in this repo

Read `BRIEF.md` (design, Czech), `docs/ARCHITECTURE.md` (contracts) and the relevant `sheets/*.json` before working.
The orchestrator owns `BRIEF.md`, `CLAUDE.md`, `MODLOG.md`, `docs/ARCHITECTURE.md`, `tools/preflight.py`, merging and
everything on Melty. Report decisions you make in your final report so the orchestrator can log them.

## Hard rules
- **Game installs are read-only.** Never launch, modify, write into, or create files inside the CS2 install
  (`C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive`) or the HZD install
  (`E:\SteamLibrary\steamapps\common\Horizon Zero Dawn`). Open their files read-only. Never copy `oo2core_3_win64.dll`
  anywhere: load it in place with `NativeLibrary.Load(<hzd>/oo2core_3_win64.dll)`.
- **Nothing from either game enters the repo or the package**: no models, textures, sounds, extracted text, path
  lists, RTTI/type dumps, items_game excerpts. Converted output goes only to a cache dir (default
  `%LOCALAPPDATA%\HorizonStrike\cache`; dev caches under `C:\meshy\_tools\cache-*`).
- **Licensing:** the project is MIT. Do not copy code from GPL or unlicensed projects (Decima Workshop, odradek,
  HZDCoreEditor, HZDMeshTool, ProjectDecima_python). Read them as format references only and write your own code.
  Do not ship their data files (e.g. `hzd_types.json.gz`, `hzd_paths.txt.gz`); type layouts you need are hand-written
  from the format facts. MIT/BSD/CC0/Apache deps are fine (ValveResourceFormat is MIT); list every bundled dep in
  `THIRD_PARTY_NOTICES.txt`.
- **No junctions or symlinks inside any git worktree or working tree.** Reference tools, caches and reference clones
  by absolute path (`C:\meshy\_tools\...`). Never `git worktree remove` anything yourself.
- **Git:** commit only on your own branch, stage explicitly by path (never `git add -A`), never push, never rewrite
  history. The orchestrator merges.
- Kill processes only by exact PID. Never block the Godot main thread on the converter.
- Sheets are the source of truth: change the sheet first, then regenerate (`python tools/gen_sheets.py`), then code.
  Never hand-edit `game/generated/` or `converter/src/Hzs.Generated/`.

## Tools on this PC
- .NET SDK 8.0.425 and 10.0.401 (`dotnet`), Python 3.12 (`python`), Node, CMake, git, ffmpeg, Java 21.
- Godot 4.7.2 editor: `C:\Users\bezdo\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe`
  (headless: `--headless --path game ...`). Export templates 4.7.2 (Windows x64) are installed.
- ValveResourceFormat CLI 20.0: `C:\meshy\_tools\vrf\Source2Viewer-CLI.exe` (dev only; the shipped converter uses the
  ValveResourceFormat NuGet library).
- Reference clones (read-only, format facts only): `C:\meshy\_tools\research\*`.
- universal-modder toolkit: `C:\meshy\_tools\universal-modder` (`bin/um`, needs `uv` from
  `C:\Users\bezdo\AppData\Roaming\Python\Python312\Scripts`).

## Verification
Done means demonstrated: run it and quote the actual output (converter exit + files written + sizes, Godot headless
run log, screenshot path). Keep heavy logs in files and grep them.
