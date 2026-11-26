# CHT Drift Judge

Drift pontozó és bírói rendszer Assetto Corsához (Custom Shaders Patch, Lua) – a CornerHuntersTeam
megrendelésére. 1. fázis: solo (kvalifikációs) pontozás zónákkal, pályaszerkesztő, telemetria.
Pontozás: Drift Masters 2025 (Line 60 / Angle 20 / Stílus 20).

## Szerverről, telepítés nélkül

A szerver (AssettoServer) minden belépőnek elküldi a programot. A szerver
`cfg/csp_extra_options.ini` fájljában (panel: CSP Options → CSP Extra Options):

```ini
[SCRIPT_1]
SCRIPT = 'https://raw.githubusercontent.com/martondavid04-design/cht-drift-judge/main/online/cht_drift_judge.lua'
REQUIRED = 0
layout = ''
pilotScores = 1
judges = ''
broadcasters = ''
```

| Kulcs | Jelentés |
| --- | --- |
| `SCRIPT` | ennek a repónak az `online/cht_drift_judge.lua` fájlja; a `main` ágra mutat, így mindig a legfrissebb verzió megy ki |
| `REQUIRED` | 1 = a script nélkül nem lehet csatlakozni (versenyen), 0 = próbához |
| `layout` | a pályaterv neve a `layouts/<pálya>/` mappából (üres = az `index.json` első neve, vagy „Alap”) |
| `pilotScores` | 1 = a pilóták is látják a pontjukat, 0 = csak a bírók és a közvetítő |
| `judges`, `broadcasters` | Steam64 azonosítók vesszővel elválasztva (szerep a szervertől) |
| `sendResults` | 1 (alap) = a befejezett futások eredménye mindenkihez elmegy (a bírók gyűjtik) |
| `base` | ha a fájlok máshol vannak: a repó raw címe `/`-rel a végén |
| `upload` | 1 (alap) = a tesztadatok (belépés, futások a felvétellel, hibák) a fejlesztő Google-táblázatába mennek; 0 = ki |
| `uploadUrl` | ha a tesztadatok máshova menjenek (üres = a beépített cím) |

A szerver adminjai (panel → Admins: Steam ID-k) bíróként látják a pontokat akkor is, ha
`pilotScores = 0`.

## Tesztadatok

A program (`src/upload.lua`) minden gépről HTTPS-en küldi a tesztadatokat egy Google Apps Script
webappnak, ami egy Google-táblázatba írja őket (lapok: Futások, Telemetria, Belépések, Debug). A
fogadó script: `tools/gsheet_collector.gs` (a közzétett változatban van az olvasó kulcs, itt nincs).
A programban lévő írókulccsal csak sort lehet hozzáadni, olvasni nem.

A játékban: **Ctrl+Shift+D** fő ablak, **Ctrl+Shift+H** HUD, **Ctrl+Shift+Z** pályarajz ki-be.
Az első belépéskor a fő ablak magától megnyílik, a HUD alapból látszik, és amíg a fő ablak zárva van, a
képernyő tetején egy kis „CHT Drift Judge” gomb nyitja meg. Ha a gépen régi (0.3.8 előtti) telepített
változat is van, a program szól (a kettő egyszerre futna).
A szerverről kapott változat nem ment fájlt (a CSP nem engedi); a beállítások és a pályaterv a CSP
saját tárolójában maradnak meg. A változtatás a szerver újraindítása után él.

## Telepített változat

`dist/CHT_DriftJudge_v<verzió>.zip` – kicsomagolva az Assetto Corsa mappájába:
`assettocorsa/apps/lua/CHT_DriftJudge`. Pályaterv készítéséhez és hangoláshoz (telemetria-fájlok) ez
kell. Ha egy gépen fut, a szerverről kapott változat ott csendben marad. Részletes leírás és
tesztterv: `OLVASS_EL.txt`.

## Közös pályatervek (0.3.12)

A program induláskor (és a Pálya fülön a „Frissítés a szerverről” gombra) letölti az adott pálya közös
pályaterveit – a telepített app és a szerverről kapott változat is:

