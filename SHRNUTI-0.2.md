# Shrnutí před publikováním – Horizon Strike 0.2.0

**Stav: KONEČNÉ (11:50).** Release 0.2.0 je nahraný na Melty jako KONCEPT. Nic není publikované – čeká na tvoje „ano“.
Build je ze značky `v0.2.0-rc` (commit 140134b) / větev `release/0.2` a neobsahuje nic z 0.3 (ověřeno: žádné nože,
XP, menu K, efekty ani grafická nastavení v exportu).

## Co se změnilo proti 0.1.1
- **Tři nové stroje:** Sawtooth, Scrapper, Broadhead – skutečné modely, kostry a textury z HZD, životy z HZD
  (1100 / 220 / 175), slabá místa z HZD (kanystr / power cell + radar / 2 kanystry), chování podle HZD
  (Sawtooth plížení + nájezd, Scrapper radar + smečka + laser, Broadhead brání stádo nájezdem); odměny
  CS2 kill award × 4,5 / 2,5 / 2,0. Obsadily svá původní místa (Broadhead 23 míst / 86 strojů, Scrapper 2 / 7,
  Sawtooth 1 / 1).
- **Animace všech 6 strojů** procedurálně na skutečných kostrách: chůze a běh podle druhu, nohy na terénu
  (skluz 14–30 cm → 0–1,4 cm), náklon těla, otáčení na místě, pasení, útoky s nápřahem, reakce na zásah, pád při
  smrti. Stroje vždy nejdřív zpozorní (suspicious) a pak spustí poplach.
- **Vzhled mapy:** textury předkomprimované v konvertoru (BC1/BC5/BC7), normálové a ORM mapy (terén, skály a budovy
  100 % kromě materiálů, které normálu nemají ani v HZD), terén z vrstev HZD (sníh/tráva/hlína/skála) podle masek,
  obloha/slunce/mlha z denního cyklu Mother's Heart v 9:00, neutrálnější stíny, matný sníh, horizont bez šedého pruhu.
- **Plynulost:** buňky se vkládají po dávkách (6 ms/snímek), kolize jen v okolí hráče a po krocích, shadery
  předkompilované na načítací obrazovce, occlusion culling, vzdálené buňky jako HLOD, konvertor během hry s nízkou
  prioritou (CPU 28 % → 10 %), bezpečný úklid cache. Nejhorší snímek při načtení buňky 1435 ms → 35–38 ms.
- **Stabilita:** opraven pád při ukončení/teardownu (0 pádů ve 105 bězích), zátěžový běh 20× přes 30 buněk bez pádu
  a bez chyb.

## Co se nepovedlo
- Vrstvy terénu jsou globální sady z oblasti startu rozmístěné podle masek – skutečné míchání terénu dělá HZD
  v kompilovaných shaderech, které nejdou přečíst.
- Animace strojů z HZD nečteme (Morpheme) – pohyby jsou vlastní procedurální.
- Vodu (31 ploch v buňce 4,-3) se nepodařilo vyfotit, proto ji listing netvrdí.
- Zdi a podlahy Cauldronu zůstávají šedé (barvu počítá HZD až shader).
- Sawtoothův kanystr pod hrudí jde zasáhnout jako první věc jen z 4–5 směrů z 8 (věrně podle HZD; viz OTAZKY.md).
- t15 (výkon): 1 % low na trase kolísá kolem limitu 45 fps – na klidném stroji 49,0 / 44,4 / 47,1 (2 ze 3 běhů
  prošly); všechny snímky při načítání pod 50 ms.
- První spuštění (t09) trvalo v závěrečné sadě 554 s místo 85,5 s – běželo souběžně s prací ostatních agentů a cache
  byla na pomalejším disku; kód bootstrapu se proti 0.2.0 nezměnil.

## Autotest (release 0.2.0-final spuštěný jako z Melty + --autotest)
| # | test | výsledek | klíčová čísla |
|---|---|---|---|
| t01–t11, s01–s03 | 14 testů z 0.1 (t03 nákup skutečným vstupem) | 14 × PASS | 0 chyb enginu |
| t12 | Sawtooth/Scrapper/Broadhead stavový cyklus | PASS | suspicious → alert/stalk → attack |
| t13 | slabé místo > tělo u 6 strojů, výstřel přes vstup | PASS | zasažitelné z 8 směrů: Watcher 7, Strider 8, Grazer 8, Sawtooth 5, Scrapper 7, Broadhead 7 |
| t14 | normálové mapy | PASS | budovy 39 315/39 326, skály 21 452/21 452, terén 15/15 |
| t15 | výkon start + trasa 10 buněk | FAIL v sadě (souběh s přesunem dat) / opakování na klidném stroji 2 ze 3 PASS | viz tabulka níže |
| t16 | zátěž 20× přes 30 buněk | PASS | 20/20 exit 0, 0 chyb, RSS 2,73–2,93 GB, VRAM 2,11 GB |

