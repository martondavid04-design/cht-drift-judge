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

A játékban: **Ctrl+Shift+D** fő ablak, **Ctrl+Shift+H** HUD, **Ctrl+Shift+Z** pályarajz ki-be.
A szerverről kapott változat nem ment fájlt (a CSP nem engedi); a beállítások és a pályaterv a CSP
saját tárolójában maradnak meg. A változtatás a szerver újraindítása után él.

## Telepített változat

`dist/CHT_DriftJudge_v<verzió>.zip` – kicsomagolva az Assetto Corsa mappájába:
`assettocorsa/apps/lua/CHT_DriftJudge`. Pályaterv készítéséhez és hangoláshoz (telemetria-fájlok) ez
kell. Ha egy gépen fut, a szerverről kapott változat ott csendben marad. Részletes leírás és
tesztterv: `OLVASS_EL.txt`.

## Pályatervek

`layouts/<pálya kulcsa>/<név>.json` (és opcionálisan `layouts/<pálya kulcsa>/index.json`: a nevek
listája). A pálya kulcsa a pálya mappaneve (layoutnál `pálya__layout`). Pályaterv a telepített app
Pálya fülén a „Másolás” gombbal vihető ki.

## Fejlesztés

- `app/CHT_DriftJudge/` – a forrás (ugyanez fut telepítve és online)
- `python3 tools/build.py` – elkészíti az `online/cht_drift_judge.lua` és a `dist/…zip` fájlt
- `python3 tests/scenarios.py` és `python3 tests/smoke_038.py` – offline tesztek CSP-csonkkal
  (`pip install lupa`)
