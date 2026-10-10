# NOC – noční běh 0.2 (2026-10-09/10)

Pravidla: docs/BRIEF-0.2.md, CLAUDE.md, MODLOG.md. Orchestrátor pracuje ve worktree `.claude/worktrees/orch`
(větev `orch`), do main jen slučuje. Zakázané příkazy viz zadání (žádné rm/push/stash/reset/clean/rebase).
Když nevíš, kde jsi: přečti NOC.md a MODLOG.md a pokračuj od posledního záznamu.

## Záznamy
- 22:01 Start nočního běhu. 0.1.1 odeslaná k publikování (in_review, sleduje se), Controls řádek v listingu
  upraven. Hotovo: brief 0.2, pravidlo testů přes vstup. Běží: agent plan (sheety 3 nových strojů, rozpis 0.2).
  Další: po planu spustit svet, hra, stroje, test.
- 22:10 0.1.1 LIVE (mod_status: live version 0.1.1, one click yes); listing ukazuje nový řádek Controls a screenshoty. Běží: plan. Další: svet/hra/stroje/test po planu.
- 22:12 Plan 0.2 hotový a sloučený (sheety bez site_map, PLAN-0.2.md). Běží: spouštím svet, hra, stroje, test (fáze A měření). Další: H1 profil načítání, V0 audit textur, M0 bench, T1 baseline 0.1.1.
- 22:13 Spuštěni svet (V0–V2…), hra (H1 profil → H2 → H3…), test (T1 baseline 0.1.1 → T2–T4), stroje (nový; M0 bench → M1 animace → M2/M3). Watchdog hlídá 45 min bez pokroku. Další: slučovat po dodání.
- 22:42 svet V0–V2 hotovo (DDS, normály, ORM) – čeká na sloučení spolu s H3 od hra. svet pokračuje V3–V7. Běží: hra H1/H2/H3, test T1, stroje M0/M1.
- 22:57 svet V3 hotovo (3 nové stroje), modely předány stroje. svet pokračuje V4–V7.
- 23:12 Sloučeno: svet V0–V2 + hra H1–H3 (DDS ve hře funguje v release, VRAM start 1022 MB, nejhorší snímek trasy 1676→77 ms). main build + smoke OK. Běží: hra H4–H8 (nejdřív precompile shaderů), svet V4–V7 (V4–V6 už commitnuté), stroje M0–M3, test T1.
- 23:21 Sloučeno svet V3–V7 (site_map nových strojů zatím zadržen do AI od stroje). svet hotov. Běží: hra H4–H8, stroje, test.
- 00:01 Sloučeno stroje M0–M3 (animace 6 strojů, AI 3 nových) a znovu zapnut spawn nových strojů na jejich místech (site_map). main smoke OK. Běží: hra H4–H8 (+ stavy stalk/scavenge v in_combat/audio/spawner), test.
- 00:39 Sloučeno hra H4–H8 (release trasa 98 fps, 1% low 46, max load 48,7 ms, VRAM 1,4 GB). Otevřené: konverze na pozadí sráží fps (→ svet: nízká priorita), vzácný segfault (→ hra), t05 Watcher přeskočí suspicious (→ stroje), 1x1 DDS (→ svet). Běží: test.
- 00:47 Sloučeno svet: throttle konvertoru (CPU 28 %→10 %), DDS min 4x4, automatická rekonverze buněk při změně sheetů. Běží: hra (segfault + napojení throttle), stroje (t05), test.
- 01:13 Sloučeno stroje: oprava průběhu podezření (t05 PASS). Běží: hra (segfault + throttle), test.
- 01:23 Sloučeno stroje: showcase scéna pro videa strojů (Watcher walk/attack/death natočeno, snímky ne prázdné). Běží: hra (segfault+throttle), test.
- 01:32 Sloučeno test: t12/t13 PASS, t14 FAIL (budovy 72,8 % normál → svet), t16 pád při ukončení (→ hra), t15 měřeno na buildu před H4–H8 (znovu na konci). Záznamy natočeny (18 klipů strojů + průchod buňkami + graf). Další: svet F8, hra F9+segfault+throttle, pak finální měření na klidném stroji.
- 01:41 Sloučeno svet: normálové mapy budov 99,3 % (t14). Běží: hra (pád při ukončení / segfault, throttle). Další: finální build + celý autotest + měření na klidném stroji.
- 01:46 Sloučeno test: t14 PASS (budovy 99,5 % hrubě / 100 % po vyřazení hzd_normal none). Běží: hra (F9 + segfault + throttle). Další: T6.
- 01:46 Kontrola záznamů: videa a snímky nejsou prázdné (snímky Sawtooth death, Mother's Heart před/po prohlédnuty). Snímky „po“ a video průchodu jsou z buildu před hra H4–H8 → v T6 pořídit znovu na finálním buildu. Vzdálený vodopád/útes má barevné pruhy (chybný materiál) – menší vada. Běží: hra.
- 02:02 test: baseline 0.1.1 běh g (zašuměný, běžely jiné procesy). Čisté srovnání + T6 až na klidném stroji po hra. Běží: hra.
- 02:44 Sloučeno hra: pád při ukončení/segfault opraven (0 pádů ve 105 bězích), throttle zapojen. Zbývá: 3 snímky >50 ms (4 nepředkompilované pipeline + synchronní zápis logu) → hra. Pak T6.
- 02:56 Watchdog: test nečinný 54 min – čeká na pokyn k T6 (očekávané). Před finálním buildem ověřit 7 buněk sheetů (render.* od hra – DDS ověřeno v release H3, vzhled v H5; perf.shot_poses od test) – až po posledním commitu hra, aby nevznikl konflikt v systems.json.
- 03:14 Sloučeno hra (neblokující log, žádné kompilace pipeline ve hře; trasa 0 snímků >50 ms). Sheety CLEAN, verze 0.2.0. Další: release build + T6 (celý autotest + t15/t16 + nové záznamy) na klidném stroji.
- 03:16 Release 0.2.0 postaven (_tools/release/0.2.0, zip 82,8 MB, sha256 d151bce2…827f), package preflight CLEAN; Melty inspect/validate OK, one_click yes. Běží: test T6 (celý autotest + t16 20× + čistá baseline + nové záznamy). Upload až po T6.
- 06:11 T6: 17/19 PASS. Opravit: F10 (úklid cache maže buňku, kterou trasa potřebuje → hra), t15 jeden snímek 51,7 ms (→ hra), Sawtooth slabé místo 4/8 (→ stroje). Pak rebuild 0.2.0 a znovu celá sada.
- 06:12 Průběžné SHRNUTI-0.2.md zapsáno (17/19, opravné kolo běží). Listing 0.2 návrh v docs/listing.md (jen prokázané věci). Viditelné vady ve finálních snímcích (modré stíny, šedý pruh na horizontu, lesklý sníh) předány hra.
- 06:23 stroje: Sawtooth 3–4/8 je věrné umístění kanystru pod hrudí (3 pokusy, vráceno) → rozhodnutí v OTAZKY.md: ponechat. Běží: hra (F10, 51,7 ms, vzhled).
- 07:44 hra: F10 opraven (t16 4/4 PASS, 0 chyb), vzhled opraven (stíny, horizont, sníh), t15 1 ze 3 PASS (Jolt staví 16 trimesh naráz → commit 4035952 po jednom, neověřeno). STOP: disk C: plný (0,95 GB) → přesouvám testovací cache na E:\meshy_offload (viz OTAZKY.md). Další: sloučit hra, build, T6 znovu.
- 07:46 Sloučeno hra (F10 + vzhled + kolize po krocích). Release 0.2.0-final postaven, preflight CLEAN. Běží: test – finální T6 (cache na E:\meshy_work), offload na E: dobíhá.
- 08:38 Offload hotov: robocopy přesunul 120 složek na E:\meshy_offload (rc 0/1 = úspěch), C: má 170 GB volných. Běží: test (finální T6).
- 08:55 Nové zadání 0.3 (výběr nožů) → docs/BRIEF-0.3.md. Pořadí: dokončit 0.2 (T6 → koncept → SHRNUTI-0.2), paralelně 0.3 ve větvích (cs2: nože v konvertoru; hra: menu + výběr).
- 09:08 Zadání 0.3 rozšířeno (XP a vylepšení, BHOP levely, efekty zásahů) → docs/BRIEF-0.3.md.
- 09:09 Sloučeno cs2: 22/22 nožů z items_game (132 MiB, na vyžádání), finishe nejdou (vcompmat). Větev release-0.2 = stav 0.2.0. Běží: test T6 (0.2), hra (0.3 nože menu), plan (0.3 sheety).
- 09:15 Plan 0.3 sloučen (sheety XP/vylepšení/efekty/bhop, PLAN-0.3.md). Spouštím cs2 K2, hra H1–H5, stroje S1–S2; test dostane 0.3 po T6 0.2.
- 09:19 Sloučeno cs2 K2: 7 zvuků zásahů z CS2 v cs2/ui/snd (cs2_format 3). Běží: hra H1–H5, stroje S1–S2, test T6 (0.2).
- 09:21 Zadání 0.3 rozšířeno o optimalizaci (bod 4): měření, grafická nastavení s presety, auto preset, RAM, konvertor idle. Nový agent vykon (měření + nastavení), svet (paměť konvertoru), hra (uvolňování dat buněk).
- 09:30 Sloučeno stroje S1–S2 (jiskry/úlomky z poolu 32 emitorů, 0,05 ms/snímek; signál machine_killed; take_hit má volitelný 7. parametr silent). T6 0.2: 17/18 PASS, t15 FAIL (jeden snímek 6,8 s na trase), t16 10/20 běhů OK.
- 09:37 Sloučeno svet: konvertor v nečinnosti 118 MB (cíl ≤300). Zbývá snížit špičku při převodu (4–6 GB) → svet.
- 09:52 Sloučeno hra H1–H5 (nože, XP, vylepšení, bhop, efekty; dev skripty skutečným vstupem OK; smoke OK). Zbývá: hra optimalizace RAM + 6,8s snímek z t15; cs2 dvojí převod nože při souběžných požadavcích.
- 09:55 Sloučeno cs2: nůž se při souběžných požadavcích převede jen jednou.
- 10:11 Tag v0.2.0-rc (140134b) + větev release/0.2. Oprava 6,8s záseku půjde na release/0.2 (hra), pak t15 (+t16 5× při změně načítání), build z release/0.2, kontrola že v něm není nic z 0.3, koncept na Melty. Pravidlo t16 5× v CLAUDE.md.
- 10:14 6,8s snímek: t15 běžel současně s mým přesunem 150 GB C:→E: (do 08:27:44) → pravděpodobně I/O zahlcení. Po t16 znovu t15 na klidném stroji; oprava na release/0.2 jen když se zopakuje.
