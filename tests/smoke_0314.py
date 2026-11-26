"""Smoke tests for 0.3.14: spectator mode (judging the car the camera follows), Versenyzők tab (every
competitor's points), bigger / high-contrast editor points, fixes from the client's answers (D20, D26).

Run: python3 tests/smoke_0314.py   (after python3 tools/build.py)
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import runtime, load_app, errors, APP  # noqa: E402
import scenarios  # noqa: E402
from smoke_038 import online_base, req, lua_list, draw_all  # noqa: E402

FAILS = []
OKS = []


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def app_base(ui=None):
    L, g, stub = runtime()
    scenarios.put_layout(g, L)
    if ui is not None:
        g.__FS[scenarios.ROOT + '/settings.json'] = json.dumps({'scoring': {}, 'ui': ui, 'activeLayouts': {scenarios.TRACK_KEY: 'Teszt'}})
    load_app(L, g)
    for _ in range(5):
        stub.frameStep(1 / 60)
    return L, g, stub, g.__CHT_APP


def drive_car(L, g, idx, speed=60, angle=35, xoff=0.0, wobble=0.0, remote_missing=False, dt=1 / 60):
    """Like scenarios.drive, for any car. remote_missing: the car comes without contact data (as a car
    driven on another PC may): empty contact points, surface „grass” (0)."""
    stub = g.STUB
    v = speed / 3.6
    z, t = -10.0, 0.0
    zero = L.eval('function(car) for w = 0, 3 do car.wheels[w].contactPoint:set(0, 0, 0); car.wheels[w].surfaceType = 0 end end')

    def place(x, zz, yaw, spd, a):
        stub.placeCar(idx, x, zz, yaw, spd, a)
        if remote_missing:
            zero(stub.cars[idx])

    while z < 140:
        a = angle + wobble * math.sin(t * 2.0)
        if z < 22:
            a = min(a, angle) * min(1.0, max(0.0, (z + 10) / 25))
        place(xoff, z, -math.radians(a), speed, a)
        stub.frameStep(dt)
        z += v * dt
        t += dt
    for _ in range(30):
        place(xoff, z, 0, 0, 0)
        stub.frameStep(dt)


def run_msgs(stub):
    out = []
    for i in range(1, len(stub.sent) + 1):
        m = stub.sent[i].msg
        if m is not None and m.runId is not None and m.final is not None:
            out.append(m)
    return out


def spectator():
    print('Néző mód (a kamerával követett autó):')
    L, g, stub, app = app_base()
    check(app.settings.ui.carMode == 'auto', 'alapból „Automatikus”: amit a kamera mutat')
    sent0 = len(run_msgs(stub))
    # the camera follows car 1 (another pilot); its contact data is missing, like a remote car's may be
    stub.sim.focusedCar = 1
    stub.frameStep(1 / 60)
    check(app.watchedCar == 1, 'a követett autót figyeli (1-es)')
    Live = req(L, 'src/ui_live')
    check(Live.watchedName(app) == 'Pilóta 1', 'HUD / Élő: „Néző mód – Pilóta 1”')
    drive_car(L, g, 1, remote_missing=True)
    res = app.lastResult
    check(res is not None, 'a követett autó futása elkészül')
    reasons = lua_list(res.zeroReasons) if res is not None else []
    check(res is not None and not res.zeroRun, 'hiányzó kerékadatnál sem nullás (nem „füvön” minden kerék) ' + str(reasons))
    check(res is not None and (res.final or 0) > 0, 'van pontja: ' + (str(round(res.final, 1)) if res is not None else '–'))
    check(len(run_msgs(stub)) == sent0, 'NEM küldi el a pilóta nevében (azt a pilóta saját programja küldi)')
    meta = app.resultMeta
    check(meta.header.driver == 'Pilóta 1' and meta.header.spectated is True and meta.header.judgedBy == 'Teszt Pilóta',
          'a futás fejléce: Pilóta 1, néző gépén, bíráló: Teszt Pilóta')
    Runs = req(L, 'src/ui_runs')
    Runs.invalidate() if Runs.invalidate else None
    entries = lua_list(Runs.entries())
    e = next((x for x in entries if x.driver == 'Pilóta 1'), None)
    check(e is not None and e.spectated is True and e.carIndex == 1 and e.line is not None, 'a futáslistában: néző gépén, autó #1, Line/Angle/Stílus')
    tel = req(L, 'src/telemetry')
    check('wfb' in [tel.fields[i] for i in range(1, len(tel.fields) + 1)], 'a felvételben jelölve, mely kerekek becsültek (wfb)')
    draw_all(g)
    # free camera (no focused car): stays on the followed car
    stub.sim.focusedCar = 1
    stub.frameStep(1 / 60)
    stub.sim.focusedCar = -1
    stub.frameStep(1 / 60)
    check(app.watchedCar == 1, 'szabad kamera (nincs követett autó): marad az eddig követett')
    # back to the own car: the own run is sent as before
    stub.sim.focusedCar = 0
    stub.frameStep(1 / 60)
    check(app.watchedCar == 0, 'kamera vissza a saját autóra → a sajátot figyeli')
    drive_car(L, g, 0)
    check(len(run_msgs(stub)) == sent0 + 1, 'a saját futás elmegy a bíróknak')
    # 'own' keeps the own car even when the camera follows someone else
    app.settings.ui.carMode = 'own'
    stub.sim.focusedCar = 1
    stub.frameStep(1 / 60)
    check(app.watchedCar == 0, '„Mindig a saját autó”: nem vált')
    # a disconnected focused car is not judged
    app.settings.ui.carMode = 'auto'
    stub.cars[1].isConnected = False
    stub.frameStep(1 / 60)
    check(app.watchedCar == 0, 'lecsatlakozott autóra nem vált')
    stub.cars[1].isConnected = True
    check(not errors(g), 'hiba nélkül')


def migration():
    print('Beállítás átállítása (régi „Saját autó” alap):')
    L, g, stub, app = app_base({'carMode': 'own'})
    check(app.settings.ui.carMode == 'auto' and app.settings.ui.carModeAuto is True, 'régi „own” → „auto” egyszer')
    L, g, stub, app = app_base({'carMode': 'own', 'carModeAuto': True})
    check(app.settings.ui.carMode == 'own', 'ha utána szándékosan „own”-ra állították, marad')
    L, g, stub, app = app_base({'carMode': 'focused'})
    check(app.settings.ui.carMode == 'focused', '„focused” marad')


def drivers_tab():
    print('Versenyzők fül:')
    L, g, stub, app = app_base()
    N = req(L, 'src/netsync')
    mk = L.eval('function(t) return t end')

    def receive(idx, run_id, final, line, angle, style, zero=False):
        sender = L.table_from({'index': idx})
        msg = L.table_from({'runId': run_id, 'final': final, 'line': line, 'angle': angle, 'style': style,
                            'zero': zero, 'zeroReason': '2 kerék kint' if zero else '', 'layout': 'Teszt'})
        N.receive(sender, msg)
    # Pilóta 1: 80 and 70; Pilóta 2: 80 and 60 → Pilóta 1 ahead on the second best (C13)
    receive(1, 1, 80, 50, 15, 15)
    receive(1, 2, 70, 45, 13, 12)
    receive(2, 1, 80, 52, 14, 14)
    receive(2, 2, 60, 40, 10, 10)
    # Pilóta 3: 80 and 70 too, but the best run's Line is lower → behind Pilóta 1
    receive(3, 1, 80, 48, 16, 16)
    receive(3, 2, 70, 45, 13, 12)
    receive(3, 3, 0, 0, 0, 0, zero=True)
    D = req(L, 'src/ui_drivers')
    lst = lua_list(D.collect(app))
    names = [d.name for d in lst]
    check(names[:3] == ['Pilóta 1', 'Pilóta 3', 'Pilóta 2'], 'rangsor: legjobb, 2. legjobb, a legjobb Line-ja (C13): ' + ', '.join(names[:3]))
    p3 = next(d for d in lst if d.name == 'Pilóta 3')
    check(p3.count == 3 and p3.zeros == 1, 'Pilóta 3: 3 futás, 1 nullás')
    check('Teszt Pilóta' in names, 'aki fent van, de még nem futott, az is a listában')
    # a judge's deduction on Pilóta 1's best run puts Pilóta 3 ahead
    p1 = next(d for d in lst if d.name == 'Pilóta 1')
    best = p1.best
    key = 'srv:Pilóta 1:' + str(int(best.runId)) + ':' + str(best.time)
    app.setDeduction(key, 5, 'korrekció')
    lst = lua_list(D.collect(app))
    names = [d.name for d in lst]
    check(names[0] == 'Pilóta 3', 'bírói levonás (−5) után Pilóta 3 az első: ' + ', '.join(names[:3]))
    # own run on this PC (installed app) is listed too
    drive_car(L, g, 0)
    lst = lua_list(D.collect(app))
    me = next(d for d in lst if d.name == 'Teszt Pilóta')
    own_runs = lua_list(me.runs)
    check(me.count == 1 and len(own_runs) == 1, 'a saját futás megjelenik, egyszer (a visszakapott üzenet és a helyi mentés nem duplázódik)')
    # drawing, copy as table, follow button
    p = req(L, 'src/ui_common')
    stub.clipboard = None
    stub.uiPress['Másolás táblázatként'] = True
    D.drawTab(app)
    clip = stub.clipboard or ''
    check(clip.startswith('Hely\tPilóta\tLegjobb') and 'Pilóta 3' in clip, 'Másolás táblázatként: TSV a vágólapon')
    stub.uiPress['Követés##fc_Pilóta 1'] = True
    D.drawTab(app)
    check(stub.sim.focusedCar == 1, '„Követés”: a kamera Pilóta 1 autójára vált')
    stub.frameStep(1 / 60)
    check(app.watchedCar == 1, '…és a program őt figyeli')
    stub.sim.focusedCar = 0
    # the tab in the main window
    L.execute("STUB.tabLabels = {}; local o = ui.tabItem; ui.tabItem = function(l, f, fn) STUB.tabLabels[#STUB.tabLabels + 1] = l; return o(l, f, fn) end")
    draw_all(g)
    labels = lua_list(stub.tabLabels)
    check(any('Versenyzők' in str(x) for x in labels), 'telepített app: van Versenyzők fül')
    check(not errors(g), 'hiba nélkül')


def drivers_online():
    print('Versenyzők fül online:')
    hook = "STUB.tabLabels = {}; local o = ui.tabItem; ui.tabItem = function(l, f, fn) STUB.tabLabels[#STUB.tabLabels + 1] = l; return o(l, f, fn) end"
    # pilot on a server where the points are for the judges only → no tab
    L, g, stub, app = online_base({'layout': 'Teszt', 'pilotScores': 0})
    L.execute(hook)
    g.script.windowMain(0.016)
    labels = lua_list(stub.tabLabels)
    check(not any('Versenyzők' in str(x) for x in labels), 'pilóta (pontok rejtve): nincs Versenyzők fül')
    # pilots see their points (pilotScores = 1) → the tab is there
    L, g, stub, app = online_base({'layout': 'Teszt', 'pilotScores': 1})
    L.execute(hook)
    g.script.windowMain(0.016)
    labels = lua_list(stub.tabLabels)
    check(any('Versenyzők' in str(x) for x in labels), 'ha a pontok láthatók: van Versenyzők fül')
    check(not errors(g), 'hiba nélkül')


def editor_points():
    print('Szerkesztő: nagyobb, kontrasztos pontok:')
    L, g, stub, app = app_base()
    L.execute("""
      STUB.circles, STUB.texts = {}, {}
      render.circle = function(pos, dir, r, col) STUB.circles[#STUB.circles + 1] = { r = r, c = col } end
      render.debugText = function(pos, text) STUB.texts[#STUB.texts + 1] = tostring(text) end
    """)
    d3 = req(L, 'src/draw3d')
    schema = req(L, 'src/schema')
    check(schema.byKey.pointSize is not None and schema.uiDefaults.pointSize == 1, 'új beállítás: Zónapontok mérete (alap 1×)')
    z = app.layout.zones[1]
    n = len(z.points)
    opts = L.table_from({'selectedZone': 1, 'showPoints': True, 'pointSize': 2, 'settings': app.settings})
    d3.drawLayout(app.layout, app.compiled, opts)
    circles = lua_list(stub.circles)
    big = [c for c in circles if c.r >= 0.42 * 2 - 1e-6]
    check(len(big) >= n, f'kijelölt zóna: {n} pont, mindegyik talpkorong fekete kerettel (2× méret)')
    texts = lua_list(stub.texts)
    check(all(str(k) in texts for k in range(1, n + 1)), 'a pontok sorszáma kiírva (1…' + str(n) + ')')
    pc = d3.pointColors
    same = L.eval('rawequal')
    check(any(same(c.c, pc.first) for c in circles) and any(same(c.c, pc.last) for c in circles), 'első pont zöld, utolsó lila')
    check(sum(1 for c in circles if same(c.c, pc.ring)) >= n, 'fekete keret minden korong alatt')
    # without render.circle (older CSP): still drawn, no error
    L.execute("rawset(render, 'circle', 5)")
    d3.drawLayout(app.layout, app.compiled, opts)
    check(not errors(g), 'render.circle nélkül is hiba nélkül')


def answers():
    print('Válaszok alapján (D20, D26):')
    L, g, stub, app = app_base()
    Live = req(L, 'src/ui_live')
    items = lua_list(Live.hudItems)
    drive = next(x for x in items if x.key == 'drive')
    check('kipörgés' not in drive.label.lower(), 'D26: a HUD-on nincs kipörgésjelző („' + drive.label + '”)')
    src = open(os.path.join(APP, 'src', 'ui_live.lua'), encoding='utf-8').read()
    check("'Kipörgés'" not in src, 'D26: a kipörgés sáv kikerült a HUD rajzolásból')
    # D20: paint detection hidden unless switched on
    L.execute("""
      STUB.coll = {}
      local U = require('src/ui_common')
      local o = U.collapsible
      U.collapsible = function(id, ...) STUB.coll[#STUB.coll + 1] = id; return o(id, ...) end
    """)
    ed = req(L, 'src/editor')
    L.execute("require('src/ui_common').setOpen('ed_step3', true)")
    ed.drawTab()
    ids = lua_list(stub.coll)
    check('ed_step3' in ids and 'ed_paint' not in ids, 'D20: „Zóna a festésből” alapból rejtve')
    app.settings.ui.showPaintTool = True
    stub.coll = L.table()
    ed.drawTab()
    check('ed_paint' in lua_list(stub.coll), 'Beállításban bekapcsolva megjelenik')
    check(not errors(g), 'hiba nélkül')


if __name__ == '__main__':
    spectator()
    migration()
    drivers_tab()
    drivers_online()
    editor_points()
    answers()
    print(f'\n{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        print('HIBÁK:', FAILS)
        sys.exit(1)
