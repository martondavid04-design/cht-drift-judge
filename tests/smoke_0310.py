"""Smoke tests for 0.3.10: the online program shows itself on joining.

Run: python3 tests/smoke_0310.py   (after python3 tools/build.py)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import errors  # noqa: E402
from smoke_038 import online_base, req, lua_list  # noqa: E402

FAILS = []
OKS = []


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def draw(g, n=1):
    for _ in range(n):
        g.script.drawUI()


def debug_msgs(stub):
    out = []
    for i in range(1, len(stub.webPosts) + 1):
        b = json.loads(stub.webPosts[i].body)
        if b.get('type') == 'debug':
            out.append(b)
    return out


def first_join():
    print('Első belépés:')
    L, g, stub, app = online_base()
    draw(g)
    check(app.onlineUI.main is True, 'az első belépéskor a fő ablak magától megnyílik')
    check(app.onlineUI.hud is True, 'a HUD alapból látszik')
    check(app.settings.ui.onlineIntroDone == app.version, 'megjegyzi, hogy az első megnyitás megvolt')
    toasts = lua_list(stub.toasts)
    check(len(toasts) == 1 and app.version in toasts[0], 'üdvözlő üzenet a verzióval')
    check(not errors(g), 'hiba nélkül')
    # the next join (settings kept in the CSP storage): main window closed, launcher instead
    app.saveSettings()
    stored = {k: stub.storage[k] for k in stub.storage.keys()}
    L, g, stub, app = online_base(storage=stored)
    draw(g)
    check(app.onlineUI.main is False and app.onlineUI.hud is True, 'következő belépéskor a fő ablak zárva, a HUD látszik')
    stub.uiPress['##chtLauncherBtn'] = True
    draw(g)
    check(app.onlineUI.main is True, 'a képernyő tetején lévő indítógomb megnyitja a fő ablakot')
    draw(g, 2)
    check(not errors(g), 'indítógomb és fő ablak hiba nélkül')
    # HUD switched off stays off
    app.setOnlineHud(False, 'teszt')
    app.saveSettings()
    stored = {k: stub.storage[k] for k in stub.storage.keys()}
    L, g, stub, app = online_base(storage=stored)
    draw(g)
    check(app.onlineUI.hud is False, 'ha a HUD-ot kikapcsolta, kikapcsolva marad')
    # launcher can be switched off
    app.settings.ui.onlineLauncher = False
    draw(g)
    check(not errors(g), 'indítógomb kikapcsolva hiba nélkül')


def diagnostics():
    print('Adatok a táblázatba:')
    L, g, stub, app = online_base()
    up = app.upload
    L.execute('FAKE_T = 0')
    up.clockFn = L.eval('function() return FAKE_T end')
    draw(g)
    stub.keyPressed['__CHT_DRIFT_JUDGE_HUD'] = True
    stub.frameStep(1 / 60)
    stub.keyPressed['__CHT_DRIFT_JUDGE_HUD'] = False
    stub.keyPressed['__CHT_DRIFT_JUDGE_HUD'] = True
    stub.frameStep(1 / 60)
    stub.keyPressed['__CHT_DRIFT_JUDGE_HUD'] = False
    for _ in range(12):
        L.execute('FAKE_T = FAKE_T + 1')
        stub.frameStep(1 / 60)
    msgs = debug_msgs(stub)
    texts = [m.get('where', '') + ': ' + m.get('message', '') for m in msgs]
    check(any(t.startswith('betöltés') for t in texts), 'betöltéskor elküldi, mit tud a CSP a rajzoláshoz (egér, ablakok)')
    load = [m for m in msgs if m.get('where') == 'betöltés']
    if load:
        d = load[0].get('details', {})
        check('mouseDelta' in d and 'hotkeys' in d and d.get('firstJoin') is True, 'betöltés: egér, gyorsbillentyűk, első belépés')
    check(any('fő ablak: első belépés' in t for t in texts), 'elküldi, hogy a fő ablak magától nyílt meg')
    check(any('HUD: gyorsbillentyű' in t for t in texts), 'elküldi, hogy a gyorsbillentyű működött (HUD)')


def dragging():
    print('Ablak mozgatása ui.mouseDelta nélkül:')
    L, g, stub, app = online_base()
    L.execute('ui.mouseDelta = nil')
    draw(g)
    check(app.onlineUI.main is True, 'fő ablak nyitva')
    before = app.settings.ui.onlineMainPos
    bx = before[1] if before else None
    stub.uiActive = '##bar_chtOnlineMain'
    stub.mouse = L.eval('vec2(500, 300)')
    draw(g)
    stub.mouse = L.eval('vec2(540, 320)')
    draw(g)
    stub.uiActive = None
    pos = app.settings.ui.onlineMainPos
    check(pos is not None and (bx is None or pos[1] != bx), 'a fő ablak az egérrel elmozdul (ui.mousePos alapján)')
    if pos is not None:
        p2 = (pos[1], pos[2])
        draw(g, 2)
        p3 = app.settings.ui.onlineMainPos
        check((p3[1], p3[2]) == p2, 'elengedés után ott marad')
    check(not errors(g), 'hiba nélkül')


def old_app():
    print('Régi telepített app ugyanazon a gépen:')
    def old037(st):
        st.installedManifest = '[ABOUT]\nNAME = CHT Drift Judge\nVERSION = 0.3.7\n'
    L, g, stub, app = online_base(prepare=old037)
    P = req(L, 'src/platform')
    check(P.oldInstalledApp() == '0.3.7', 'felismeri a régi (0.3.7) telepített appot')
    draw(g)
    toasts = lua_list(stub.toasts)
    check(len(toasts) == 1 and 'régi telepített' in toasts[0], 'az üdvözlő üzenet figyelmeztet rá')
    check('régi' in str(app.statusMessage) or 'régi' in str(getattr(app, 'statusText', '')), 'a fő ablak állapotsora is figyelmeztet')
    Settings = req(L, 'src/ui_settings')
    Settings.serverInfo(app)
    check(not errors(g), 'Beállítások – telepített app sor hiba nélkül')
    def new0310(st):
        st.installedManifest = '[ABOUT]\nVERSION = 0.3.10\n'
    L, g, stub, app = online_base(prepare=new0310)
    P = req(L, 'src/platform')
    check(P.oldInstalledApp() is None and P.installedAppVersion() == '0.3.10', 'az új telepített appra nem figyelmeztet')
    check(P.versionLess('0.3.9', '0.3.10') and not P.versionLess('0.3.10', '0.3.9'), 'verzió-összehasonlítás (0.3.9 < 0.3.10)')


def no_layout():
    print('Pálya pályaterv nélkül:')
    L, g, stub, app = online_base(with_layout=False)
    stub.frameStep(1 / 60)
    draw(g, 2)
    check(app.remote.state == 'error', 'nincs pályaterv a szerveren → hibaállapot')
    check(not errors(g), 'a figyelmeztetés a fő ablakban és az indítógombon hiba nélkül')


if __name__ == '__main__':
    first_join()
    diagnostics()
    dragging()
    old_app()
    no_layout()
    print(f'\n{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        print('HIBÁK:', FAILS)
        sys.exit(1)
