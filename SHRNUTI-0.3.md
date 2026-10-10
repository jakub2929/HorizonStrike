# Shrnutí před publikováním – Horizon Strike 0.3.0

**Stav: ROZPRACOVANÉ (2026-10-10 ~21:40).** Balíček `HorizonStrike-0.3.0.zip` je připravený a prošel kontrolami Melty
(`validate_recipe` platný, `one_click_check` = yes, 222 souborů umístěno, 0 vynecháno). Na Melty zatím NENÍ nahraný:
0.2.0 je pořád v ruční kontrole Melty (viz „Čeká“). Nic není publikované.

Build: značka `v0.3.0` (větev `release/0.3`), `C:\meshy\_tools\release\0.3.0`, zip
`C:\meshy\_tools\release\HorizonStrike-0.3.0.zip` (83 111 653 B, sha256 `99319de3…2eed5c8f`). Kontrola balíčku
(`tools/preflight.py package`): CLEAN – nic ze hry v balíčku. Celá sada testů běžela na `v0.3.0-rc3`/`rc4`; `v0.3.0` se
od rc4 liší jen čísly verze (hra, exe, konvertor) a od rc3 navíc jen opravou nahrávače videa bhopu (r08).

## Co je nového proti 0.2
- **Nože:** výběr modelu nože z CS2 ve tvé instalaci (22 nožů), Esc → Knife s otáčejícím se 3D náhledem, vlastní
  animace v ruce včetně inspectu (F) a zvuky; poškození všech nožů = výchozí nůž (jako v CS2). Jen výchozí finish
  (skiny CS2 skládá shader, který nejde přečíst).
- **XP, levely a vylepšení:** XP za zabití (100 × násobek odměny stroje, +20 % za zabití do slabého místa, +30 % za
  silent strike), levely do 15, bod za level; menu K: poškození +10 %/level, max. životy +20/level, bhop +1 skok/level
  (vše max. 5). XP a vylepšení přežijí smrt i restart.
- **Silent strike:** bodnutí nožem (pravé tlačítko) do nic netušícího stroje mimo jeho zorné pole × 5.
- **Bunny hop:** level N udrží rychlost N skoků za sebou, skok N+1 ji ořízne; rychlost se nabírá air strafem jako v CS2
  (A/D + otáčení myší) – ověřeno skutečným vstupem (level 5: 6,35 → 14,2 m/s).
- **Efekty zásahů:** hitmarker (silnější na slabém místě), čísla poškození (vypínatelná v Esc), jiskry a úlomky na
  strojích, indikátor směru a červená viněta při zásahu hráče, aimpunch, zvuky zásahů z CS2.
- **Grafická nastavení (Esc → Graphics):** presety Low / Medium / High (první start volí podle GPU a VRAM), limit fps,
  VSync, render scale s FSR, stíny, dohled a hustota vegetace, LOD, SSAO, SSR, objemová mlha.
- **Výkon:** hustý obsah buněk se kreslí po 128m blocích (dřív 512 m – kreslil se celý v plném detailu) → GPU na High
  11,4 → 5,1 ms/snímek; výstřel už nic nealokuje (dřív ~15 ms na výstřel); uvolňování buněk a vstup strojů rozložené.
- **Rychlejší první spuštění:** 81,9 s → **26,5 s** do hratelnosti (na startu jen nůž a Glock, ostatní zbraně se
  převádějí na pozadí, buy wheel ukazuje „Preparing…“).
- **Konvertor:** v nečinnosti ~9 MB místo ~4,3 GB.

## Srovnání 0.2 a 0.3 (release, 1920×1080, bez vsync, fps bez limitu, RTX 3060 Ti, klidný stroj)
| | 0.2.0 | 0.3.0 High | 0.3.0 Low |
|---|---|---|---|
| start: průměr / 1 % low | 77,1–77,7 / 70,5–70,8 fps | 127,7 / 110,1 fps | – |
| trasa 10 buněk: průměr / 1 % low | 83,9–85,3 / 44,4–49,0 fps | 164,2 / 68,5 fps (t15); 158,0 / 61,4 (t25) | 209,5 / 73,7 fps |
| nejhorší snímek při načítání buňky | 35–40 ms | 33,2 ms (t15), 38,9 ms (t25) | 37,7 ms |
| čas GPU / CPU renderu na trase | 10,95 / 3,0 ms | 5,14 / 2,51 ms | 3,33 / 1,98 ms |
| VRAM na startu / max na trase | 1491 / 2126 MiB | 1404 / 1753 MiB | – / 1471 MiB |
| RAM hry (špička na trase) | working set max 2,7 GB | 2,74 GB | 2,67 GB |
| RSS v zátěžovém testu t16 | 2,73–2,93 GB | 2,56–2,62 GB | – |
| konvertor v nečinnosti | ~4,3 GB | 8,6 MB (private 14 MB) | 8,6 MB |
| první spuštění do hratelnosti | 81,9 s | 26,5 s | – |
| boj se 3 stroji s efekty (t24) | – | 115,3 / 81,9 fps, nejhorší 18,6 ms | – |
| limit 60 fps (t27) | – | 60,0 fps, zátěž GPU 931 → 449 ms/s | – |

