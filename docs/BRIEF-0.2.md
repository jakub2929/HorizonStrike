# Zadání 0.2 – vzhled mapy, stroje, plynulost (2026-10-09)

Platí vše z BRIEF.md a CLAUDE.md (stopky, orchestrace, větve z main, preflight, MODLOG, nic ze hry v balíčku ani
v gitu, CS2 ani HZD se nespouští). Run uninterrupted. Před publikováním shrnutí a „ano“ uživatele.
Cíl: hráč na první pohled pozná Horizon a svět běží plynule. Herní smyčka, ekonomika ani zbraně se nemění.

## Mapa – vzhled
- Textury předkomprimované v konvertoru (BC1/BC3/BC5/BC7 podle typu); video paměť na startu ≤ 2,5 GB (GPU 8 GB).
- Normálové mapy a roughness/specular pro terén, skály, stavby a vegetaci z dat HZD.
- Terén: prolínání materiálů (sníh, tráva, hlína, skála) podle masek z HZD, ne jedna barevná textura.
- Obloha, slunce, mlha, atmosféra laděné podle HZD; pevná hezká denní doba (dopoledne), bez cyklu dne a noci.
- Voda (řeky, jezera), pokud je v datech HZD.
- Ambience vítr/déšť (ATRAC9): dekodér s kompatibilní licencí (ffmpeg / libatrac9) v konvertoru na straně hráče,
  max 3 kroky; když ne, jedna věta a pokračovat.

## Mapa – plynulost
- Occlusion culling (OccluderInstance3D z terénu a velkých objektů, generovaný v konvertoru pro každou buňku),
  visibility ranges / HLOD, LOD z HZD nebo generované.
- Opakující se objekty přes MultiMesh.
- Načítání buňky rozložené do snímků: příprava ve vlákně, vkládání po dávkách s časovým rozpočtem, kolize postupně
  a jen v okolí hráče.
- Shadery/materiály předkompilované při úvodním načítání.
- Nejdřív změřit časy fází načítání buňky, zapsat do MODLOG, opravit největší položku.

## Stroje
- Nové: Sawtooth, Scrapper, Broadhead – skutečné modely, kostry, textury; životy a slabá místa z dat HZD; chování
  podle HZD; obsadí svá původní místa (tabulka v MODLOG aktualizovaná).
- Odměny stejným vzorcem (CS2 kill award × násobič podle síly stroje v sheetu).
- Animace všech 6 strojů procedurálně na skutečných kostrách: vlastní chůze a běh, IK nohou, náklon těla, otáčení
  na místě, pasení, útoky, reakce na zásah, smrt (pád).
- Vše přes obsahový kontrakt.

## Stabilita
- Zátěžový běh: trasa přes ≥ 30 buněk, 20× po sobě, bez pádu.

## Autotest (vše z 0.1 + nový t03 dál musí projít)
1. Sawtooth, Scrapper, Broadhead projdou stavovým cyklem (podezření → poplach → útok nebo útěk podle druhu).
2. Slabé místo dává víc než tělo u všech 6 strojů – skutečným výstřelem přes vstup hráče, s ověřením, že první
   zasažená věc je slabé místo; zapsat, z kolika směrů z 8 jde zasáhnout.
3. Materiály terénu, skal a staveb mají normálovou mapu.
4. Výkon na startu i na trase přes ≥ 10 buněk: ≥ 60 fps průměr, 1% low ≥ 45 fps, žádný snímek > 50 ms při načítání
   nové buňky; video paměť na startu ≤ 2,5 GB.
5. Zátěžový běh streamování 20× bez pádu.
Pravidlo: žádný test nesmí obcházet vstup hráče voláním funkce (API jen pro přípravu a čtení stavu).

## Záznamy
- Screenshoty před/po ze stejných pozic jako v 0.1: Mother's Heart, údolí, skály zblízka.
- Videa 5–10 s (Godot --write-movie): každý ze 6 strojů chůze, útok, smrt; 20–30 s chůze přes hranice buněk.
- Graf času snímků z trasy přes 10 buněk, 0.1 proti 0.2.

## Postup
build → autotest → záznamy → balíček → Melty release 0.2.0 do „horizon-strike“ (inspect_package, validate_recipe,
one_click_check, upload, submit_release, screenshot), text listingu podle prokázaného → shrnutí → „ano“ → publish.

## Shrnutí před publikováním 0.2
změny proti 0.1.1; co se nepovedlo (věta každé); tabulka autotestu; fps, 1% low, nejdelší snímek při načítání a VRAM
(0.1 vs 0.2); cesty ke screenshotům před/po, videím a grafu; celý nový text listingu; ID release.
