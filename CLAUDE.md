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
  `%LOCALAPPDATA%\HorizonStrike\cache`; dev caches under `C:\meshy\_tools\cache-*`). Allowed in sheets: asset
  paths, binding key paths and single numbers as `_evidence` (MODLOG D26).
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

## Unattended runs: forbidden commands (they prompt and hang, or fail)
- git rebase, git branch -D, git stash (any), git checkout -- …, git restore … → make a new branch from main or a
  new commit instead. git push (any form) → never. git reset --hard, git clean, anything with GIT_CONFIG_*,
  hooksPath or CLAUDECODE.
- rm, Remove-Item, del, rd → move to `C:\meshy\_to_delete\` instead. Tests that need a clean cache use a NEW cache
  folder per run; never delete old ones.
- docker system prune, claude -p, claude --bg; anything that can wait for input (UAC/admin installers, interactive
  prompts, the Godot editor GUI with dialogs). If a tool needs an admin install, report it and build without it.
- Long commands (build, export, autotest, conversion) always with a time limit; after it, kill only processes you
  started (exact PID). Same step failing 3× → stop, report one sentence, build the nearest working version.
- Commit all changes before reporting a task done. Never commit to main directly; the orchestrator merges.

## Content is data, not code (content contract)
- The game never hard-codes a file, bone, mesh or path from HZD or CS2. It only knows **roles and named points**
  defined per row in the sheets and in the converter's per-asset `meta.json`.
- Every machine and weapon row carries a content contract: `content_model` (cache-relative model file),
  `bone_roles` (role -> bone name, e.g. head, spine, tail, leg_fl_upper/lower/foot ..., for weapons hand_r, hand_l),
  `points` (named points -> bone + local offset: weak spots, muzzle, eject, fx, hit/impact points). The same for
  world cells: `cell.json` is the contract (terrain file, instances, campfires, spawns, vegetation).
- Goal: all content can later be replaced by own models and terrain only by swapping files and sheets. Code that
  names a game-specific bone or file is a bug.

## Tools on this PC
- .NET SDK 8.0.425 and 10.0.401 (`dotnet`), Python 3.12 (`python`), Node, CMake, git, ffmpeg, Java 21.
- Godot 4.7.2 editor: `C:\Users\bezdo\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe`
  (headless: `--headless --path game ...`). Export templates 4.7.2 (Windows x64) are installed.
- ValveResourceFormat CLI 20.0: `C:\meshy\_tools\vrf\Source2Viewer-CLI.exe` (dev only; the shipped converter uses the
  ValveResourceFormat NuGet library).
- Reference clones (read-only, format facts only): `C:\meshy\_tools\research\*`.
- universal-modder toolkit: `C:\meshy\_tools\universal-modder` (`bin/um`, needs `uv` from
  `C:\Users\bezdo\AppData\Roaming\Python\Python312\Scripts`).

## Tests drive the player's input
- Every autotest exercises the behaviour under test through the player's input path (Input.parse_input_event: keys,
  mouse motion, buttons; helper game/autotest/lib/inputsim.gd). The Game API is only for setup (teleport, spawn,
  money, AI on/off) and for reading state. A test that calls a gameplay function instead of sending input is a bug.
- Weak spots are tested with a real shot through input, after checking that the first thing along the shot is the
  weak spot; report from how many of 8 directions it can be hit.

## Release branches and stress runs
- Each released version has a tag (vX.Y.Z-rc for the candidate) and a branch release/X.Y made FROM THAT TAG. Fixes for
  a release go on release/X.Y (a fix branch from release/X.Y), then are merged into main too. A release is built from
  its release branch only and must not contain later features.
- The streaming stress run (t16) runs 5x, and only when the loading or quit code changed.

## Verification
Done means demonstrated: run it and quote the actual output (converter exit + files written + sizes, Godot headless
run log, screenshot path). Keep heavy logs in files and grep them.
