"""Smoke tests for 0.4.0 (phase 2): qualifying table, Top 32 bracket, tandem battles (proximity, contact,
passing, accel / decel map), the judges' votes and One More Time, the competition between the PCs, the
broadcaster HUD and the Verseny tab.

Run: python3 tests/smoke_040.py   (after python3 tools/build.py)
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenarios  # noqa: E402
from harness import runtime, load_app, errors  # noqa: E402
from smoke_038 import online_base, req, lua_list, draw_all  # noqa: E402

FAILS = []
OKS = []
ME = '76561198011111111'
NEW_URL = 'https://script.google.com/macros/s/AKfycbxOxMCb5AuRvyurK3WEewwNGOe-Ph2O0sSQyPVNW50lKvSznnlXSnU1fc7qmadBkmmasA/exec'


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def first(r):
    return r[0] if isinstance(r, tuple) else r


def strs(t):
    return [str(x) for x in lua_list(t)]


def app_base(cars=3):
    L, g, stub = runtime()
    scenarios.put_layout(g, L)
    load_app(L, g)
    for i in range(2, cars + 1):
        stub.addCar(i)
    for _ in range(5):
        stub.frameStep(1 / 60)
    return L, g, stub, g.__CHT_APP


def fake_clock(L):
    L.execute("""
      local rq = __CHT_REQUIRE__ or require
      STUB.T = 1000
      rq('src/event').clockFn = function() return STUB.T end
      rq('src/upload').clockFn = function() return STUB.T end
      rq('src/netsync').clockFn = function() return STUB.T end
      rq('src/roles').clockFn = function() return STUB.T end
      -- the wall clock follows the fake one too (run times, competition times)
      local od = os.date
      os.date = function(f, t) return od(f, t or (1795000000 + math.floor(STUB.T))) end
    """)


def advance(stub, seconds, step=0.25):
    t = 0.0
    while t < seconds:
        stub.T = stub.T + step
        stub.frameStep(1 / 60)
        t += step


def drive_pair(L, g, lead, chase, gap=6.0, speed=60, angle=40, chase_angle=None, chase_x=2.2, contact_at=None,
               lead_brake_at=None, pass_at=None, lead_slow_at=None):
    """Two cars along the test strip (+z): the lead in front, the chase `gap` m behind (centre to centre)."""
    stub = g.STUB
    place = stub.placeCar
    dt = 1 / 60
    v = speed / 3.6
    z, t = -12.0, 0.0
    while z < 150:
        a = angle + 3 * math.sin(t * 2)
        if z < 22:
            a = a * min(1.0, max(0.0, (z + 12) / 26))
        lead_speed = speed
        stub.cars[lead].brake = 0
        if lead_brake_at and lead_brake_at[0] < z < lead_brake_at[1]:
            stub.cars[lead].brake = 0.8
        if lead_slow_at and lead_slow_at[0] < z < lead_slow_at[1]:
            lead_speed = speed * 0.55
        place(lead, 2.0, z, -math.radians(a), lead_speed, a)
        gz = gap
        if contact_at and contact_at[0] < z < contact_at[1]:
            gz = 1.5
        if pass_at and z > pass_at:
            gz = -7.0
        ca = a if chase_angle is None else chase_angle
        place(chase, chase_x, z - gz, -math.radians(ca), speed, ca)
        if hasattr(stub, 'T') and stub.T is not None:
            stub.T = stub.T + dt
        stub.frameStep(dt)
        z += v * dt
        t += dt
    for _ in range(40):
        place(lead, 2.0, 160, 0, 0, 0)
        place(chase, 2.2, 150, 0, 0, 0)
        if hasattr(stub, 'T') and stub.T is not None:
            stub.T = stub.T + dt
        stub.frameStep(dt)


def receive_run(L, N, idx, run_id, final, line, angle, style, zero=False, time=None):
    sender = L.table_from({'index': idx})
    msg = L.table_from({'runId': run_id, 'final': final, 'line': line, 'angle': angle, 'style': style,
                        'zero': zero, 'zeroReason': '2 kerék kint' if zero else '', 'layout': 'Teszt'})
    N.receive(sender, msg)


def posts_of(stub, kind):
    out = []
    for i in range(1, len(stub.webPosts) + 1):
        p = stub.webPosts[i]
        try:
            body = json.loads(p.body)
        except Exception:
            continue
        if body.get('type') == kind:
            out.append(body)
    return out


def sent_with(stub, part):
    out = []
    for i in range(1, len(stub.sent) + 1):
        e = stub.sent[i]
        if part in str(e.key):
            out.append(e.msg)
    return out


# ------------------------------------------------------------------------------------------------------
def pure_bracket():
    print('Tábla és döntés (tiszta logika):')
    L, g, stub, app = app_base()
    B = req(L, 'src/bracket')
    check(strs(B.seedOrder(8)) == ['1', '8', '4', '5', '2', '7', '3', '6'], 'kiemelési sorrend Top 8: 1–8, 4–5, 2–7, 3–6')
    o32 = [int(x) for x in strs(B.seedOrder(32))]
    check(o32[:4] == [1, 32, 16, 17] and sorted(o32) == list(range(1, 33)), 'Top 32: 1–32, 16–17 …, mind a 32 hely egyszer')
    check(B.sizeFor(5) == 8 and B.sizeFor(17) == 32 and B.sizeFor(40) == 32 and B.sizeFor(3) == 4, 'táblaméret: 5 → 8, 17 → 32, 40 → 32 (legfeljebb Top 32)')
    seeds = L.table_from(['A', 'B', 'C', 'D', 'E'])
    br = B.build(seeds, 8)
    r1 = lua_list(br.rounds[1].battles)
    byes = [b for b in r1 if b.bye]
    check(len(byes) == 3 and all(B.winnerName(b) in ('A', 'B', 'C') for b in byes), 'bye-ok a 3 legjobbnak (A, B, C), ellenfél nélkül tovább')
    nb = B.nextBattle(br)
    check(nb is not None and {nb.a, nb.b} == {'D', 'E'}, 'az első futtatandó csata: D – E (4–5)')
    r2 = lua_list(br.rounds[2].battles)
    check(r2[0].a == 'A' and r2[1].a == 'B' and r2[1].b == 'C', '2. kör: A a D–E győztesére vár, B – C kész párosítás')
    nb.winner = 'b'
    B.propagate(br)
    check(r2[0].b == 'E' and r2[0].seedB == 5, 'a győztes (E, 5. kiemelt) továbbmegy')
    v = L.table_from({'j1': 'a', 'j2': 'a'})

    def dec(*a):
        r = B.decide(*a)
        return r[0] if isinstance(r, tuple) else r
    check(dec(v, 2, False) == 'a', 'két egyező szavazat: A nyer')
    check(dec(L.table_from({'j1': 'a', 'j2': 'b'}), 2, False) == 'omt', 'eltérő szavazat: One More Time')
    check(dec(L.table_from({'j1': 'a', 'j2': 'b'}), 2, True) == 'deadlock', 'OMT után is eltérő: dönteni kell (versenyigazgató)')
    check(dec(L.table_from({'j1': 'a'}), 2, False) == 'pending', 'egy szavazat a kettőből: még vár')
    check(dec(L.table_from({'j1': 'omt', 'j2': 'omt'}), 2, False) == 'omt', 'mindkét bíró OMT-t kér')
    # qualifying table
    mk = L.eval('function(t) return t end')

    def drv(name, runs):
        return {'name': name, 'runs': [dict(r) for r in runs]}
    data = [
        drv('P1', [{'final': 80, 'line': 50, 'angle': 15, 'style': 15, 'time': '2026.11.27. 10:00:01'},
                   {'final': 70, 'line': 45, 'angle': 13, 'style': 12, 'time': '2026.11.27. 10:05:01'},
                   {'final': 99, 'line': 60, 'angle': 20, 'style': 19, 'time': '2026.11.27. 10:09:01'}]),
        drv('P2', [{'final': 80, 'line': 52, 'angle': 14, 'style': 14, 'time': '2026.11.27. 10:01:01'},
                   {'final': 60, 'line': 40, 'angle': 10, 'style': 10, 'time': '2026.11.27. 10:06:01'}]),
        drv('P3', [{'final': 0, 'zero': True, 'time': '2026.11.27. 10:02:01'}, {'final': 0, 'zero': True, 'time': '2026.11.27. 10:07:01'}]),
        drv('P4', []),
    ]
    lua_data = L.eval('function(s) return JSON.parse(s) end')(json.dumps(data))
    rows = lua_list(B.qualiTable(lua_data, L.table()))
    names = [r.name for r in rows]
    check(names[:2] == ['P1', 'P2'], 'kvali: a 3. futás nem számít (P1 99-es köre nélkül is első a 2. futás miatt)')
    p1 = rows[0]
    check(p1.best.final == 80 and p1.second.final == 70 and p1.all == 3 and len(lua_list(p1.counted)) == 2, 'P1: legjobb 80, második 70 (2 számít a 3-ból)')
    p3 = next(r for r in rows if r.name == 'P3')
    check(p3.status == 'out' and p3.place is None, 'két nullás kör: kiesett (nincs helyezés)')
    p4 = next(r for r in rows if r.name == 'P4')
    check(p4.status == 'norun', 'még nem futott')
    man = L.eval('function(s) return JSON.parse(s) end')(json.dumps({'P1': {'third': True}, 'P3': {'back': True}}))
    rows = lua_list(B.qualiTable(lua_data, man))
    p1 = next(r for r in rows if r.name == 'P1')
    check(p1.best.final == 99 and p1.third, '3. esély: a 3. futás is számít (99)')
    p3 = next(r for r in rows if r.name == 'P3')
    check(p3.status == 'ok', '„Mégis továbbjut”: két nullás ellenére a rangsorban')
    txt = B.challongeText(L.table_from(['P1', 'P2']))
    check(txt == 'P1\nP2', 'Challonge lista: soronként egy név, kiemelési sorrendben')
    check(not errors(g), 'hiba nélkül')


def tandem_runs():
    print('Tandem mérés:')
    L, g, stub, app = app_base()
    T = req(L, 'src/tandem')
    cars = L.table_from({'lead': 1, 'chase': 2, 'leadName': 'Pilóta 1', 'chaseName': 'Pilóta 2'})

    def run(**kw):
        tr = T.new(cars, app.compiled, app.cfg)
        place = stub.placeCar
        dt = 1 / 60
        speed = kw.get('speed', 60)
        v = speed / 3.6
        z, t = -12.0, 0.0
        gap = kw.get('gap', 6.0)
        while z < 150 and tr.state != 'done':
            a = 40 + 3 * math.sin(t * 2)
            if z < 22:
                a = a * min(1.0, max(0.0, (z + 12) / 26))
            ls = speed
            stub.cars[1].brake = 0
            if kw.get('lead_brake') and kw['lead_brake'][0] < z < kw['lead_brake'][1]:
                stub.cars[1].brake = 0.9
            if kw.get('lead_slow') and kw['lead_slow'][0] < z < kw['lead_slow'][1]:
                ls = speed * 0.5
            la = a
            if kw.get('lead_straight') and kw['lead_straight'][0] < z < kw['lead_straight'][1]:
                la = 2
            place(1, 2.0, z, -math.radians(la), ls, la)
            gz = gap
            if kw.get('contact') and kw['contact'][0] < z < kw['contact'][1]:
                gz = 1.5
            if kw.get('pass_at') and z > kw['pass_at']:
                gz = -7.0
            ca = kw.get('chase_angle', a)
            if kw.get('opposite'):
                ca = a
            place(2, kw.get('chase_x', 2.2), z - gz, (math.radians(ca) if kw.get('opposite') else -math.radians(ca)), speed, -ca if kw.get('opposite') else ca)
            tr.update(tr, dt, None)
            z += v * dt
            t += dt
        for _ in range(700):
            if tr.state == 'done':
                break
            place(1, 2.0, 160, 0, 0, 0)
            place(2, 2.2, 152, 0, 0, 0)
            tr.update(tr, dt, None)
        return tr
    tr = run()
    s = tr.summary
    check(tr.state == 'done' and s is not None, 'a futás magától lezárul (mindkét autó áthaladt a FINISH-en)')
    p = s.prox
    check(p.avg is not None and 0.5 < p.avg < 3 and p.near > 0.95, 'közelség: átlag %.2f m, 3 m-en belül %.0f%%' % (p.avg or -1, (p.near or 0) * 100))
    check(len(lua_list(s.contacts)) == 0 and s['pass'] is None, 'nincs kontaktus, nincs előzés')
    lr = s.leadResult
    check(lr is not None and abs(s.leadPts - 0.6 * lr.final) < 0.11, 'lead javaslat = a solo pont 60%%-a (%.1f / %.1f)' % (s.leadPts, lr.final))
    check(0 < s.chasePts <= 40, 'chase javaslat 0–40 között (%.1f)' % s.chasePts)
    check(s.init.late is False and s.init.diff is not None, 'indítás: a chase nem később indított')
    check(not lua_list(s.incomplete.lead) and not lua_list(s.incomplete.chase), 'nincs incomplete')
    # far chase: weak / far share
    tr = run(gap=10.0)
    p = tr.summary.prox
    check(p.avg > 4 and p.far > 0.5 and tr.summary.chasePts < s.chasePts, 'messze lévő chase: 4 m fölött, kevesebb javasolt pont (%.1f)' % tr.summary.chasePts)
    # contact: the chase runs into a lead that keeps its drift and speed → chase's fault
    tr = run(contact=(60, 64))
    cs = lua_list(tr.summary.contacts)
    check(len(cs) == 1 and cs[0].leadFault is False, 'kontaktus: a lead tartotta a driftet → a chase hibája lehet')
    # contact after the lead slowed down sharply → lead's fault
    tr = run(contact=(62, 66), lead_slow=(58, 70))
    cs = lua_list(tr.summary.contacts)
    reasons = ' '.join(strs(cs[0].reasons)) if cs else ''
    check(len(cs) >= 1 and cs[0].leadFault is True and 'lassított' in reasons, 'kontaktus hirtelen lassítás után: a lead hibája lehet (' + reasons + ')')
    # passing
    tr = run(pass_at=90)
    check(tr.summary['pass'] is not None and any('megelőzte' in x for x in strs(tr.summary.warnings.chase)), 'előzés: jelzi (a bírók döntik el, szabályos volt-e)')
    # lead stops drifting
    tr = run(lead_straight=(60, 95))
    check(any('abbahagyta' in x for x in strs(tr.summary.incomplete.lead)), 'a lead abbahagyta a driftet: incomplete javaslat')
    # the live numbers
    tr = T.new(cars, app.compiled, app.cfg)
    stub.placeCar(1, 2.0, 5, 0, 60, 30)
    stub.placeCar(2, 2.2, 0, 0, 60, 30)
    tr.update(tr, 1 / 60, None)
    lv = tr.live(tr)
    check(lv is not None and lv.prox is not None and lv.state == 'armed', 'élő adat: közelség már a rajt előtt, állapot „armed”')
    check(not errors(g), 'hiba nélkül')


def decel_map():
    print('Gyorsítási / lassítási térkép:')
    L, g, stub, app = app_base()
    M = req(L, 'src/decelmap')
    d = L.eval('function(s) return JSON.parse(s) end')(json.dumps({'path': [{'x': 2, 'y': 0, 'z': z} for z in range(-10, 151, 2)], 'segments': []}))
    M.addSegment(d, 'green', 20, 120)
    M.addSegment(d, 'red', 60, 70)
    segs = [(s.color, s['from'], s.to) for s in lua_list(d.segments)]
    check(segs == [('green', 20, 60), ('red', 60, 70), ('green', 70, 120)], 'átfedő szakasz: a régi kettéválik (zöld 20–60, piros 60–70, zöld 70–120)')
    app.layout.decelMap = d
    app.recompile()
    check(app.compiled.decel is not None and abs(app.compiled.decel.length - 160) < 0.5, 'a pályaterv lefordítva (160 m útvonal)')
    T = req(L, 'src/tandem')
    cars = L.table_from({'lead': 1, 'chase': 2, 'leadName': 'Pilóta 1', 'chaseName': 'Pilóta 2'})
    tr = T.new(cars, app.compiled, app.cfg)
    dt, z, t = 1 / 60, -12.0, 0.0
    while z < 150 and tr.state != 'done':
        a = 40 if z > 22 else 40 * max(0.0, (z + 12) / 34)
        stub.cars[1].brake = 0.9 if 40 < z < 48 else 0
        stub.placeCar(1, 2.0, z, -math.radians(a), 60, a)
        stub.placeCar(2, 2.2, z - 6, -math.radians(a), 60, a)
        tr.update(tr, dt, None)
        z += 60 / 3.6 * dt
        t += dt
    for _ in range(700):
        if tr.state == 'done':
            break
        tr.update(tr, dt, None)
    stub.cars[1].brake = 0
    vs = lua_list(tr.summary.map.violations)
    check(tr.summary.map.has and len(vs) >= 1 and vs[0].color == 'green' and vs[0].kind == 'brake', 'fék a zöld szakaszon: jelzi a lead futásában')
    check('ZÖLD' in M.violationText(vs[0]) if vs else False, 'szöveg: ' + (M.violationText(vs[0]) if vs else '–'))
    # saved with the layout, read back
    layoutMod = req(L, 'src/layout')
    txt = L.eval('function(l) return JSON.stringify(l) end')(app.layout)
    back = layoutMod.sanitize(L.eval('function(s) return JSON.parse(s) end')(txt))
    if isinstance(back, tuple):
        back = back[0]
    check(back.decelMap is not None and len(lua_list(back.decelMap.segments)) == 3 and back.decelMap.path[1].y == 0, 'mentés és visszaolvasás: útvonal (magassággal) és 3 szakasz')
    # editor step 6 draws, the 3D ribbon draws
    stub.uiPress['Útvonal a legutóbbi futásból'] = True
    ed = req(L, 'src/editor')
    ed.drawTab()
    D3 = req(L, 'src/draw3d')
    D3.drawDecelMap(app.layout.decelMap.path, app.compiled.decel, True)
    check(not errors(g), 'a Pálya fül 6. lépése és a pályarajz hiba nélkül')


def competition_director():
    print('Verseny a versenyigazgató gépén (telepített app):')
    L, g, stub, app = app_base(cars=3)
    fake_clock(L)
    E = req(L, 'src/event')
    N = req(L, 'src/netsync')
    check(E.canDirect() is True, 'a telepített app vezetheti a versenyt')
    ev = E.create('CHT próba')
    check(ev.phase == 'quali' and ev.director.name == 'Teszt Pilóta' and E.isDirector(), 'új verseny: kvalifikáció, te vagy a versenyigazgató')
    receive_run(L, N, 1, 11, 80, 50, 15, 15)
    receive_run(L, N, 2, 21, 75, 48, 14, 13)
    receive_run(L, N, 1, 12, 70, 45, 13, 12)
    receive_run(L, N, 2, 22, 0, 0, 0, 0, zero=True)
    advance(stub, 3)
    rows = lua_list(E.qualiTable())
    ok_rows = [r for r in rows if r.status == 'ok']
    check([r.name for r in ok_rows][:2] == ['Pilóta 1', 'Pilóta 2'], 'kvali-táblázat a pilóták gépéről jött futásokból: ' + ', '.join(r.name for r in ok_rows))
    advance(stub, 4)
    posts = posts_of(stub, 'event')
    check(len(posts) >= 1, 'a verseny elmegy a közös táblázatba (type = event)')
    last = posts[-1]
    evj = json.loads(last['eventText'])
    check(evj['id'] == ev.id and evj['format'] == 'cht-drift-event' and len(evj['quali']['table']) >= 2, 'a küldött verseny: azonosító, kvali-táblázat (%d sor)' % len(evj['quali']['table']))
    check(g.__FS[app_root(L) + '/versenyek/' + ev.id + '.json'] is not None, 'a gépen is elmentve (versenyek/<id>.json)')
    # bracket of 2 → Top 4 with byes, final Pilóta 1 – Pilóta 2
    sizes = [int(x) for x in strs(E.sizesFor(2))]
    check(sizes == [4], 'táblaméret 2 továbbjutóval: csak Top 4 (%s)' % sizes)
    ok = first(E.buildBracket(4))
    check(ok is True and ev.phase == 'bracket', 'tábla összeállítva (Top 4)')
    b, cur = E.current()
    check(b is not None and {b.a, b.b} == {'Pilóta 1', 'Pilóta 2'} and b.round == 2, 'az első csata a döntő (a többi bye): Pilóta 1 – Pilóta 2')
    check(b.firstLead == 'a' and b.a == 'Pilóta 1', 'alapból a jobb kvalifikációs (Pilóta 1) vezet először')
    ev.judges = L.table_from(['Teszt Pilóta', 'Pilóta 3'])
    ok = first(E.arm())
    check(ok is True and E.tracker is not None, 'élesítés: 1. futás, Pilóta 1 vezet')
    lives = sent_with(stub, 'cht.driftjudge.evt.v1')
    check(len(lives) >= 1 and lives[-1].phase == 1 and lives[-1].carA == 1 and lives[-1].carB == 2 and lives[-1].lead == 1,
          'élő üzenet a többi gépnek: csata, autók (1, 2), ki vezet, „élesítve”')
    drive_pair(L, g, 1, 2)
    runs = lua_list(b.runs)
    check(len(runs) == 1 and runs[0].lead == 'Pilóta 1' and runs[0].summary.prox.avg is not None, '1. futás rögzítve (közelség, pontjavaslat)')
    check(E.tracker is not None and cur.leadSide == 'b' and cur.state == 'armed', 'a 2. futás magától élesedett: Pilóta 2 vezet')
    # the chase's own result arrives a moment later: added to run 1 (not to run 2)
    receive_run(L, N, 2, 31, 66, 44, 12, 10)
    advance(stub, 3)
    co = runs[0].chaseOwn
    check(co is not None and abs(co.final - 66) < 1e-6, 'a chase saját gépének eredménye utólag is az 1. futáshoz kerül (66)')
    drive_pair(L, g, 2, 1)
    runs = lua_list(b.runs)
    check(len(runs) == 2 and runs[1].lead == 'Pilóta 2' and cur.state == 'voting', '2. futás rögzítve → szavazás')
    # a deduction from a judge's PC (A16)
    stub.deliverFrom(3, 'cht.driftjudge.tded.v1', L.table_from({'eventId': ev.id, 'battle': b.id, 'run': 1, 'target': 2, 'amount': 3, 'note': 'kontakt'}))
    check(E.deductionTotal(runs[0], 'chase') == 3, 'levonás a bíró gépéről: 1. futás, chase −3 „kontakt”')
    # votes: own (director) and Pilóta 3's (judge) → different → One More Time
    E.vote('a')
    stub.deliverFrom(3, 'cht.driftjudge.vote.v1', L.table_from({'eventId': ev.id, 'battle': b.id, 'pair': 1, 'vote': 2}))
    check(b.omt is True and b.winner is None and cur.state == 'idle', 'eltérő szavazat → One More Time')
    check(E.nextLead(b) == 'a', 'az OMT-ben is Pilóta 1 vezet először')
    # a vote from a non-judge is refused
    stub.addCar(4)
    stub.deliverFrom(4, 'cht.driftjudge.vote.v1', L.table_from({'eventId': ev.id, 'battle': b.id, 'pair': 2, 'vote': 1}))
    check(len(lua_list(E.votesOf(b, 2))) == 0 and next((m for m in lua_list(E.messages) if 'elutasítva' in str(m.text)), None) is not None, 'nem bíró szavazata nem számít')
    E.arm()
    drive_pair(L, g, 1, 2)
    drive_pair(L, g, 2, 1)
    check(len(lua_list(b.runs)) == 4 and cur.state == 'voting', 'OMT: még két futás → szavazás')
    check(first(E.vote('omt')) is False, 'az OMT után nem lehet újra OMT-t kérni (DM 1.11)')
    E.vote('b')
    stub.deliverFrom(3, 'cht.driftjudge.vote.v1', L.table_from({'eventId': ev.id, 'battle': b.id, 'pair': 2, 'vote': 2}))
    check(b.winner == 'b' and ev.phase == 'done', 'két B szavazat: Pilóta 2 nyert, ő a győztes (vége)')
    B = req(L, 'src/bracket')
    check(B.champion(ev.bracket) == 'Pilóta 2', 'a tábla győztese: Pilóta 2')
    sug = E.suggestion(b)
    check(sug['Pilóta 1'] is not None and sug['Pilóta 1'].total > 0, 'pontjavaslat csatánként (lead + chase)')
    # undo, then the director decides by hand
    ok = first(E.undoDecision(b.id))
    check(ok is True and b.winner is None and ev.phase == 'bracket', 'döntés visszavonása')
    E.setWinner(b, 'a', 'versenyigazgató döntése')
    check(b.winner == 'a' and b.decision.how == 'versenyigazgató döntése', 'kézi döntés (versenyigazgató)')
    log = lua_list(ev.log)
    check(len(log) > 10 and any('nyert' in str(x.text) for x in log), 'napló: minden döntés benne van (%d sor)' % len(log))
    res = E.resultsText()
    check(res.startswith('Kör\tCsata') and 'Pilóta 1' in res, 'eredmények táblázatként')
    advance(stub, 4)
    evj = json.loads(posts_of(stub, 'event')[-1]['eventText'])
    final = evj['bracket']['rounds'][1]['battles'][0]
    check(final['winner'] == 'a' and len(final['runs']) == 4 and 'votes' in final, 'a közös táblázatba a csata minden futása, szavazata és a döntés is elmegy')
    size = len(posts_of(stub, 'event')[-1]['eventText'])
    check(size < 60000, 'a mentett verseny kicsi (%d bájt, mért sorozatok nélkül)' % size)
    # the Verseny tab, all views
    UI = req(L, 'src/ui_event')
    for v in ('quali', 'bracket', 'battle', 'log'):
        UI.setView(v)
        UI.drawTab(app)
    draw_all(g)
    check(not errors(g), 'a Verseny fül minden nézete hiba nélkül')
    # reopening after a restart of the program: it is read back from the PC
    # restart of the program: a finished competition stays on the PC (listed), an unfinished one comes back by itself
    E._reset()
    E.init(app)
    lst = lua_list(E.list())
    check(E.ev is None and any(x.id == ev.id for x in lst), 'újraindulás után: a befejezett verseny a listában (nem nyílik meg magától)')
    path = app_root(L) + '/versenyek/' + ev.id + '.json'
    saved = json.loads(g.__FS[path])
    saved['phase'] = 'bracket'
    g.__FS[path] = json.dumps(saved)
    E._reset()
    E.init(app)
    check(E.ev is not None and E.ev.id == ev.id and E.isDirector(), 'a félbemaradt verseny újraindulás után magától visszajön (folytatható)')


def app_root(L):
    return str(L.eval("(__CHT_REQUIRE__ or require)('src/storage').root()"))


def competition_follower():
    print('Verseny a bíró / közvetítő gépén (online, követés):')
    L, g, stub, app = online_base(server_config={'layout': 'Teszt', 'judges': ME}, steam_id=ME)
    stub.addCar(2)
    stub.addCar(3)
    fake_clock(L)
    E = req(L, 'src/event')
    check(E.myRole() == 'judge' and E.involved(), 'bíró szerep (a szerver listájáról)')
    # the director's competition (as the store gives it back)
    evdata = {
        'format': 'cht-drift-event', 'version': 1, 'id': 'v20261127-100000', 'name': 'CHT próba', 'rev': 7, 'phase': 'bracket',
        'layout': 'Teszt', 'director': {'name': 'Pilóta 1'}, 'judgeCount': 2, 'judges': ['Teszt Pilóta'],
        'quali': {'from': '', 'manual': {}, 'table': [{'name': 'Pilóta 2', 'place': 1, 'status': 'ok', 'best': {'final': 80}},
                                                     {'name': 'Pilóta 3', 'place': 2, 'status': 'ok', 'best': {'final': 70}}]},
        'seeds': ['Pilóta 2', 'Pilóta 3'],
        'bracket': {'size': 2, 'rounds': [{'name': 'Döntő', 'battles': [{'id': 'r1b1', 'round': 1, 'slot': 1, 'a': 'Pilóta 2', 'b': 'Pilóta 3',
                                                                        'seedA': 1, 'seedB': 2, 'runs': [], 'votes': {}, 'omt': False}]}]},
        'current': {'battle': 'r1b1', 'state': 'armed', 'run': 1, 'leadSide': 'a'}, 'log': [],
    }
    url = NEW_URL + '?action=event&id=v20261127-100000'
    stub.webResponses[url] = json.dumps({'ok': True, 'event': evdata})
    L.execute("STUB.hashName = (__CHT_REQUIRE__ or require)('src/event').nameHash('Pilóta 1')")
    msg = {'eventId': 'v20261127-100000', 'rev': 7, 'director': stub.hashName, 'battle': 'r1b1', 'carA': 2, 'carB': 3,
           'lead': 1, 'phase': 1, 'run': 1, 'pair': 1, 'winner': 0}
    stub.deliverFrom(1, 'cht.driftjudge.evt.v1', L.table_from(msg))
    check(E.live is not None and E.live.a == 'Pilóta 2' and E.live.b == 'Pilóta 3' and E.live.leadSide == 'a', 'élő üzenet: Pilóta 2 – Pilóta 3, Pilóta 2 vezet (nevek az autókból)')
    check(E.tracker is not None, 'a bíró gépe is méri az élesített futást')
    advance(stub, 2)
    check(E.ev is not None and E.ev.id == 'v20261127-100000' and not E.isDirector(), 'a verseny letöltve a táblázatból (követés, nem ő vezeti)')
    drive_pair(L, g, 2, 3)
    key = 'r1b1#1'
    check(E.localRuns[key] is not None and E.localRuns[key].prox.avg is not None, 'a futás ezen a gépen mérve is megvan (amíg a versenyigazgatóé meg nem érkezik)')
    # vote from this PC → goes to the director
    msg['phase'] = 4
    stub.deliverFrom(1, 'cht.driftjudge.evt.v1', L.table_from(msg))
    n0 = len(sent_with(stub, 'cht.driftjudge.vote.v1'))
    ok = first(E.vote('b'))
    votes = sent_with(stub, 'cht.driftjudge.vote.v1')
    check(ok is True and len(votes) == n0 + 1 and votes[-1].vote == 2 and votes[-1].battle == 'r1b1', 'szavazat: elküldve a versenyigazgatónak (B nyert)')
    ok = first(E.sendDeduction('r1b1', 1, 'lead', 2.5, 'lassított'))
    d = sent_with(stub, 'cht.driftjudge.tded.v1')
    check(ok is True and len(d) == 1 and abs(d[-1].amount - 2.5) < 1e-6 and d[-1].target == 1, 'levonás elküldve (lead −2,5)')
    # broadcaster HUD on this PC (online: full screen window) – tandem and qualifying
    app.settings.ui.broadcastHud = True
    L.execute("STUB.twin = {}; local o = ui.transparentWindow; ui.transparentWindow = function(id, p, s, a, b, fn) STUB.twin[#STUB.twin + 1] = id; return o(id, p, s, a, b, fn) end")
    stub.frameStep(1 / 60)
    check('chtBroadcastHud' in strs(stub.twin), 'közvetítői HUD: teljes képernyős ablak')
    msg['phase'] = 5
    msg['winner'] = 1
    stub.deliverFrom(1, 'cht.driftjudge.evt.v1', L.table_from(msg))
    stub.frameStep(1 / 60)
    E.live = None
    stub.frameStep(1 / 60)
    check(not errors(g), 'a közvetítői HUD (tandem, győztes, kvali) hiba nélkül')
    # someone else took over: the director hash changes → still a follower; the tab draws
    UI = req(L, 'src/ui_event')
    for v in ('quali', 'bracket', 'battle', 'log'):
        UI.setView(v)
        UI.drawTab(app)
    check(not errors(g), 'a Verseny fül követőként hiba nélkül')


def follower_late_join():
    print('Később belépő közvetítő: megkeresi a futó versenyt:')
    L, g, stub, app = online_base(server_config={'layout': 'Teszt', 'broadcasters': ME}, steam_id=ME)
    fake_clock(L)
    E = req(L, 'src/event')
    check(E.myRole() == 'streamer' and E.involved(), 'közvetítő szerep')
    lst = {'ok': True, 'events': [{'id': 'vold', 'name': 'régi', 'phase': 'done', 'updated': '2026-11-20 10:00:00'},
                                  {'id': 'vnew', 'name': 'CHT kupa', 'phase': 'quali', 'updated': '2026-11-27 10:00:00'}]}
    stub.webResponses[NEW_URL + '?action=events&track=' + scenarios.TRACK_KEY] = json.dumps(lst)
    ev = {'format': 'cht-drift-event', 'id': 'vnew', 'name': 'CHT kupa', 'rev': 3, 'phase': 'quali', 'director': {'name': 'Pilóta 1'},
          'quali': {'from': '', 'manual': {}, 'table': [{'name': 'Pilóta 1', 'place': 1, 'status': 'ok', 'best': {'final': 77.5}}]}, 'log': []}
    stub.webResponses[NEW_URL + '?action=event&id=vnew'] = json.dumps({'ok': True, 'event': ev})
    advance(stub, 16)
    check(E.ev is not None and E.ev.id == 'vnew', 'induláskor betölti a pálya futó (nem befejezett) versenyét: CHT kupa')
    rows = lua_list(E.qualiTable())
    check(len(rows) == 1 and rows[0].name == 'Pilóta 1', 'a kvali-táblázat a versenyigazgatóé (a közvetítő HUD-hoz)')
    app.settings.ui.broadcastHud = True
    stub.frameStep(1 / 60)
    check(not errors(g), 'közvetítői HUD kvalifikáció alatt hiba nélkül')


def pilot_view():
    print('Pilóta gépe (nincs szerep):')
    L, g, stub, app = online_base(server_config={'layout': 'Teszt', 'pilotScores': 0}, steam_id=ME)
    E = req(L, 'src/event')
    check(E.involved() is False and E.canDirect() is False, 'pilóta: nem vesz részt a vezetésben, nem mér, nem tölt le')
    L.execute("STUB.tabLabels = {}; local o = ui.tabItem; ui.tabItem = function(l, f, fn) STUB.tabLabels[#STUB.tabLabels + 1] = l; return o(l, f, fn) end")
    g.script.windowMain(0.016)
    check(not any('Verseny' in str(x) for x in lua_list(stub.tabLabels)), 'pilótának (pilotScores = 0) nincs Verseny fül')
    check(not errors(g), 'hiba nélkül')


def upload_coalesce():
    print('Verseny küldése (sor):')
    L, g, stub, app = app_base()
    U = req(L, 'src/upload')
    L.execute("STUB.webPostMode = 'hold'")
    for rev in range(1, 4):
        U.event(L.table_from({'id': 'vx', 'name': 'x', 'rev': rev, 'text': '{}'}))
    q = lua_list(U._queue())
    evs = [it for it in q if it.kind == 'event']
    check(len(evs) <= 2, 'egy verseny újabb változata kiváltja a még várakozót (%d a sorban)' % len(evs))


def broadcast_app_window():
    print('Közvetítői HUD a telepített appban:')
    L, g, stub, app = app_base()
    g.script.windowBroadcast(0.016)
    check(not errors(g), 'a „CHT Közvetítő HUD” ablak (kvalifikáció) hiba nélkül')
    manifest = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'app', 'CHT_DriftJudge', 'manifest.ini'), encoding='utf-8').read()
    check('FUNCTION_MAIN = windowBroadcast' in manifest and 'VERSION = 0.4.0' in manifest, 'manifest: közvetítő ablak, 0.4.0')


if __name__ == '__main__':
    pure_bracket()
    tandem_runs()
    decel_map()
    competition_director()
    competition_follower()
    follower_late_join()
    pilot_view()
    upload_coalesce()
    broadcast_app_window()
    print()
    print(f'{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        for f in FAILS:
            print('  HIBA:', f)
        sys.exit(1)
