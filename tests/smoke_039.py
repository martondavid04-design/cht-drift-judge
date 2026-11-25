"""Smoke tests for 0.3.9: test data to the Google Sheet (src/upload.lua) and admin-based roles.

Run: python3 tests/smoke_039.py   (after python3 tools/build.py)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import runtime, load_app, errors  # noqa: E402
import scenarios  # noqa: E402
from smoke_038 import online_base, req, draw_all  # noqa: E402

FAILS = []
OKS = []


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def posts(stub):
    return [stub.webPosts[i] for i in range(1, len(stub.webPosts) + 1)]


def bodies(stub, typ=None):
    out = []
    for p in posts(stub):
        b = json.loads(p.body)
        if typ is None or b.get('type') == typ:
            out.append(b)
    return out


def fake_clock(L, up, t=0.0):
    L.execute(f'FAKE_T = {t}')
    up.clockFn = L.eval('function() return FAKE_T end')


def advance(L, g, seconds, frames=2):
    L.execute(f'FAKE_T = FAKE_T + {seconds}')
    for _ in range(frames):
        g.STUB.frameStep(1 / 60)


def app_mode():
    print('Telepített app – adatküldés:')
    L, g, stub = runtime()
    scenarios.put_layout(g, L)
    load_app(L, g)
    app = g.__CHT_APP
    up = app.upload
    fake_clock(L, up)
    for _ in range(3):
        stub.frameStep(1 / 60)
    check(app.version == '0.3.9', 'verzió 0.3.9')
    check(up.stateText() == 'bekapcsolva', 'alapból bekapcsolva (telepített app)')
    check(len(posts(stub)) == 0, 'belépéskor még nem küld (vár, amíg a pályaterv betölt)')
    advance(L, g, 9)
    s = bodies(stub, 'session')
    check(len(s) == 1, 'belépés elküldve egyszer')
    if s:
        b = s[0]
        check(b['key'] == up.key and b['mode'] == 'app' and b['version'] == '0.3.9' and b['driver'] == 'Teszt Pilóta',
              'belépés: kulcs, mód, verzió, név')
        check(isinstance(b.get('caps'), dict) and 'steamIDfn' in b['caps'] and 'checkAdmin' in b['caps'] and 'mouseDelta' in b['caps'],
              'belépés: mit tud a CSP (Steam ID, admin, egér…)')
        check(posts(stub)[0].url == up.url and up.url.startswith('https://script.google.com/macros/s/'), 'a beépített táblázatcímre megy')
        check(json.loads(posts(stub)[0].body) is not None and 'application/json' in str(posts(stub)[0].headers['Content-Type']),
              'JSON törzs, Content-Type: application/json')
    advance(L, g, 30)
    check(len(bodies(stub, 'session')) == 1, 'a belépést nem küldi újra')

    # a finished run
    scenarios.drive(L, g, 60, 45, 2.0, 3)
    advance(L, g, 1)
    runs = bodies(stub, 'run')
    check(len(runs) == 1, 'a befejezett futás elküldve')
    if runs:
        r = runs[0]
        res = app.lastResult
        check(r['tag'] == 'futás' and abs(r['summary']['final'] - res.final) < 1e-6, 'futás: típus és pontszám egyezik')
        check(len(r['record']['samples']) > 100 and r['record']['format'] == 'cht-drift-run', 'futás: a teljes felvétel benne van')
        check(len(r['result']['zones']) > 0 and 'trace' not in r['result'], 'futás: zónák összegzése (nyomvonal nélkül)')
        check(r['layout'] == 'Teszt' and r['runId'].startswith(up.sessionId), 'futás: pályaterv és azonosító')
    check(up.stats.sent == 2 and up.stats.failed == 0 and up.stats.queued == 0, 'statisztika: 2 elküldve, 0 hiba, üres sor')

    # free recording
    app.toggleFreeRecording()
    for _ in range(30):
        stub.frameStep(1 / 60)
    app.toggleFreeRecording()
    advance(L, g, 1)
    check(bodies(stub, 'run')[-1]['tag'] == 'szabad felvétel', 'szabad felvétel is megy (típussal)')

    # retry after a network error
    n0 = len(posts(stub))
    stub.webPostMode = 'error'
    up.debug('error', 'teszt', 'hálózati próba')
    advance(L, g, 0.1)
    check(len(posts(stub)) == n0 + 1 and up.stats.queued == 1, 'hálózati hiba: a tétel a sorban marad')
    check('connection failed' in str(up.stats.lastError), 'a hiba szövege látszik')
    advance(L, g, 1)
    check(len(posts(stub)) == n0 + 1, 'nem próbálja újra azonnal')
    stub.webPostMode = 'ok'
    advance(L, g, 5)
    check(up.stats.queued == 0 and len(posts(stub)) == n0 + 2, '5 mp múlva újrapróbálja, és sikerül')

    # redirect (Apps Script answers 302) = ok
    stub.webPostMode = 'redirect'
    sent0 = up.stats.sent
    up.debug('info', 'teszt', 'átirányítás')
    advance(L, g, 0.1)
    check(up.stats.sent == sent0 + 1 and up.stats.queued == 0, '302-es válasz: elküldöttnek számít')

    # wrong key: no retry
    stub.webPostMode = 'badkey'
    f0, n0 = up.stats.failed, len(posts(stub))
    up.debug('info', 'teszt', 'rossz kulcs')
    advance(L, g, 0.1)
    advance(L, g, 100)
    check(up.stats.failed == f0 + 1 and len(posts(stub)) == n0 + 1 and up.stats.queued == 0, 'rossz kulcs: nem próbálja újra')

    # html answer: retried, then given up after 4 tries
    stub.webPostMode = 'html'
    f0, n0 = up.stats.failed, len(posts(stub))
    up.debug('info', 'teszt', 'html válasz')
    for _ in range(6):
        advance(L, g, 70)
    check(len(posts(stub)) == n0 + 4 and up.stats.failed == f0 + 1 and up.stats.queued == 0, 'hibás válasz: 4 próba után feladja')

    # web.post throws (e.g. too many requests at once)
    stub.webPostMode = 'throw'
    up.debug('info', 'teszt', 'dobás')
    advance(L, g, 0.1)
    check(not errors(g) and up.stats.queued == 1, 'ha a web.post hibát dob: nincs összeomlás, a sorban marad')
    stub.webPostMode = 'ok'
    advance(L, g, 6)
    check(up.stats.queued == 0, '…és később elmegy')

    # no answer at all: timeout, the late answer is ignored
    stub.webPostMode = 'deferred'
    up.debug('info', 'teszt', 'nincs válasz')
    advance(L, g, 0.1)
    late = posts(stub)[-1]
    advance(L, g, 91)
    check(up.stats.queued == 1 and 'nincs válasz' in str(up.stats.lastError), '90 mp válasz nélkül: sikertelen, újrapróba később')
    stub.webPostMode = 'ok'
    sent0 = up.stats.sent
    L.eval('function(p) p.cb(nil, { status = 200, body = \'{"ok":true}\' }) end')(late)
    check(up.stats.sent == sent0, 'a késve érkező választ figyelmen kívül hagyja')
    advance(L, g, 6)
    check(up.stats.queued == 0, '…és az újrapróba sikerül')

    # debug rate limit
    n0 = len(posts(stub))
    up.debug('error', 'ismétlés', 'ugyanaz a hiba')
    up.debug('error', 'ismétlés', 'ugyanaz a hiba')
    advance(L, g, 0.1)
    advance(L, g, 0.1)
    check(len(posts(stub)) == n0 + 1, 'ugyanaz a hiba percenként csak egyszer')

    # queue limits: debug items are dropped first
    stub.webPostMode = 'deferred'
    up.maxQueue = 5
    for i in range(4):
        up.debug('info', 'sor', 'tétel ' + str(i))
    advance(L, g, 0.1)
    app.upload.run(L.eval("{ header = { driver = 'X', time = 'most' }, layoutName = 'Teszt', samples = {} }"))
    for i in range(4, 8):
        up.debug('info', 'sor', 'tétel ' + str(i))
    q = up._queue()
    kinds = [q[i].kind for i in range(1, len(q) + 1)]
    check(len(kinds) == 5 and 'run' in kinds and up.stats.dropped >= 3, 'tele sor: a régi debug tételek mennek ki, a futás marad')
    up._reset()
    up.maxQueue = 40
    stub.webPostMode = 'ok'

    # switched off in Beállítások
    app.settings.ui.uploadData = False
    n0 = len(posts(stub))
    scenarios.drive(L, g, 60, 45, 2.0, 3)
    advance(L, g, 1)
    check(len(posts(stub)) == n0 and up.stateText() == 'kikapcsolva', 'Beállításokban kikapcsolva: semmit nem küld')
    app.settings.ui.uploadData = None

    draw_all(g)
    Settings = req(L, 'src/ui_settings')
    Settings.uploadInfo(app)
    check(not errors(g), 'Beállítások – adatküldés rész rajzolása hiba nélkül')


def online_mode():
    print('Online változat – adatküldés és admin:')
    L, g, stub, app = online_base()
    up = app.upload
    fake_clock(L, up)
    advance(L, g, 9)
    s = bodies(stub, 'session')
    check(len(s) == 1 and s[0]['mode'] == 'online', 'online: belépés elküldve (mód: online)')
    if s:
        check(s[0]['caps']['server']['layout'] == 'Teszt' and s[0]['caps']['remoteLayout']['state'] == 'ok',
              'belépés: a szerver beállításai és a pályaterv letöltése')
    scenarios.drive(L, g, 60, 45, 2.0, 3)
    advance(L, g, 1)
    check(len(bodies(stub, 'run')) == 1, 'online: a futás a táblázatba megy (fájl nélkül is)')
    check(not errors(g), 'online futás hiba nélkül')

    L, g, stub, app = online_base({'layout': 'Teszt', 'upload': 0})
    up = app.upload
    fake_clock(L, up)
    advance(L, g, 9)
    scenarios.drive(L, g, 60, 45, 2.0, 3)
    advance(L, g, 1)
    check(len(posts(stub)) == 0 and up.stateText() == 'a szerver kikapcsolta (upload = 0)', 'upload = 0: semmit nem küld')

    L, g, stub, app = online_base({'layout': 'Teszt', 'uploadUrl': 'https://pelda.hu/gyujto'})
    up = app.upload
    fake_clock(L, up)
    advance(L, g, 9)
    check(len(posts(stub)) == 1 and posts(stub)[0].url == 'https://pelda.hu/gyujto', 'uploadUrl: máshova küldi')

    # admin = judge
    L, g, stub, app = online_base({'layout': 'Teszt', 'pilotScores': 0})
    P = req(L, 'src/platform')
    check(P.serverRole() is None and P.canSeeScores() is False, 'nem admin, nincs Steam ID: pilóta, nem látja a pontot')
    stub.makeAdmin = True
    P.adminCheckAt = 0
    stub.frameStep(1 / 60)
    check(stub.adminChecks >= 1, 'az admin-jogot lekérdezi a szervertől')
    check(P.serverRole() == 'admin' and P.canSeeScores() is True, 'szerveradmin: bíróként látja a pontot')
    g.script.windowMain(0)
    Settings = req(L, 'src/ui_settings')
    Settings.serverInfo(app)
    Settings.uploadInfo(app)
    check(not errors(g), 'admin módban a fő ablak és a Beállítások hiba nélkül')


if __name__ == '__main__':
    app_mode()
    online_mode()
    print(f'\n{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        print('HIBÁK:', FAILS)
        sys.exit(1)