## Výkon 0.1 proti 0.2 (release, 1920×1080, bez vsync, klidný stroj)
| build / běh | start avg / 1 % low | trasa avg / 1 % low | nejdelší snímek při načítání | VRAM na startu |
|---|---|---|---|---|
| 0.1.1 | 78,4 / 70,3 fps | 78,7 / 46,3 fps | 1435 ms | 1230 MiB |
| 0.2.0 opakování 1 | 77,1 / 70,6 fps | 85,3 / 49,0 fps | 37,9 ms | 1491 MiB |
| 0.2.0 opakování 2 | 77,1 / 70,5 fps | 83,9 / 44,4 fps | 35,1 ms | 1491 MiB |
| 0.2.0 opakování 3 | 77,7 / 70,8 fps | 85,0 / 47,1 fps | 35,2 ms | 1492 MiB |

## Záznamy (skutečné soubory)
- Screenshoty před/po: `C:\meshy\_toolsecords-0.2inalefore\{mothers_heart,valley,rocks_close}.png`,
  `C:\meshy\_toolsecords-0.2inalfter\{mothers_heart,valley,rocks_close}.png`
- Videa: `C:\meshy\_toolsecords-0.2inalideo\` – `<stroj>_{walk,attack,death}.mp4` pro watcher, strider,
  grazer, sawtooth, scrapper, broadhead (18 klipů) a `cell_crossing.mp4` (25,3 s)
- Graf času snímků: `C:\meshy\_toolsecords-0.2inalrametime_0.1_vs_0.2.svg`
- Výsledky: `C:\meshy\_toolsecords-0.2inalesults.json`, `results-t15-rerun-{1,2,3}.json`

## Nový text listingu
Text a nové screenshoty se na Melty změní až při publikování (úprava textu i screenshotů se na živém listingu
projeví okamžitě, proto je teď nenahrávám). Screenshoty k přidání: 3× `after\*.png`.

**Title:** Horizon Strike
**Tagline:** Hunt Horizon Zero Dawn's machines across its real world with Counter-Strike 2 guns, kill money and the buy wheel.

Walk out of Mother's Heart into **Horizon Zero Dawn's own world** and hunt its machines with **Counter-Strike 2's arsenal**.

**What's in it**
- **Horizon's world, read from your copy of Horizon Zero Dawn Complete Edition:** the real terrain of all 340 main-world tiles with Horizon's own snow, grass, dirt and rock layers and normal maps, Horizon's sky, sun and fog at a fixed morning hour, rocks, ruins, Nora huts and campfires on their original places, trees and undergrowth placed from the game's own density and snow maps, Horizon's music.
- **Six of Horizon's machines:** Watcher, Strider, Grazer, **Sawtooth, Scrapper and Broadhead**, with their real models, skeletons and textures, at their real sites. Each walks, runs, turns, grazes, attacks, flinches and falls with its own procedural animation on its real skeleton. Watchers patrol and go suspicious → alert → attack; Sawtooths stalk and charge; Scrappers ping their radar, call the pack and fire laser bursts; Broadheads charge to defend their herd; Striders and Grazers flee. Hit the weak spots (Watcher eye, blaze canisters, Scrapper power cell and radar) for headshot damage.
- **Counter-Strike 2's guns, read from your CS2 install:** real first-person models with CS2's own viewmodel animations, sounds, damage, fire rate, recoil, clip sizes and prices: knife, Glock, P250, Desert Eagle, MP9, UMP-45, Galil AR, AK-47, M4A1-S, AWP, Nova, HE grenade, Molotov and Kevlar.
- **CS economy:** start with knife, Glock and $800; every machine kill pays the CS2 kill award of your weapon class × the machine's bounty (max $16,000). Press **B** for the buy wheel (not in combat).
- **Death:** you respawn at the last campfire you visited with knife and Glock; other weapons are lost, money stays.

**Smooth streaming:** new areas load in small steps in the background (textures pre-compressed, shaders compiled on the loading screen, occlusion culling and far-distance proxies), and the converter slows itself down while you play.

**First start:** the mashup converts your own game files into a local cache (about 1.5 minutes until you can play, ~0.8 GB). The rest of the world converts in the background as you approach it; the cache limit (default 4 GB) can be changed in the Esc menu. Nothing from either game is included in the download.

**Needs:** Counter-Strike 2 and Horizon Zero Dawn Complete Edition (Steam, original 2020 PC version) installed. If Horizon isn't found, the game tells you on screen. Counter-Strike 2 is never started or modified – only its files are read.

**Controls:** WASD move, Shift walk, Ctrl crouch, Space jump, mouse aim/fire, R reload, 1-4 weapons, B buy wheel (click an item, or hold B and release over it), F inspect, Esc menu.

**Version 0.2 limits:** solo only; machine motion is our own procedural animation on their real skeletons (Horizon's animation format can't be read); no people, quests, loot or day/night cycle; no Frozen Wilds area.

Made by EM. Code MIT. Built with Godot 4.7.2, ValveResourceFormat, LibAtrac9 and other open-source libraries (see THIRD_PARTY_NOTICES.txt). Built with the help of AI (Claude).

## ID release
`024c27ab-d661-45b7-9226-0ec9dbcb68e8` (verze 0.2.0, koncept, publishable, one click: yes)
Upload `e6a95a38-4dc5-49d6-933a-de84e21bd95d`, `HorizonStrike-0.2.0.zip` (82 784 865 B, sha256 abfec3ed…cac8d1).

## Příkazy na push (nespouštěno)
```
git -C C:/meshy push origin main
git -C C:/meshy push origin release/0.2
git -C C:/meshy push origin v0.2.0-rc
```
