"""Smoke tests for 0.4.1: cars in the messages by server slot (session ID), the tandem run measured on the
two pilots' own PCs too (and sent to the race director), the broadcaster HUD's bracket and big
qualifying screens, the race director choosing the broadcast screen.

Run: python3 tests/smoke_041.py   (after python3 tools/build.py)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import errors  # noqa: E402
from smoke_038 import online_base, req, lua_list  # noqa: E402
from smoke_040 import app_base, fake_clock, advance, drive_pair, receive_run, sent_with, first, NEW_URL, ME  # noqa: E402

FAILS = []
OKS = []


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def session_ids():
    print('Autók a szerver szerinti azonosítóval (session ID):')
    L, g, stub, app = app_base(cars=3)
    fake_clock(L)
    E = req(L, 'src/event')
    # on this PC: own car 0 = slot 5, car 1 = slot 2, car 2 = slot 9, car 3 = slot 0
    for idx, sid in ((0, 5), (1, 2), (2, 9), (3, 0)):
        stub.cars[idx].sessionID = sid
    check(E.sessionOf(2) == 9 and E.localOf(9) == 2 and E.localOf(5) == 0, 'helyi index ↔ szerver-azonosító (2 ↔ 9, a saját autó 0 ↔ 5)')
    check(E.localOf(33) is None and E.localOf(255) is None, 'ismeretlen azonosító: nincs autó')
    N = req(L, 'src/netsync')
    E.create('Próba')
    receive_run(L, N, 1, 11, 80, 50, 15, 15)
    receive_run(L, N, 2, 21, 70, 45, 13, 12)
    advance(stub, 3)
    first(E.buildBracket(4))
    first(E.arm())
    lives = sent_with(stub, 'cht.driftjudge.evt.v1')
    check(lives[-1].carA == 2 and lives[-1].carB == 9, 'az élő üzenetben a szerver szerinti azonosítók mennek (Pilóta 1 → 2, Pilóta 2 → 9)')
    check(not errors(g), 'hiba nélkül')


def pilot_measures():
    print('A pilóták gépe is méri a tandemet:')
    # the chase pilot's PC (online, no role): its own car is car 0
    L, g, stub, app = online_base(server_config={'layout': 'Teszt', 'pilotScores': 0}, steam_id=ME)
    stub.addCar(2)
    fake_clock(L)
    E = req(L, 'src/event')
    for idx, sid in ((0, 6), (1, 3), (2, 8)):
        stub.cars[idx].sessionID = sid
    check(E.involved() is False, 'pilóta: nincs szerepe')
    L.execute("STUB.hashName = (__CHT_REQUIRE__ or require)('src/event').nameHash('Pilóta 1')")
    # the director (car 1) armed run 1: a = Pilóta 2 (slot 8) leads, b = this PC (slot 6) chases
    msg = {'eventId': 'v20261127-100000', 'rev': 3, 'director': stub.hashName, 'battle': 'r1b1', 'carA': 8, 'carB': 6,
           'lead': 1, 'phase': 1, 'run': 1, 'pair': 1, 'winner': 0, 'screen': 0}
    stub.deliverFrom(1, 'cht.driftjudge.evt.v1', L.table_from(msg))
    check(E.tracker is not None and E.trackMine == 'chase', 'a saját autója a csatában van: ő is méri (chase)')
    check(E.live.a == 'Pilóta 2' and E.live.b == 'Teszt Pilóta', 'a nevek a szerver-azonosítóból (8 → Pilóta 2, 6 → saját)')
    n0 = len(sent_with(stub, 'cht.driftjudge.tmes.v1'))
    drive_pair(L, g, 2, 0)
    ms = sent_with(stub, 'cht.driftjudge.tmes.v1')
    check(len(ms) == n0 + 1, 'a futás végén elküldi a mérését a versenyigazgatónak')
    m = ms[-1] if ms else None
    check(m is not None and m.role == 2 and m.battle == 'r1b1' and m.run == 1 and 0 < m.proxAvg < 3 and m.near > 150,
          'a mérés: chase, 1. futás, közelség átlag %.2f m, 3 m-en belül %s/200' % (m.proxAvg if m else -1, m.near if m else '–'))
    check(E.tracker is None and E.localRuns['r1b1#1'] is not None, 'a saját mérése megmarad ezen a gépen is')
    # a pilot who is not in the battle does not measure
    msg2 = dict(msg, carA=3, carB=8, run=2)
    stub.deliverFrom(1, 'cht.driftjudge.evt.v1', L.table_from(msg2))
    check(E.tracker is None, 'ha nem ő fut, a pilóta gépe nem mér')
    check(not errors(g), 'hiba nélkül')


def director_receives():
    print('A versenyigazgató megkapja a pilóták mérését:')
    L, g, stub, app = app_base(cars=3)
    fake_clock(L)
    E = req(L, 'src/event')
    N = req(L, 'src/netsync')
    E.create('Próba')
    receive_run(L, N, 1, 11, 80, 50, 15, 15)
    receive_run(L, N, 2, 21, 70, 45, 13, 12)
    advance(stub, 3)
    first(E.buildBracket(4))
    b, cur = E.current()
    first(E.arm())

    def meas(run, role, near, prox, fault=0, mapCount=0):
        return L.table_from({'eventId': E.ev.id, 'battle': b.id, 'run': run, 'role': role, 'proxAvg': prox, 'proxMin': 0.5,
                             'near': near, 'weak': 0, 'far': 200 - near, 'contacts': 1 if fault else 0, 'contactT': 4.2 if fault else -999,
                             'fault': fault, 'initDiff': 0.1, 'angleDiff': -2, 'lineDev': 0.4, 'pass': 0, 'mapCount': mapCount,
                             'mColor': 1 if mapCount else 0, 'mKind': 2 if mapCount else 0, 'mFrom': 50 if mapCount else -999,
                             'mTo': 58 if mapCount else -999, 'solo': 61.5, 'soloZero': 0, 'zeroReason': ''})
    # run 1: Pilóta 1 leads, Pilóta 2 chases. The lead's measurement arrives before the run is recorded.
    stub.deliverFrom(1, 'cht.driftjudge.tmes.v1', meas(1, 1, 0, 9.0, mapCount=1))
    drive_pair(L, g, 1, 2)
    runs = lua_list(b.runs)
    r1 = runs[0]
    check(r1.measured is not None and r1.measured.lead is not None and r1.measured.lead.mapCount == 1 and r1.measured.lead.map1.kind == 'brake',
          'a lead gépének mérése (korábban jött) a futáshoz kerül: térkép 1 eltérés (fék)')
    base = r1.summary.chasePts
    # the chase's PC: worse proximity than the director measured → the suggestion follows it
    stub.deliverFrom(2, 'cht.driftjudge.tmes.v1', meas(1, 2, 40, 5.5, fault=2))
    check(r1.measured.chase is not None and abs(r1.measured.chase.near - 0.2) < 1e-6 and r1.measured.chase.fault == 'chase',
          'a chase gépének mérése utólag is megérkezik (3 m-en belül 20%, kontaktus: a chase hibája lehet)')
    pts = E.chasePoints(r1)
    check(pts < base, 'a chase pontjavaslata a chase gépének közelségével számol (%.1f → %.1f)' % (base, pts))
    # someone else's (not in the battle) message does not count; nor the wrong role
    stub.deliverFrom(3, 'cht.driftjudge.tmes.v1', meas(1, 1, 200, 1.0))
    check(r1.measured.lead.proxAvg == 9.0, 'aki nem fut a csatában, annak a mérése nem számít')
    stub.deliverFrom(1, 'cht.driftjudge.tmes.v1', meas(1, 2, 200, 1.0))
    check(abs(r1.measured.chase.near - 0.2) < 1e-6, 'a lead nem küldhet chase-mérést')
    advance(stub, 4)
    evj = None
    for i in range(1, len(stub.webPosts) + 1):
        try:
            body = json.loads(stub.webPosts[i].body)
        except Exception:
            continue
        if body.get('type') == 'event':
            evj = json.loads(body['eventText'])
    fr = evj['bracket']['rounds'][1]['battles'][0]['runs'][0] if evj else {}
    check('measured' in fr and 'chase' in fr['measured'] and 'lead' in fr['measured'], 'a pilóták mérése a közös táblázatba is elmegy')
    UI = req(L, 'src/ui_event')
    UI.setView('battle')
    UI.drawTab(app)
    check(not errors(g), 'a Csata nézet a pilóták mérésével hiba nélkül')


def broadcast_screens():
    print('Közvetítői kép: ágrajz, nagy kvali-táblázat, a versenyigazgató választ:')
    L, g, stub, app = app_base(cars=3)
    fake_clock(L)
    E = req(L, 'src/event')
    N = req(L, 'src/netsync')
    B = req(L, 'src/ui_broadcast')
    E.create('CHT kupa')
    for i in range(1, 4):
        receive_run(L, N, i, 10 + i, 90 - i * 5, 50, 15, 15)
    advance(stub, 3)
    check(B.screen(app) == 'solo', 'kvalifikáció alatt (automatikus): a követett autó és a kvali-táblázat')
    E.setScreen('quali')
    check(B.screen(app) == 'quali', 'a versenyigazgató „Kvali-táblázat”-ot választ: nagy kvali-táblázat')
    B.draw(app, L.eval('vec2(0, 0)'), 1920, 1080)
    E.setScreen('auto')
    first(E.buildBracket(4))
    b, cur = E.current()
    check(B.screen(app) == 'battle', 'kiválasztott csata: párosítás és a két autó')
    E.setWinner(b, 'a', 'teszt')
    check(B.screen(app) == 'battle', 'a döntés után még a csata (a továbbjutó) látszik…')
    advance(stub, 11)
    check(B.screen(app) == 'bracket', '…10 mp múlva az ágrajz')
    B.draw(app, L.eval('vec2(0, 0)'), 1920, 1080)
    E.setScreen('battle')
    check(B.screen(app) == 'battle', 'a versenyigazgató „Csata”-ra állítja: újra a csata')
    app.settings.ui.broadcastScreen = 'bracket'
    check(B.screen(app) == 'bracket', 'a közvetítő saját beállítása (Ágrajz) erősebb, ha nem „a versenyigazgató szerint”')
    app.settings.ui.broadcastScreen = 'director'
    check(not errors(g), 'rajzolás hiba nélkül')
    # a big bracket: 20 drivers → Top 32, every screen draws
    L2, g2, stub2, app2 = app_base(cars=3)
    fake_clock(L2)
    E2 = req(L2, 'src/event')
    Bk = req(L2, 'src/bracket')
    names = L2.table_from(['Pilóta %d' % i for i in range(1, 21)])
    E2.create('Nagy verseny')
    E2.ev.bracket = Bk.build(names, 32)
    E2.ev.phase = 'bracket'
    B2 = req(L2, 'src/ui_broadcast')
    app2.settings.ui.broadcastScreen = 'bracket'
    ok = B2.drawBracket(app2, L2.eval('vec2(0, 0)'), 1.0)
    check(ok is True and not errors(g2), 'Top 32 ágrajz (20 pilóta, bye-okkal) hiba nélkül')
    ok = B2.drawBracket(app2, L2.eval('vec2(0, 0)'), 2560 / 1920)
    check(ok is True and not errors(g2), '2560×1440-en is (arányosan)')
    # online broadcaster PC follows the director's choice from the live message
    L3, g3, stub3, app3 = online_base(server_config={'layout': 'Teszt', 'broadcasters': ME}, steam_id=ME)
    fake_clock(L3)
    E3 = req(L3, 'src/event')
    B3 = req(L3, 'src/ui_broadcast')
    ev = {'format': 'cht-drift-event', 'id': 'vx', 'name': 'CHT kupa', 'rev': 2, 'phase': 'quali', 'director': {'name': 'Pilóta 1'},
          'quali': {'from': '', 'manual': {}, 'table': [{'name': 'Pilóta 1', 'place': 1, 'status': 'ok', 'best': {'final': 77.5}}]}, 'log': []}
    stub3.webResponses[NEW_URL + '?action=event&id=vx'] = json.dumps({'ok': True, 'event': ev})
    L3.execute("STUB.hashName = (__CHT_REQUIRE__ or require)('src/event').nameHash('Pilóta 1')")
    msg = {'eventId': 'vx', 'rev': 2, 'director': stub3.hashName, 'battle': '', 'carA': 255, 'carB': 255, 'lead': 0, 'phase': 0, 'run': 0,
           'pair': 1, 'winner': 0, 'screen': 3}
    stub3.deliverFrom(1, 'cht.driftjudge.evt.v1', L3.table_from(msg))
    advance(stub3, 2)
    check(E3.ev is not None and E3.requestedScreen() == 'quali' and B3.screen(app3) == 'quali', 'a közvetítő gépe követi a versenyigazgató választását (Kvali-táblázat)')
    app3.settings.ui.broadcastHud = True
    stub3.frameStep(1 / 60)
    check(not errors(g3), 'online közvetítői HUD hiba nélkül')


if __name__ == '__main__':
    session_ids()
    pilot_measures()
    director_receives()
    broadcast_screens()
    print()
    print(f'{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        for f in FAILS:
            print('  HIBA:', f)
        sys.exit(1)
