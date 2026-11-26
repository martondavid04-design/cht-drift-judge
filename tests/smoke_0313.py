"""Smoke tests for 0.3.13: hotkeys (own Ctrl+Shift check + CSP binding), resizing, CSP functions given as cdata.

Run: python3 tests/smoke_0313.py   (after python3 tools/build.py)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import errors  # noqa: E402
from smoke_038 import online_base, req, lua_list  # noqa: E402

FAILS = []
OKS = []
CTRL, SHIFT, ALT = 17, 16, 18


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def keys(stub, L, *codes):
    stub.keysDown = L.table_from({c: True for c in codes})


def step(stub, n=1):
    for _ in range(n):
        stub.frameStep(1 / 60)


def hotkeys():
    print('Gyorsbillentyűk:')
    L, g, stub, app = online_base()
    g.script.drawUI()
    app.setOnlineMain(False, 'teszt')
    app.setOnlineHud(False, 'teszt')
    keys(stub, L, CTRL, SHIFT, ord('D'))
    step(stub)
    check(app.onlineUI.main is True, 'Ctrl+Shift+D megnyitja a fő ablakot (a program maga figyeli)')
    step(stub, 5)
    check(app.onlineUI.main is True, 'nyomva tartva nem kapcsolgat')
    keys(stub, L)
    step(stub)
    keys(stub, L, CTRL, SHIFT, ord('D'))
    step(stub)
    check(app.onlineUI.main is False, 'újra megnyomva bezárja')
    keys(stub, L, CTRL, SHIFT, ord('H'))
    step(stub)
    check(app.onlineUI.hud is True, 'Ctrl+Shift+H: HUD')
    vis = req(L, 'src/visibility')
    before = vis.masterOn(app.settings)
    keys(stub, L, CTRL, SHIFT, ord('Z'))
    step(stub)
    check(vis.masterOn(app.settings) is (not before), 'Ctrl+Shift+Z: pályarajz ki-be')
    keys(stub, L, ord('D'))
    step(stub)
    keys(stub, L, SHIFT, ord('D'))
    step(stub)
    keys(stub, L, CTRL, SHIFT, ALT, ord('D'))
    step(stub)
    check(app.onlineUI.main is False, 'D, Shift+D, Ctrl+Shift+Alt+D nem nyit')
    keys(stub, L)
    step(stub)
    # the CSP binding (here Alt+D, as on preview120) works too
    stub.keyPressed['__CHT_DRIFT_JUDGE_MAIN'] = True
    step(stub)
    stub.keyPressed['__CHT_DRIFT_JUDGE_MAIN'] = False
    check(app.onlineUI.main is True, 'a CSP-ben beállított gomb (pl. Alt+D) is működik')
    # binding = the same Ctrl+Shift+D: one toggle, not two
    keys(stub, L, CTRL, SHIFT, ord('D'))
    stub.keyPressed['__CHT_DRIFT_JUDGE_MAIN'] = True
    step(stub)
    stub.keyPressed['__CHT_DRIFT_JUDGE_MAIN'] = False
    keys(stub, L)
    step(stub)
    check(app.onlineUI.main is False, 'ha a CSP-gomb is Ctrl+Shift+D, egyszer kapcsol (nem kétszer)')
    stub.boundTo = L.table_from({'__CHT_DRIFT_JUDGE_MAIN': 'Alt+D'})
    check(app.hotkeyText('main') == 'Ctrl+Shift+D vagy Alt+D', 'kiírás: „Ctrl+Shift+D vagy Alt+D”')
    stub.boundTo = L.table_from({'__CHT_DRIFT_JUDGE_MAIN': 'Ctrl+Shift+D'})
    check(app.hotkeyText('main') == 'Ctrl+Shift+D', 'ha ugyanaz, csak egyszer írja ki')
    check(not errors(g), 'hiba nélkül')


def resizing():
    print('Átméretezés:')
    L, g, stub, app = online_base()
    L.execute('ui.mouseDelta = nil')  # as if this CSP had none: worked out from ui.mousePos
    g.script.drawUI()
    check(app.onlineUI.main is True, 'fő ablak nyitva')
    size0 = app.settings.ui.onlineMainSize
    w0 = size0[1] if size0 else 980
    stub.mouse = L.eval('vec2(900, 700)')
    g.script.drawUI()
    stub.uiActive = '##grip_chtOnlineMain'
    stub.mouse = L.eval('vec2(840, 650)')
    g.script.drawUI()
    stub.uiActive = None
    size = app.settings.ui.onlineMainSize
    check(size is not None and abs(size[1] - (w0 - 60)) < 1e-6, 'a sarokkal kisebbre húzható (−60 px)')
    # HUD resize while the main window is open
    app.setOnlineHud(True, 'teszt')
    stub.mouse = L.eval('vec2(300, 500)')
    g.script.drawUI()
    stub.uiActive = '##grip_chtOnlineHud'
    stub.mouse = L.eval('vec2(340, 560)')
    g.script.drawUI()
    stub.uiActive = None
    hs = app.settings.ui.onlineHudSize
    check(hs is not None and abs(hs[1] - 300) < 1e-6 and abs(hs[2] - 480) < 1e-6, 'a HUD is átméretezhető, amíg a fő ablak nyitva van')
    check(not errors(g), 'hiba nélkül')


def callable_check():
    print('CSP-függvények „cdata” típussal:')
    L, g, stub, app = online_base()
    F = req(L, 'src/fn')
    cdata = L.eval("require('ffi').new('int[1]')")
    check(F.callable(cdata) is True, 'cdata = meglévő függvény')
    check(F.callable(L.eval('function() end')) is True and F.callable(None) is False and F.callable(5) is False, 'függvény igen, nil / szám nem')
    check(F.callable(L.eval("setmetatable({}, { __call = function() end })")) is True, 'hívható tábla igen')


if __name__ == '__main__':
    hotkeys()
    resizing()
    callable_check()
    print(f'\n{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        print('HIBÁK:', FAILS)
        sys.exit(1)
