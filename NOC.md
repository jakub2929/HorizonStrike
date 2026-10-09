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
