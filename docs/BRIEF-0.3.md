# Zadání 0.3 – výběr nožů z CS2 (2026-10-10)

Platí CLAUDE.md (zakázané příkazy, testovací cache na E:\meshy_work). Run uninterrupted; před publikováním shrnutí
a „ano“ uživatele. Herní smyčka, ekonomika ani ostatní zbraně se nemění.

## Nože
- Seznam nožů z dat CS2 hráče (items_game), ne natvrdo (Karambit, M9 Bayonet, Butterfly a všechny ostatní). Nože,
  které v instalaci nejsou nebo nejdou převést, ve výběru nejsou a do MODLOG jednou větou.
- Každý nůž: model, vlastní animace v ruce (vytažení, útok, inspect na F) a zvuky z CS2; obsahový kontrakt jako
  ostatní zbraně.
- Poškození a rychlost útoku všech nožů = výchozí nůž (jako v CS2); silent strike funguje se všemi.
- Volný výběr v Esc menu, položka „Nůž“ s náhledem modelu; volba uložená lokálně, platí i po respawnu a restartu.
- Finishe: výchozí vzhled; pokus o převod finishů z dat CS2 max 3 kroky, jinak jedna věta.

## Autotest (+ celá dosavadní sada musí projít)
1. Každý nůž ze seznamu se načte a má všechny pojmenované body z kontraktu.
2. Výběr přes menu skutečným vstupem: zvolený nůž v ruce, po smrti a respawnu i po restartu hry pořád zvolený.
3. Poškození vybraného nože = výchozí.
4. Inspect (F) přehraje animaci u každého nože.

## Záznamy
Screenshot menu výběru nožů; videa inspectu 3–5 s: Karambit, M9 Bayonet, Butterfly.

## Listing
Řádek o výběru nožů formulovaný jako „vyber si model nože z CS2 ve své instalaci“; nic o skinech zdarma ani
odemykání inventáře CS2.

## Postup
build → autotest → záznamy → balíček → Melty release 0.3.0 (koncept) → SHRNUTI-0.3.md → „ano“ → publish + ověření.