1. a GitHub `layouts/<pálya kulcsa>/` mappájából (lásd lent),
2. a játékból feltöltöttek közül: Pálya fül → **„Feltöltés mindenkinek”**. Ezek a tesztadatokat gyűjtő
   Google-scripthez kerülnek (`tools/gsheet_collector.gs`, Pályatervek lap, minden változat megmarad), és
   onnan kérhetők le kulcs nélkül: `<script címe>?action=layouts&track=<pálya kulcsa>`. Ugyanazon a
   néven a feltöltött nyer. GitHub-írókulcs azért nincs a programban, mert a program nyilvános: a kulccsal
   bárki átírhatná a repót.

Ami egy gépen módosult, nem vész el: marad, amíg a közös nem változik; ha mindkettő változott, a helyi
`<név> (helyi)` néven megmarad (`settings.layoutSync` tartja nyilván, melyik közös változat van a gépen).
Pályát offline, a telepített appal lehet készíteni (egyjátékos mód), és onnan feltölteni.

## Bíróknak: Versenyzők fül és néző mód (0.3.14)

- **Versenyzők fül**: pilótánként minden futás és pont, rangsor (legjobb → második legjobb → a legjobb
  Line / Angle / Stílus), bírói levonás futásonként, „Követés” (kamera az autóra), „Másolás
  táblázatként” (TSV). Ott látszik, ahol a pontok is (`platform.canSeeScores()`).
- **Néző mód**: `ui.carMode = 'auto'` (alap) – a kamera által követett autót pontozza és mutatja
  (`sim.focusedCar`; szabad kameránál marad a követett). A követett autó eredményét a gép nem küldi el
  a pilóta nevében; a tesztadatokban „futás (néző gépén)” címkével megy, `judgedBy` mezővel. Hiányzó
  kerékadatnál (távoli autó) a kerék helye becsült, a felülete nem számít (`wfb` mező a felvételben).

## Szerepek a szerveren (0.3.15)

- Minden gép, amin az online script fut, elküldi a saját Steam ID-ját (`cht.driftjudge.hello.v1`);
  a szerveradmin a Versenyzők fülön Pilóta / Bíró / Közvetítő szerepet ad (`src/roles.lua`). A szerep
  a táblázat Szerepek lapjára kerül, a gépek `?action=roles`-szal olvassák (csak a Steam ID
  ujjlenyomata megy ki), a változás után `cht.driftjudge.role.v1` jelzés. Sorrend: a szerver
  `judges` / `broadcasters` listája → kijelölt szerep → szerveradmin.

## Adattáblázat (0.3.15-től a 2.)

- `tools/gsheet_collector.gs` + `tools/appsscript.json`: a „CHT Drift Judge – adatok (2)” táblázat
  scriptje. A futások felvétele gzip fájlként a Drive „CHT Drift Judge – felvételek” mappájába megy
  (csak a script által létrehozott fájlokhoz fér hozzá: `drive.file`), a táblázatban rövid sorok. Az
  első táblázat 2026-11-26-án megtelt és csak olvasható lett; az adatait az `atvetel()` hozta át, a
  régi felvételeket a script a régi webappból olvassa.

## Pályatervek

`layouts/<pálya kulcsa>/<név>.json` (és opcionálisan `layouts/<pálya kulcsa>/index.json`: a nevek
listája). A pálya kulcsa a pálya mappaneve (layoutnál `pálya__layout`). Pályaterv a telepített app
Pálya fülén a „Másolás” gombbal vihető ki.

## Fejlesztés

- `app/CHT_DriftJudge/` – a forrás (ugyanez fut telepítve és online)
- `python3 tools/build.py` – elkészíti az `online/cht_drift_judge.lua` és a `dist/…zip` fájlt
- `python3 tests/scenarios.py` és `python3 tests/smoke_038.py` … `smoke_0315.py` – offline tesztek CSP-csonkkal
  (`pip install lupa`)
