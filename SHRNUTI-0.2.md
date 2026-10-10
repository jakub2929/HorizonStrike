# Shrnutí před publikováním – Horizon Strike 0.2.0

> **Stav: PRŮBĚŽNÉ (06:20).** Release 0.2.0 je postavený a otestovaný (17/19), běží poslední opravové kolo
> (úklid cache F10, jeden snímek 51,7 ms, vzhled stínů/horizontu/sněhu, slabé místo Sawtootha). Tento soubor
> se po něm aktualizuje; konečná verze nahradí tuto poznámku. NIC NENÍ PUBLIKOVÁNO.

## Co se změnilo proti 0.1.1
- **Tři nové stroje:** Sawtooth, Scrapper, Broadhead – skutečné modely, kostry a textury z HZD, životy z HZD
  (1100 / 220 / 175), slabá místa z HZD (kanystr / power cell + radar / 2 kanystry), chování podle HZD
  (Sawtooth plížení + nájezd, Scrapper radar + smečka + laser, Broadhead brání stádo nájezdem), odměny
  CS2 kill award × 4,5 / 2,5 / 2,0. Obsadily svá původní místa (Broadhead 23 míst / 86 strojů, Scrapper 2 / 7,
  Sawtooth 1 / 1).
- **Animace všech 6 strojů** procedurálně na skutečných kostrách: chůze a běh podle druhu, IK nohou na terénu
  (skluz nohou 14–30 cm → 0–1,4 cm), náklon těla, otáčení na místě, pasení, útoky s nápřahem, reakce na zásah,
  pád při smrti. Stroje vždy nejdřív zpozorní (suspicious), pak poplach.
- **Vzhled mapy:** textury předkomprimované v konvertoru (BC1/BC5/BC7, DDS), normálové a ORM mapy (terén,
  skály 100 %, budovy 99,5 %, vegetace 100 %), terén z vrstev HZD (sníh/tráva/hlína/skála) podle masek,
  obloha/slunce/mlha z denního cyklu Mother's Heart v 9:00, voda z vrstev HZD, vítr a déšť (ATRAC9 přes
  LibAtrac9, MIT).
- **Plynulost:** buňky se vkládají po dávkách s rozpočtem 6 ms/snímek, kolize jen v okolí hráče, shadery se
  předkompilují na načítací obrazovce, occlusion culling, vzdálené buňky jako HLOD, konvertor během hry
  s nízkou prioritou (CPU 28 % → 10 %). Nejhorší snímek při načtení buňky 1435 ms → 51,7 ms.
- **Stabilita:** opraven pád při ukončení/teardownu (a pravděpodobně i vzácný pád při startu): 0 pádů
  ve 105 bězích, zátěžový běh 20× přes 30 buněk bez pádu.

## Co se nepovedlo
- Tvar terénu z HZD shaderů nejde přečíst – vrstvy terénu jsou globální sady z oblasti startu, rozmístěné podle masek.
- Animace z HZD nečteme (formát Morpheme) – pohyby jsou vlastní procedurální.
- Vodu se nepodařilo vyfotit ve screenshotu (ve hře vzniká, 31 ploch v buňce 4,-3), proto ji listing netvrdí.
- Zdi a podlahy Cauldronu zůstávají šedé (barvu počítá HZD až shader).
- [doplní se po opravném kole]

## Autotest (release 0.2.0 spuštěný jako z Melty + --autotest, klidný stroj) – průběžný
| # | test | výsledek | klíčová čísla |
|---|---|---|---|
| t01–t11, s01–s03 | 14 testů z 0.1 (t03 nákup přes vstup hráče) | 14 × PASS | bootstrap 85,5 s, 416 MiB při world_ready |
| t12 | Sawtooth/Scrapper/Broadhead stavový cyklus | PASS | suspicious → alert/stalk → attack |
| t13 | slabé místo > tělo u 6 strojů, výstřel přes vstup | PASS | zasažitelné z 8 směrů: Watcher 7, Strider 8, Grazer 8, Sawtooth 4, Scrapper 7, Broadhead 7 |
| t14 | normálové mapy | PASS | terén 16/16, skály 100 %, budovy 100 % (bez 19 bez normály v HZD) |
| t15 | výkon | FAIL | start 80,8 / 74,4; trasa 92,5 / 52,5; nejhorší snímek při načítání 51,7 ms (limit 50); VRAM 1532 MiB |
| t16 | zátěž 20× přes 30 buněk | FAIL | 20/20 bez pádu, ale běh 1 zapsal 5 chyb (úklid cache smazal potřebnou buňku) |

## Výkon 0.1 proti 0.2 (release, 1920×1080, bez vsync, klidný stroj)
| build | start avg / 1 % low | trasa avg / 1 % low | nejdelší snímek při načítání | VRAM na startu |
|---|---|---|---|---|
| 0.1.1 | 78,4 / 70,3 fps | 78,7 / 46,3 fps | 1435 ms | 1230 MiB |
| 0.2.0 | 80,8 / 74,4 fps | 92,5 / 52,5 fps | 51,7 ms | 1532 MiB |

## Záznamy (skutečné soubory)
- Screenshoty před/po: `C:\meshy\_tools\records-0.2\final\before\{mothers_heart,valley,rocks_close}.png`,
  `C:\meshy\_tools\records-0.2\final\after\{mothers_heart,valley,rocks_close}.png`
- Videa: `C:\meshy\_tools\records-0.2\final\video\` – `<stroj>_{walk,attack,death}.mp4` pro watcher, strider,
  grazer, sawtooth, scrapper, broadhead (18 klipů, 7–8 s) a `cell_crossing.mp4` (25,3 s)
- Graf času snímků: `C:\meshy\_tools\records-0.2\final\frametime_0.1_vs_0.2.svg`

## Nový text listingu
`docs/listing.md` (celý text se sem vloží v konečné verzi).

## ID release
Zatím nenahráno (čeká na opravné kolo). Balíček: `C:\meshy\_tools\release\HorizonStrike-0.2.0.zip`.

## Příkazy na push (nespouštěno)
```
git -C C:/meshy push origin main
```
