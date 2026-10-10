# HANDOVER – Horizon Strike (stav 2026-10-10 ~12:40)

Mashup CS2 × Horizon Zero Dawn Complete Edition na Melty. Godot 4.7.2 hra (`game/`) + .NET 10 konvertor
`hzsconv` (`converter/`), obsah se převádí z hráčových instalací do lokální cache. Nový chat: přečti nejdřív
`CLAUDE.md` (pravidla, zakázané příkazy, release větve), pak tento soubor, pak konec `MODLOG.md` a `NOC.md`.

## Verze na Melty
- Listing „horizon-strike“, modId `6e2ecdda-6217-40c2-b016-e6940db6aee4`,
  Studio https://melty.gg/studio/6e2ecdda-6217-40c2-b016-e6940db6aee4, stránka https://melty.gg/m/horizon-strike.
- **0.1.1 – ŽIVÁ** (release `544104e6-b3f9-404e-ade4-4aadf27346e8`; 7 stažení, 4 hráči). 0.1.0 = `a59fbb25…`.
- **0.2.0 – uživatel řekl „ano“, publish odeslán, Melty ji DRŽÍ v ruční bezpečnostní kontrole** („Melty's team will
  take a look“). Release `024c27ab-d661-45b7-9226-0ec9dbcb68e8`, upload `e6a95a38…`, zip sha256 `abfec3ed…cac8d1`.
  Text listingu 0.2 a 3 nové screenshoty (v020_*) jsou už na živém listingu (nahrány před publish) – dokud 0.2.0
  neprojde kontrolou, popisují verzi, kterou hráči ještě nemají. Další krok: `mod_status`, po schválení ověřit
  stránku (verze 0.2.0, text, screenshoty). Shrnutí: `SHRNUTI-0.2.md`.
- **0.3 – rozpracovaná v main, nic nenahráno.** Zadání `docs/BRIEF-0.3.md`, plán `docs/PLAN-0.3.md`.
- Melty volání: HTTP JSON-RPC na https://melty.gg/api/mcp s tokenem uživatele (token není v repu; v tomto chatu byl
  ve scratchpadu `…/scratchpad/melty/.tok` – nový chat potřebuje od uživatele nový Publish prompt / token).

## Git
- `main` – vše sloučené kromě větve vykon (níže). **Nepushnuto: ~275 commitů** (origin = github.com/jakub2929/HorizonStrike,
  na GitHubu je stav 45638b3).
- Tag `v0.2.0-rc` = 140134b (z něj postavený release 0.2.0); větev `release/0.2` z tohoto tagu (žádné opravy nebyly potřeba).
- `release-0.2` (779dbe1) – stará pomocná větev se stejným kódem, nepoužívá se (smazat ručně, `branch -D` je zakázané).
- `orch` – worktree orchestrátora (`.claude/worktrees/orch`), sloučeno.
- `worktree-agent-*` – větve teammates, všechny sloučené, **kromě `worktree-agent-aa2a9caade51a2b86` (vykon, 6 commitů,
  dfb42e8): grafická nastavení**; merge má konflikty v `game/main/main.gd`, `game/ui/settings_menu.gd` a vygenerovaných
  `systems.*` – hooky jsou vždy 1 řádek, seznam v posledním reportu vykon (komentář `# GRAPHICS HOOK (vykon)`):
  main.gd `apply_render_settings` → `GraphicsSettings.attach_environment(_env, _sun)`; settings_menu.gd tlačítko Graphics;
  cell_builder.gd `track_chunk` a `far_albedo`; mesh_library.gd `world_texture`; project.godot autoload. Po merge
  znovu `python tools/gen_sheets.py`.
- Push (spouští uživatel):
  ```
  git -C C:/meshy push origin main
  git -C C:/meshy push origin release/0.2
  git -C C:/meshy push origin v0.2.0-rc
  ```

## 0.3 – hotové a sloučené v main
- Nože: 22/22 z items_game (finishe nejdou – vcompmat), Esc → Knife s 3D náhledem, `loadout.json`, inspect F,
  převod na vyžádání, dedup.
- XP/levely/body/vylepšení (K + Esc, `progression.json`), HUD, silent strike (nová mechanika ×5), bhop levely,
  efekty: hitmarker, čísla, indikátor směru, viněta, aimpunch, zvuky CS2; jiskry/úlomky na strojích (pool 32).
- Optimalizace: uvolňování meshů/textur s poslední buňkou, I/O mimo hlavní vlákno, konvertor v nečinnosti 118 MB,
  špička konvertoru 1,22 GB hra / 2,08 GB bootstrap, bootstrap převádí jen nůž + Glock (ostatní zbraně na pozadí,
  buy wheel „Preparing…“), paralelní bootstrap CS2/HZD, větší rozpočet vkládání na loading screenu, `--gfx-low`.

## 0.3 – co zbývá
1. Sloučit větev vykon (grafická nastavení, presety, auto preset) a dodělat cíle: Low GPU ≤ 5 ms, RAM ≤ 2,5 GB,
   VRAM ≤ 1,5 GB; High RAM ≤ 3,5 GB; změřit na release (nic z toho zatím neměřeno po úpravách).
