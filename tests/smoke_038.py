"""Smoke tests for the 0.3.8 features, installed app and online script (bundle).

Run: python3 tests/smoke_038.py   (after python3 tools/build.py)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import runtime, load_app, load_online, errors  # noqa: E402
import scenarios  # noqa: E402

FAILS = []
OKS = []


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def req(L, name):
    return L.eval(f"(__CHT_REQUIRE__ or require)('{name}')")


def lua_list(t):
    if t is None:
        return []
    return [t[i] for i in range(1, len(t) + 1)]


def draw_all(g):
    s = g.script
    s.windowMain(0.016)
    s.windowHud(0.016)
    s.windowHudSettings(0.016)


def app_mode():
    print('Telepített app:')
    L, g, stub = runtime()
    scenarios.put_layout(g, L)
    load_app(L, g)
    for _ in range(5):
        stub.frameStep(1 / 60)
    app = g.__CHT_APP
    draw_all(g)
    check(not errors(g), 'betöltés és minden fül rajzolása hiba nélkül')
    check(app.version.startswith('0.3.'), 'verzió ' + str(app.version))
    # E01: hotkey toggles the drawings
    vis = L.eval("require('src/visibility')")
    check(vis.masterOn(app.settings) is True, 'pályarajz alapból BE')
    stub.keyPressed['__CHT_DRIFT_JUDGE_ZONES'] = True
    stub.frameStep(1 / 60)
    stub.keyPressed['__CHT_DRIFT_JUDGE_ZONES'] = False
    check(vis.masterOn(app.settings) is False, 'Ctrl+Shift+Z: pályarajz KI')
    check(vis.visible(app.settings, 'zones', True) is False, 'KI állásban a zónák nem látszanak (szerkesztéskor sem)')
    draw_all(g)
    stub.frameStep(1 / 60)
    stub.frameStep(1 / 60)
    app.toggleTrackDraw()
    check(vis.masterOn(app.settings) is True, 'gombbal vissza BE')
    # drive a run: result, sending, deduction
    stub.sent = L.table()
    scenarios.drive(L, g, 60, 45, 2.0, 3)
    res = app.lastResult
    check(res is not None and abs(res.final - 51.961) < 0.01, 'futás pontja egyezik a baseline-nal (51,961)')
    N = app.netsync
    check(len(stub.sent) == 1, 'a futás eredménye kiment a szerverre (1 üzenet)')
    runs = lua_list(N.runs)
    check(len(runs) == 1 and runs[0].own and abs(runs[0].final - res.final) < 0.01, 'a saját futás megjelent a szerver-futások között')
    meta = app.resultMeta
    check(meta is not None and meta.file is not None, 'a mentett futás fájlneve az eredménynél (levonáshoz)')
    app.setDeduction(meta.file, 2.5, 'korrekció az OZ 1-ben')
    d = app.getDeduction(meta.file)
    check(d is not None and d.amount == 2.5, 'bírói levonás beállítva')
    fs = g.__FS
    path = [k for k in fs.keys() if k.endswith('biroi_levonasok.json')]
    check(len(path) == 1 and 'korrekció' in fs[path[0]], 'levonás elmentve (biroi_levonasok.json)')
    Runs = L.eval("require('src/ui_runs')")
    e = lua_list(Runs.entries())[0]
    txt = Runs.scoreText(app, e)
    check(txt.startswith('49.4') or txt.startswith('49,4'), f'Futások lista: pont a levonás után ({txt})')
    srv = [k for k in fs.keys() if k.endswith('szerver_futasok.json')]
    check(len(srv) == 1, 'szerver-futások fájlba mentve')
    # incoming result from another PC
    stub.deliverFrom(1, 'cht.driftjudge.run.v1', L.eval("{ runId = 77, final = 61.2, line = 40, angle = 9, style = 12.2, zero = false, zeroReason = '', layout = 'Teszt', corrections = 1, wallSaves = 0, oneWheel = 0, twoWheel = 0, overRot = 0, duration = 7.5, avgSpeed = 58, maxAngle = 61, appVersion = '0.3.8' }"))
    runs = lua_list(N.runs)
    check(len(runs) == 2 and runs[0].driver == 'Pilóta 1' and abs(runs[0].final - 61.2) < 0.01, 'másik pilóta futása megérkezett')
    stub.deliverFrom(1, 'cht.driftjudge.run.v1', L.eval("{ runId = 77, final = 61.2 }"))
    check(len(lua_list(N.runs)) == 2, 'ugyanaz az üzenet kétszer nem kerül be')
    stub.uiPress['Másolás táblázatként'] = True
    draw_all(g)
    clip = stub.clipboard
    check(clip is not None and 'Pilóta 1' in clip and '61.2' in clip, 'szerver-futások vágólapra (táblázat)')
    # result tab with the deduction
    draw_all(g)
    check(not errors(g), 'rajzolás hiba nélkül a futás után')
    # layout copy button
    stub.clipboard = None
    stub.uiPress['Másolás##'] = None
    ed = L.eval("require('src/editor')")
    stub.uiPress['Másolás'] = True
    ed.drawTab()
    check(stub.clipboard is not None and '"zones"' in stub.clipboard, 'Pálya fül: Másolás – a pályaterv JSON a vágólapon')
    # app heartbeat for the online script
    beat = [v for k, v in stub.connected.items() if 'presence' in k]
    check(len(beat) == 1 and (beat[0].appBeat or 0) > 0, 'a telepített app jelzi, hogy fut (az online változat ezt figyeli)')
    check(stub.glMaxVerts <= 36, f'rajzköteg legfeljebb 36 csúcs ({stub.glMaxVerts})')
    check(not errors(g), 'nincs hiba a naplóban')


def online_base(server_config=None, steam_id=None, with_layout=True, extras=False, storage=None, prepare=None):
    L, g, stub = runtime(online=True, steam_id=steam_id, online_extras=extras)
    if storage:
        for k, v in storage.items():
            stub.storage[k] = v
    cfg = L.table()
    for k, v in (server_config or {'layout': 'Teszt'}).items():
        cfg[k] = v
    stub.serverConfig = cfg
    if with_layout:
        base = 'https://raw.githubusercontent.com/martondavid04-design/cht-drift-judge/main/layouts/'
        stub.webResponses[base + scenarios.TRACK_KEY + '/Teszt.json'] = json.dumps(scenarios.LAYOUT)
        stub.webResponses[base + scenarios.TRACK_KEY + '/index.json'] = json.dumps(['Teszt'])
    if prepare:
        prepare(stub, L)
    load_online(L, g)
    for _ in range(5):
        stub.frameStep(1 / 60)
    return L, g, stub, g.__CHT_APP


def online_mode():
    print('Online (szerverről kapott) változat:')
    L, g, stub, app = online_base(extras=True)
    P = req(L, "src/platform")
    check(P.online is True and app.online is True, 'online módban fut')
    check(app.remote.state == 'ok' and app.layout.name == 'Teszt' and len(lua_list(app.layout.zones)) == 2, 'pályaterv letöltve a GitHubról és betöltve')
    check(any('index.json' in u for u in lua_list(stub.webRequests)), 'a pályatervek listáját is lekérte (index.json)')
    toasts = lua_list(stub.toasts)
    check(len(toasts) == 1 and 'Ctrl+Shift+D' in toasts[0], 'üdvözlő üzenet a gyorsbillentyűkkel')
    extras = lua_list(stub.onlineExtras)
    check(len(extras) == 1 and extras[0].title == 'CHT Drift Judge', 'bejegyzés a CSP chat app menüjében')
    extras[0].ui()
    # main window + HUD by hotkey (0.3.10: both are open after the first join, so the first press closes them)
    def press_both():
        stub.keyPressed['__CHT_DRIFT_JUDGE_MAIN'] = True
        stub.keyPressed['__CHT_DRIFT_JUDGE_HUD'] = True
        stub.frameStep(1 / 60)
        stub.keyPressed['__CHT_DRIFT_JUDGE_MAIN'] = False
        stub.keyPressed['__CHT_DRIFT_JUDGE_HUD'] = False
    if not (app.onlineUI.main is True and app.onlineUI.hud is True):
        press_both()
    else:
        press_both()
        press_both()
    check(app.onlineUI.main is True and app.onlineUI.hud is True, 'Ctrl+Shift+D / Ctrl+Shift+H megnyitja a fő ablakot és a HUD-ot')
    for _ in range(3):
        stub.frameStep(1 / 60)
    check(not errors(g), 'fő ablak és HUD rajzolása hiba nélkül (online)')
    # a run in online mode
    stub.sent = L.table()
    scenarios.drive(L, g, 60, 45, 2.0, 3)
    check(app.lastResult is not None and abs(app.lastResult.final - 51.961) < 0.01, 'online is ugyanaz a pont (51,961)')
    check(len(stub.sent) == 1, 'online: a futás kiment a szerverre')
    check(app.resultMeta.file is not None, 'online: a futás bekerült a menet futásai közé')
    app.setDeduction(app.resultMeta.file, 1.0, 'teszt')
    for _ in range(3):
        stub.frameStep(1 / 60)
    check(not errors(g), 'online: rajzolás hiba nélkül a futás után')
    # nothing is written as a file online
    check(len(list(g.__FS.keys())) == 0, 'online: nem ír fájlt')
    # settings, layout and deductions survive the next session (CSP storage)
    app.toggleTrackDraw()
    app.saveSettings()
    saved = {k: v for k, v in stub.storage.items()}
    check(any(k.startswith('cht_f') for k in saved), 'online: beállítások a CSP tárolóban')
    L2, g2, stub2, app2 = online_base(storage=saved, with_layout=False)
    vis2 = req(L2, "src/visibility")
    check(vis2.masterOn(app2.settings) is False, 'következő belépéskor megmaradt: pályarajz KI')
    check(app2.layout.name == 'Teszt' and len(lua_list(app2.layout.zones)) == 2, 'következő belépéskor megmaradt: a letöltött pályaterv (szerver nélkül is)')
    check(app2.remote.state in ('error', 'none'), 'ha a szerverről nem jön pályaterv, jelzi (Beállítások → Online változat)')
    # 0.3.12: an online save of a shared layout keeps its name; the sync protects it (tests/smoke_0312.py)
    app.dirty = True
    app.saveLayout()
    check(app.layout.name == 'Teszt' and app.dirty is False, 'online mentés: a közös pályaterv a saját nevén mentődik (a szinkron védi, lásd smoke_0312)')
    check(stub.glMaxVerts <= 36, f'online: rajzköteg legfeljebb 36 csúcs ({stub.glMaxVerts})')


def roles():
    print('Szerepek és pontok (online):')
    L, g, stub, app = online_base({'layout': 'Teszt', 'pilotScores': 0, 'judges': '76561198000000001, 76561198000000002'}, steam_id='76561198000000099')
    P = req(L, "src/platform")
    Live = req(L, "src/ui_live")
    check(P.canSeeScores() is False, 'pilotScores = 0: a pilóta nem látja a pontot')
    check(Live.hudEnabled(app, 'last') is False and Live.hudEnabled(app, 'speed') is True, 'HUD: pontmodulok rejtve, a többi marad')
    g.script.windowMain(0)
    check(not errors(g), 'fő ablak pontok nélkül hiba nélkül')
    L, g, stub, app = online_base({'layout': 'Teszt', 'pilotScores': 0, 'judges': '76561198000000001, 76561198000000002'}, steam_id='76561198000000002')
    P = req(L, "src/platform")
    check(P.serverRole() == 'judge' and P.canSeeScores() is True, 'a bírók listáján lévő Steam ID: bíró, látja a pontot')
    L, g, stub, app = online_base({'layout': 'Teszt', 'pilotScores': 0, 'judges': '76561198000000001'})
    P = req(L, "src/platform")
    check(P.steamID() is None and P.canSeeScores() is False, 'ha a CSP nem adja meg a Steam ID-t: pilóta')


def passive():
    print('Telepített app + online script ugyanazon a gépen:')
    L, g, stub, app = online_base()
    key = [k for k in stub.connected.keys() if 'presence' in k]
    check(len(key) == 1, 'az online script figyeli a telepített appot')
    stub.connected[key[0]].appBeat = L.eval('os.clock()')
    stub.sent = L.table()
    L.execute('local t = os.clock() while os.clock() - t < 1.1 do end')  # the check runs once a second
    for _ in range(5):
        stub.frameStep(1 / 60)
    check(app.passive is True, 'fut a telepített app → az online változat csendben marad')
    scenarios.drive(L, g, 60, 45, 2.0, 3)
    check(len(stub.sent) == 0, 'csendes módban nem küld (a telepített app küldi)')


if __name__ == '__main__':
    app_mode()
    online_mode()
    roles()
    passive()
    print(f'\n{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        print('HIBÁK:', FAILS)
        sys.exit(1)
