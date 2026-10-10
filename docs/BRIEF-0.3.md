# Zadání 0.3 – výběr nožů, XP a vylepšení, efekty zásahů (2026-10-10, rozšířeno)

Platí CLAUDE.md (zakázané příkazy, testovací cache na E:\meshy_work). Run uninterrupted; před publikováním shrnutí
a „ano“ uživatele. Ekonomika za peníze, buy wheel a ostatní zbraně se nemění. Všechna nová čísla patří do sheetů, nic natvrdo v kódu.

## Nože
- Seznam nožů z dat CS2 hráče (items_game), ne natvrdo (Karambit, M9 Bayonet, Butterfly a všechny ostatní). Nože,
  které v instalaci nejsou nebo nejdou převést, ve výběru nejsou a do MODLOG jednou větou.
- Každý nůž: model, vlastní animace v ruce (vytažení, útok, inspect na F) a zvuky z CS2; obsahový kontrakt jako
  ostatní zbraně.
- Poškození a rychlost útoku všech nožů = výchozí nůž (jako v CS2); silent strike funguje se všemi.
- Volný výběr v Esc menu, položka „Nůž“ s náhledem modelu; volba uložená lokálně, platí i po respawnu a restartu.
- Finishe: výchozí vzhled; pokus o převod finishů z dat CS2 max 3 kroky, jinak jedna věta.

## XP a vylepšení
- XP za každý zabitý stroj podle síly stroje (sheet strojů); malý bonus za zabití zásahem do slabého místa a za
  silent strike. XP oddělené od peněz (peníze = ekonomika CS beze změny).
- Levely podle křivky v sheetu; každý level = 1 bod vylepšení.
- Menu vylepšení (klávesa K + položka v Esc menu):
  - Poškození +10 %/level, max 5, všechny zbraně vč. nože.
  - Životy +20 max HP/level, max 5 (základ 100).
  - BHOP: level N = N skoků po sobě bez ztráty rychlosti, skok N+1 rychlost ořízne; level 0 = jako teď; max 5;
    air strafe podle CS2 zůstává.
- XP, levely a vylepšení přežijí smrt i restart (lokálně). HUD: level + lišta XP, oznámení level-upu.

## Efekty zásahů
- Dáš poškození: hitmarker (jiný pro slabé místo), číslo poškození u zásahu (vypínatelné v Esc menu), jiskry
  a úlomky na stroji v místě zásahu (výraznější u slabého místa), zvuk zásahu; stávající reakce stroje zůstává.
- Dostaneš poškození: směrový indikátor, červená viněta podle zbývajících životů, aimpunch jako v CS2, zvuk.
- Výkon: limity z 0.2 platí (≥ 60 fps průměr, 1% low ≥ 45, žádný snímek nad 50 ms).

## Optimalizace (hra musí jít i na slabších PC než RTX 3060 Ti)
- Nejdřív změřit na 0.2 a zapsat do MODLOG: RAM zvlášť hra a konvertor; rozpad paměti hry (textury, modely, data
  buněk, skripty); čas GPU a CPU na snímek. Opravovat od největší položky.
- Grafická nastavení v Esc menu, presety Low / Medium / High + ruční volby: limit fps (30/60/120/144/bez limitu,
  výchozí 60) a VSync; render scale s FSR (50–100 %); kvalita a vzdálenost stínů; dohled a hustota vegetace;
  LOD bias; SSAO, SSR, objemová mlha (zap/vyp). Ukládá se lokálně.
- První spuštění: preset automaticky podle GPU a její VRAM; hráč ho může kdykoli změnit.
- RAM: data buněk mimo dohled uvolnit z paměti (ne jen ze scény); textury a modely sdílet mezi buňkami;
  konvertor po dokončení převodu uvolní paměť nebo se ukončí a spustí znovu až při potřebě.
- Cíle (release, trasa přes 10 buněk): Low – GPU ≤ 5 ms/snímek při 1080p, RAM hry ≤ 2,5 GB, VRAM ≤ 1,5 GB;
  High – limity výkonu z 0.2, RAM hry ≤ 3,5 GB; konvertor v nečinnosti ≤ 300 MB RAM. Když cíl nejde: jedna věta
  proč a nejlepší dosažitelná hodnota.

## Autotest (+ celá dosavadní sada musí projít)
1. Každý nůž ze seznamu se načte a má všechny pojmenované body z kontraktu.
2. Výběr přes menu skutečným vstupem: zvolený nůž v ruce, po smrti a respawnu i po restartu hry pořád zvolený.
3. Poškození vybraného nože = výchozí; inspect (F) přehraje animaci u každého nože.
4. Zabití stroje přidá správné XP; level-up dá bod.
5. Vylepšení přes menu skutečným vstupem: poškození o správné %, max životy o správnou hodnotu; XP a vylepšení
   přežijí smrt i restart.
6. BHOP: s levelem N udrží rychlost N skoků po sobě, skok N+1 ořízne (level 0, 1, 5) – skoky simulovaným vstupem
   se správným časováním, ne nastavením rychlosti.
7. Efekty: zásah stroje spustí hitmarker a číslo; zásah hráče indikátor směru a vinětu (ověřit zobrazení).
8. Výkon s efekty při boji se 3 stroji: limity z 0.2.
9. Měření na trase pro Low i High: RAM hry, RAM konvertoru, VRAM, čas GPU a CPU na snímek, fps a 1% low; cíle musí
   projít.
10. Přepnutí presetu v menu skutečným vstupem se projeví hned a vydrží restart.
11. Limit fps 60: průměr 60 ± 2 a vytížení GPU klesne proti „bez limitu“.
Vše skutečným vstupem hráče.

## Záznamy
Screenshot menu nožů a menu vylepšení; videa inspectu 3–5 s: Karambit, M9 Bayonet, Butterfly; video 15–20 s boje
se strojem (hitmarkery, čísla, jiskry, zásah hráče); video 10 s bhopu na levelu 0 a 5 vedle sebe; screenshoty ze stejné pozice v Low, Medium a High;
tabulka 0.2 proti 0.3 (RAM, VRAM, čas GPU, fps) v SHRNUTI-0.3.md.

## Listing
Doplnit nože, XP a vylepšení, efekty zásahů.
Řádek o výběru nožů formulovaný jako „vyber si model nože z CS2 ve své instalaci“; nic o skinech zdarma ani
odemykání inventáře CS2.

## Postup
build → autotest → záznamy → balíček → Melty release 0.3.0 (koncept) → SHRNUTI-0.3.md → „ano“ → publish + ověření.