2. Návrhy vykon k ověření: plné buňky uvolňovat za ringem 2 (dnes `streaming.unload_ring` 3), albedo vzdálených buněk.
3. **Autotesty 0.3 nejsou napsané:** t17–t24 (sheet `autotest.json` je připravený) + nové body 9–11 (Low/High měření,
   přepnutí presetu vstupem + restart, limit fps 60) – vše skutečným vstupem; perf testy musí nastavit max_fps = 0.
4. Záznamy 0.3 (screenshot menu nožů a vylepšení, inspect videa Karambit/M9/Butterfly, video boje, bhop 0 vs 5,
   screenshoty Low/Medium/High), tabulka 0.2 vs 0.3 do `SHRNUTI-0.3.md`.
5. Znovu změřit první spuštění (cíl ≤ 40 s): poslední měření 39,8 s bylo PŘED paralelním bootstrapem a loading budgetem.
6. Neověřené buňky sheetu (3): `movement.bhop_clip_speed_mult`, `combat.silent_strike_mult`, `fx.aimpunch` – preflight
   musí být CLEAN před buildem.
7. Pak: build → celý autotest (t16 jen 5×, protože se měnilo načítání) → záznamy → balíček → Melty release 0.3.0
   (koncept) → `SHRNUTI-0.3.md` → „ano“ → publish. Text listingu: nože formulovat „vyber si model nože z CS2 ve své instalaci“.

## Neprošlo testem / neověřeno v 0.3
Op `weapons` s reálným konvertorem v běžící hře; loading budget 60 ms; RSS Low; volby kvality textur a far albedo;
zbylé čtení souborů na hlavním vlákně (model nože při přepnutí v menu, model granátu při prvním hodu, meta.json
nepřevedených zbraní/nožů).

## Rozhodnutí, která čekají na uživatele (OTAZKY.md)
Sawtooth 1100 HP ponecháno podle HZD; Broadhead na 23 místech; Sawtoothův kanystr zasažitelný jen z ~5/8 směrů
(ponecháno věrně, alternativní „zástupný hitbox“ připraven); co s `E:\meshy_offload` (181 GB testovacích cache).

## Známé problémy
- Zdi a podlahy Cauldronu šedé (barvu počítá až shader HZD).
- Sawtooth: slabé místo zasažitelné jako první věc z 4–5/8 směrů.
- 1 % low na trase na hraně limitu 45 (0.2.0: 49,0 / 44,4 / 47,1).
- `E:\meshy_offload\_tools` – 181 GB přesunutých testovacích dat (nic nesmazáno); `E:\meshy_work` – pracovní cache.
- Stará větev `release-0.2`.
- Na C: jsou v `%LOCALAPPDATA%\HorizonStrike\` staré cache `cache-prev-*` a `cache-mock` z měření.

## Kde co je
- Pravidla: `CLAUDE.md` (zakázané příkazy, testy přes vstup hráče, obsahový kontrakt, release větve, t16 5×).
- Deník rozhodnutí D1–D62 a průběh: `MODLOG.md`; noční log: `NOC.md`; otázky: `OTAZKY.md`.
- Shrnutí: `SHRNUTI-0.2.md` (konečné), `SHRNUTI-0.3.md` zatím není.
- Zadání a plány: `BRIEF.md`, `docs/BRIEF-0.2.md`, `docs/BRIEF-0.3.md`, `docs/PLAN*.md`, `docs/ARCHITECTURE.md`,
  `docs/listing.md` (text 0.2), `docs/notes/<agent>.md` (deníky teammates).
- Sheety: `sheets/*.json` → `python tools/gen_sheets.py`; kontrola `python tools/preflight.py sheets|package <dir>`.
- Build: `powershell -ExecutionPolicy Bypass -File tools/build.ps1 -Dist <dir>`; recept `melty.json` / `docs/melty-recipe.json`.
- Konvertor: `converter/src/Hzs.{Cli,Common,Cs2,Decima,Generated}`; hra: `game/`; autotest: `game/autotest/`
  (`--autotest [ids] --out <dir>`).
- Release buildy: `C:\meshy\_tools\release\{0.1.1,0.2.0-final}`, zipy tamtéž; záznamy 0.2:
  `C:\meshy\_tools\records-0.2\final\`; testovací výstupy a cache jen na `E:\meshy_work\`.

## Výchozí čísla pro srovnání (release, 1920×1080, bez vsync, klidný stroj)
| | 0.1.1 | 0.2.0 | 0.3 (main, dílčí) |
|---|---|---|---|
| start avg / 1 % low | 78,4 / 70,3 fps | 77,1–77,7 / 70,5–70,8 fps | – |
| trasa 10 buněk avg / 1 % low | 78,7 / 46,3 fps | 83,9–85,3 / 44,4–49,0 fps | – |
| nejhorší snímek při načítání buňky | 1435 ms | 35–40 ms | – |
| VRAM na startu / max na trase | 1230 MiB / – | 1491 / 2126 MiB | 1584 MiB (High, orientačně) |
| RAM hry | – | working set max 2,7 GB, private 5,2 GB, RSS t16 2,73–2,93 GB | RSS max 2,40 GB (High, orientačně) |
| konvertor RAM nečinný / špička | – | ~4,3 GB / 4–6 GB | 118 MB / 1,22 GB hra, 2,08 GB bootstrap |
| první spuštění do hratelnosti | – | 81,9 s | 39,8 s (před paralelním bootstrapem) |
| GPU / CPU render na trase (High) | – | 10,95 / 3,0 ms | – |