## Cíle 0.3 (BRIEF)
| cíl | výsledek |
|---|---|
| Low: GPU ≤ 5 ms/snímek | **3,33 ms** ✔ |
| Low: VRAM ≤ 1,5 GB | **1471 MiB** ✔ |
| Low: RAM hry ≤ 2,5 GB | **2,67 GB ✘** – špičku tvoří ovladač GPU a Vulkan (~1 GB), namapované soubory (~600 MB, z toho DLL ovladače NVIDIA ~330 MB) a halda Godotu (~1 GB); Low i High mají stejnou špičku, preset s ní nehne (menší prstenec buněk −8 až −25 MB). Nejlepší hodnota 2,67 GB. |
| High: limity 0.2 (≥ 60 fps, 1 % low ≥ 45, žádný snímek > 50 ms při načítání) | 158,0 / 61,4 fps, 38,9 ms ✔ |
| High: RAM hry ≤ 3,5 GB | 2,74 GB ✔ |
| konvertor v nečinnosti ≤ 300 MB | 8,6 MB ✔ |
| první spuštění ≤ 40 s | 26,5 s ✔ |

## Autotest (release, spuštěno jako z Melty + --autotest)
- Funkční sada `v0.3.0-rc3`: **25/25 PASS** – t01–t14 a s01–s03 z 0.1/0.2, t17 (22/22 nožů s kontraktem), t18 (volba
  nože přes menu přežije smrt i restart), t19 (poškození všech nožů = výchozí, inspect u všech), t20 (XP: tělo +100,
  slabé místo Grazer +180, silent strike Broadhead +260, level-up +1 bod), t21 (vylepšení přes K, přežijí restart),
  t22 (bhop 0/1/5), t23 (efekty zásahu), t26 (přepnutí presetu vstupem, přežije restart). Vše skutečným vstupem.
- Výkon `rc3`: t15 PASS, t24 PASS, t27 PASS, t25 High PASS, t25 Low FAIL jen na RAM (viz cíle).
- t16 zátěž streamingu 5×: **5/5** (30 buněk, exit 0, 0 chyb, RSS 2556–2624 MB, VRAM 1227 MB).
- t09 první spuštění: PASS (jen startovní buňka při world_ready, 9 buněk po bootstrapu).
- Smoke na finálním `v0.3.0`: t01, t03, t17, t26 PASS; t22 napoprvé FAIL (strafe přestal přidávat rychlost po 2.
  skoku, běh se kryl s prací uživatele na PC – ztráta fokusu uvolní drženou klávesu), na klidném stroji **PASS 16/16**
  (level 5: 7,82 → 9,47 → 10,87 → 12,11 → 13,23 m/s, skok 6 ořízne).

## Záznamy (`C:\meshy\_tools\records-0.3\`)
- `shots\knife_menu.png`, `shots\upgrades_menu.png` (r05) – **pozor: v pozadí menu jsou řady světlých obdélníčků
  (vada UI, už od začátku menu 0.3), řeší se – čeká.**
- `video\inspect_knife_karambit.mp4`, `…_m9_bayonet.mp4`, `…_butterfly.mp4` (r06, oříznuto na 4,5 s).
- `video\combat.mp4` (r07, 18,6 s: hitmarkery, čísla, jiskry, zásahy hráče).
- `video\bhop_l0_vs_l5.mp4` (r08, 10 s vedle sebe; rychlost nabírá hráč jen strafem: level 0 max 7,2 m/s, level 5 max
  9,7 m/s a ořez na 6,35). Proti t22 (až 14,2 m/s) je to méně, protože video se nahrává s pevnými 30 snímky/s, takže
  myš opraví směr pohledu jen 30× za sekundu (t22 bez limitu ~150×) a strafe se navíc každý skok střídá A/D, takže
  pohled za rychlostí zaostává a každá fáze ve vzduchu přidá zhruba polovinu rychlosti.
- `shots\{mothers_heart,valley,rocks_close}_{low,medium,high}.png` (r09, stejné pozice v Low/Medium/High).

## Co se nepovedlo / známé problémy
- **Cíl RAM hry na Low ≤ 2,5 GB splněný není** (2,67 GB, přijato): špičku tvoří ovladač GPU a Vulkan (~1 GB),
  namapované soubory (~600 MB, z toho DLL ovladače NVIDIA ~330 MB) a halda Godotu (~1 GB), které na presetu nezávisí –
  Low i High mají stejnou špičku a ani menší prstenec plných buněk ji nesnížil o víc než 25 MB.
- Nože jen ve výchozím finishi.
- Obdélníčky v pozadí menu (oprava běží).
- Rezerva nejhoršího snímku při načítání je ~11 ms: uvolnění meshů jedné buňky stojí najednou 17–30 ms a stavba
  kolizního tvaru až 12 ms (kandidáti na další optimalizaci).
- Dřívější známé: zdi a podlahy Cauldronu šedé; Sawtoothův kanystr zasažitelný jako první věc z 5/8 směrů.

## Čeká
1. Opravit obdélníčky v pozadí menu a znovu vyfotit r05 (běží).
2. Melty: 0.2.0 je stále v ruční kontrole („Melty's team will take a look“), na listingu je věta o review.
   Druhá selhaná instalace 0.1.1 nemá v `install_outcomes` žádný důvod (hlášen jen výpadek Melty u jedné) – nic
   nenaznačuje chybu hry.
3. Nahrát 0.3.0 jako koncept (submit_release) až po schválení 0.2.0 (tvé rozhodnutí); pak
   screenshoty a text listingu 0.3 (`docs/listing-0.3.md`) až při publikaci, a „ano“ → publish.
4. Vrátit tvou cache a profil z `%LOCALAPPDATA%\HorizonStrike\prev-0.3rc-1440` (po posledním okenním běhu).
