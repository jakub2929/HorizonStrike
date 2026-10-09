# Zadání: Counter-Strike 2 × Horizon Zero Dawn Complete Edition (mashup pro Melty)

Toto je odsouhlasené zadání (zdroj pravdy pro design). Technické kontrakty jsou v `docs/ARCHITECTURE.md`,
rozhodnutí a průběh v `MODLOG.md`, pravidla pro agenty v `CLAUDE.md`.

Režim práce: Run uninterrupted. Zastavit se jen kvůli přihlášení/platbě, otázce blokující veškerou zbylou práci,
velké chybě (zápis nebo spuštění herní instalace, mazání mimo C:\meshy, nejde postavit vůbec nic) a před
publikováním (shrnutí + čekat na „ano“).

## Design (odsouhlaseno)
- Hráč je ve světě Horizonu a bojuje se stroji z Horizonu. Zbraně, peníze a buy wheel jsou z CS2.
- Logika Horizonu zůstává: stroje se chovají jako v HZD (hlídky, stáda, podezření → poplach → útok, slabá místa).
- Za každé zabití peníze (ekonomika CS), za ně lepší zbraně přes buy wheel.
- Start jako v CS: nůž, Glock a $800.
- Po smrti respawn u posledního ohniště. Znovu nůž a Glock, ostatní nesené zbraně ztratí, peníze zůstanou.
- Stroje v 1. verzi: Watcher, Strider, Grazer.
- Sólo.
- Mapa: Horizon 1:1 se vším všudy. Celý svět Horizonu, vše na původním místě: skály, ruiny, stromy, stavby, ohniště.
  - Terén ze skutečných dat hry, do jeho čtení investovat. Tvar krajiny je hlavní smysl mapy.
  - Vegetaci, kterou HZD generuje procedurálně, rozmístit podle jejích map hustoty z dat hry (ne 1:1).
  - Stroje na svých původních místech, pokud je data obsahují, jinak tam, kde v HZD žijí.
  - Místa ostatních strojů (Sawtooth, Scrapper, …) obsadit stroji 1. verze podle typu místa (varianta B);
    zapsat do MODLOG, kde je co obsazeno.
  - Postavy a lidé z Horizonu v 1. verzi nejsou, živé jsou jen 3 stroje.
  - Když celý svět v 1. verzi nepůjde: co největší souvislá oblast kolem Mother's Heart (Nora) se vším na
    původním místě. Mírně zvlněný terén s texturami Horizonu až po skutečném pokusu o terén. Obojí jednou větou
    ve shrnutí.
- Animace: opravdové modely, textury a kostry strojů z instalace HZD; pohyby napsané vlastní na jejich skutečné
  kostře, co nejblíž originálu.
- Zvuky a hudba z Horizonu; zvuky zbraní z CS2.

## Výchozí rozhodnutí (čísla lze doladit testem; zapsáno v MODLOG)
- Odměna za zabití = CS2 kill award podle třídy zbraně × násobič stroje (sheet strojů). Strop $16 000 jako v CS2.
- Zásah do slabého místa = poškození zbraně × headshot násobič té zbraně z CS2.
- Výstřel zvedá podezření strojů v okruhu; tlumené zbraně mají menší okruh.
- Buy wheel v 1. verzi max 12 položek s cenami z dat CS2: pistole, SMG, pušky, AWP, brokovnice, HE, molotov, armor.

## Technika
- Hostem je CS2 v režimu „standalone“ (vlastní program, Melty předá složku CS2; vzor spike-rush a kh1-x-cs2).
  HZD je v receptu „secondary“ (custom-horizon-zero-dawn-complete-edition). Program najde HZD sám přes Steam
  libraryfolders.vdf a ve hře řekne, když chybí.
- CS2 ani HZD se nikdy nespouští, nemoduje, ani se do nich nezapisuje; jen se čtou jejich soubory.
- Žádné soubory her se nedistribuují. Assety se konvertují z hráčových instalací do lokální cache.
  oo2core se načítá z instalace HZD, nikdy se nekopíruje do balíčku.
- Preflight před každým buildem ověřuje, že v exportu není žádný soubor odvozený ze hry.
- Godot 4.7.2 (GDScript) + konvertor v .NET 10 (ValveResourceFormat 20 vyžaduje .NET 10), publikovaný jako
  self-contained win-x64 (hráč nepotřebuje .NET runtime). Hra s konvertorem mluví přes stdio; žádný TCP listener
  (kdyby byl, jen 127.0.0.1).
- „Horizon Strike“ je pracovní název; finální název, tagline a popis až podle hotového buildu.
- Svět po buňkách: konvertovat až když se hráč přibližuje, s předstihem, aby nečekal. První spuštění převede jen
  zbraně, stroje a oblast kolem startu, nesmí čekat na celý svět. Cache má rozumný výchozí strop nastavitelný
  v menu; vzdálené buňky se při překročení mažou a při návratu znovu převedou. Hra ukazuje, kolik místa cache zabírá.
- JSON sheety (zbraně, stroje, systémy, hooky), preflight před každým buildem, deník v MODLOG.md.

## Listing
- Název, tagline, popis navrhne orchestrátor podle hotového buildu; jen to, co test ve hře prokázal.
- Autor (credits): EM
- Licence obsahu: MIT
- Remix povolen: ANO

## Autotest (`--autotest`, spuštěný stejně jako ho spouští Melty)
1. start nůž + Glock + $800
2. zabití stroje přidá správnou odměnu
3. nákup odečte cenu
4. slabé místo dává víc než tělo
5. Watcher: podezření → poplach → útok
6. stádo při poplachu uteče
7. smrt: zbraně pryč, nůž + Glock zpět, peníze zůstanou, respawn u posledního ohniště
8. hláška ve hře, když chybí HZD
9. první spuštění nepřevádí celý svět
10. cache nepřekročí strop
11. konvertor neposlouchá na žádné jiné adrese než loopback (komunikace je přes stdio)

Screenshoty ze hry (aspoň 3): buy wheel, poplach Watchera, stádo v krajině.

## Shrnutí před publikováním musí obsahovat
co v buildu je; jak velká část světa se postavila a jestli je terén skutečný; co bylo seškrtáno (jednou větou
každé); tabulku výsledků autotestu; délku prvního spuštění a velikost cache po něm; cesty ke screenshotům; celý text
listingu; ID release.
