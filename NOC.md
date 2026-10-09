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
