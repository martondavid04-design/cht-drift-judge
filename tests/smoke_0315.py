"""Smoke tests for 0.3.15: judges / broadcaster chosen in the game by a server admin (no Steam IDs to
collect), Steam ID hello between the PCs, the new data store address.

Run: python3 tests/smoke_0315.py   (after python3 tools/build.py)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import errors  # noqa: E402
from smoke_038 import online_base, req, lua_list, draw_all  # noqa: E402

FAILS = []
OKS = []

ME = '76561198011111111'
OTHER = '76561198022222222'
NEW_URL = 'https://script.google.com/macros/s/AKfycbxOxMCb5AuRvyurK3WEewwNGOe-Ph2O0sSQyPVNW50lKvSznnlXSnU1fc7qmadBkmmasA/exec'


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def hash_id(steam):
    """Same as hashId_ in tools/gsheet_collector.gs and R.hashId in src/roles.lua."""
    s = 'cht-dj:' + str(steam)
    a, b = 7, 11
    for ch in s.encode('utf-8'):
        a = (a * 31 + ch) % 2147483647
        b = (b * 131 + ch) % 1000000007
    return '%08x%08x' % (a, b)


def roles_url():
    return NEW_URL + '?action=roles'


def fake_clock(L):
    L.execute("""
      local rq = __CHT_REQUIRE__ or require
      STUB.T = os.clock()
      rq('src/netsync').clockFn = function() return STUB.T end
      rq('src/roles').clockFn = function() return STUB.T end
      rq('src/upload').clockFn = function() return STUB.T end
    """)


def advance(stub, seconds, step=0.5):
    t = 0.0
    while t < seconds:
        stub.T = stub.T + step
        stub.frameStep(1 / 60)
        t += step


def sent_with(stub, part):
    out = []
    for i in range(1, len(stub.sent) + 1):
        e = stub.sent[i]
        if part in str(e.key):
            out.append(e.msg)
    return out


def role_posts(stub):
    out = []
    for i in range(1, len(stub.webPosts) + 1):
        p = stub.webPosts[i]
        try:
            body = json.loads(p.body)
        except Exception:
            continue
        if body.get('type') == 'role':
            out.append((p.url, body))
    return out


def basics():
    print('Ujjlenyomat és cím:')
    L, g, stub, app = online_base({'layout': 'Teszt'}, steam_id=ME)
    R = req(L, 'src/roles')
    ids = ['76561198000000000', ME, OTHER, '76561197960287930']
    check(all(R.hashId(i) == hash_id(i) for i in ids), 'Steam ID ujjlenyomata a programban = a táblázat scriptjében')
    check(R.hashId('76561198000000000') == '2ff5a3e3029fe5de', 'egyezik a Google-on futó script értékével (2ff5a3e3029fe5de)')
    up = req(L, 'src/upload')
    check(up.url == NEW_URL and up.target() == NEW_URL, 'az új táblázat címére küld')
    check(not errors(g), 'hiba nélkül')


def hello():
    print('Steam ID csere a gépek között (hello):')
    L, g, stub, app = online_base({'layout': 'Teszt'}, steam_id=ME)
    fake_clock(L)
    N = req(L, 'src/netsync')
    advance(stub, 6)
    hellos = sent_with(stub, 'cht.driftjudge.hello.v1')
    check(len(hellos) >= 1 and str(hellos[-1].steamId) == ME, 'belépés után pár másodperccel elküldi a saját Steam ID-ját')
    n0 = len(hellos)
    # another PC says hello → it is known, and this PC answers soon (so a newcomer learns everyone)
    msg = L.table_from({'steamId': OTHER, 'role': '', 'appVersion': '0.3.15'})
    stub.deliverFrom(1, 'cht.driftjudge.hello.v1', msg)
    p = N.peers[1]
    check(p is not None and str(p.steamId) == OTHER and str(p.name) == 'Pilóta 1', 'a másik gép Steam ID-ja megvan (autó #1)')
    advance(stub, 4)
    check(len(sent_with(stub, 'cht.driftjudge.hello.v1')) == n0 + 1, 'egy új gépnek pár mp-en belül válaszol')
    # every 2 minutes again
    advance(stub, 125, step=5)
    check(len(sent_with(stub, 'cht.driftjudge.hello.v1')) >= n0 + 2, '2 percenként újra elküldi')
    # a forged / broken ID is not kept
    stub.deliverFrom(1, 'cht.driftjudge.hello.v1', L.table_from({'steamId': 'abc', 'role': '', 'appVersion': ''}))
    check(N.peers[1].steamId is None, 'hibás Steam ID-t nem fogad el')
    # while the installed app runs on this PC the online script stays passive, but still says hello
    L.execute("(__CHT_REQUIRE__ or require)('src/netsync').installedAppRunning = function() return true end")
    for _ in range(20000):   # the passive check runs once a (CPU) second
        stub.frameStep(1 / 60)
        if app.passive:
            break
    n1 = len(sent_with(stub, 'cht.driftjudge.hello.v1'))
    advance(stub, 125, step=5)
    check(app.passive is True and len(sent_with(stub, 'cht.driftjudge.hello.v1')) > n1, 'telepített app mellett (csendes mód) is küldi')
    check(not errors(g), 'hiba nélkül')


def assigned_role():
    print('Kijelölt szerep a táblázatból:')

    def prep(stub, L):
        stub.webResponses[roles_url()] = json.dumps({'ok': True, 'roles': [{'h': hash_id(ME), 'role': 'judge'}, {'h': hash_id(OTHER), 'role': 'streamer'}]})
    L, g, stub, app = online_base({'layout': 'Teszt', 'pilotScores': 0}, steam_id=ME, prepare=prep)
    fake_clock(L)
    advance(stub, 2)
    P = req(L, 'src/platform')
    R = req(L, 'src/roles')
    role, src = P.roleSource()
    check(R.state == 'ok' and role == 'judge' and src == 'assigned', 'az admin által kijelölt bíró szerepet megkapja (forrás: kijelölt)')
    check(P.canSeeScores() is True, 'pilotScores = 0 mellett is látja a pontokat')
    c = app.settings.ui.roleCache
    check(c is not None and c.h == hash_id(ME) and c.role == 'judge', 'a szerepet megjegyzi (következő belépésnél azonnal megvan)')
    check(R.roleOf(OTHER) == 'streamer', 'a másik gép szerepe is látszik (közvetítő)')
    # the server's own lists still come first
    L2, g2, stub2, app2 = online_base({'layout': 'Teszt', 'pilotScores': 0, 'broadcasters': ME}, steam_id=ME, prepare=prep)
    fake_clock(L2)
    advance(stub2, 2)
    role2, src2 = req(L2, 'src/platform').roleSource()
    check(role2 == 'streamer' and src2 == 'list', 'a szerver saját listája (broadcasters) erősebb')
    # role taken away (list without this ID) → pilot again, the cache too
    stub.webResponses[roles_url()] = json.dumps({'ok': True, 'roles': []})
    R.fetch('teszt')
    advance(stub, 1)
    role3, _ = P.roleSource()
    check(role3 is None and P.canSeeScores() is False and app.settings.ui.roleCache is None, 'ha elvették: újra pilóta, a megjegyzett szerep is törlődik')
    # a ping for this PC makes it re-read the list
    stub.webResponses[roles_url()] = json.dumps({'ok': True, 'roles': [{'h': hash_id(ME), 'role': 'judge'}]})
    n = sum(1 for i in range(1, len(stub.webRequests) + 1) if 'action=roles' in str(stub.webRequests[i]))
    stub.deliverFrom(1, 'cht.driftjudge.role.v1', L.table_from({'steamId': ME}))
    advance(stub, 1)
    n2 = sum(1 for i in range(1, len(stub.webRequests) + 1) if 'action=roles' in str(stub.webRequests[i]))
    check(n2 == n + 1 and P.serverRole() == 'judge', 'jelzés az admintól: azonnal újraolvassa, és már bíró')
    # ping for another PC: a pilot does not re-read
    stub.deliverFrom(1, 'cht.driftjudge.role.v1', L.table_from({'steamId': OTHER}))
    advance(stub, 1)
    n3 = sum(1 for i in range(1, len(stub.webRequests) + 1) if 'action=roles' in str(stub.webRequests[i]))
    check(n3 == n2, 'más gépnek szóló jelzésre nem olvas újra')
    check(not errors(g) and not errors(g2), 'hiba nélkül')


def admin_assigns():
    print('Az admin kijelöli a bírót a Versenyzők fülön:')

    def prep(stub, L):
        stub.webResponses[roles_url()] = json.dumps({'ok': True, 'roles': []})
        stub.makeAdmin = True
        stub.sim.isAdmin = True
    L, g, stub, app = online_base({'layout': 'Teszt', 'pilotScores': 0}, steam_id=ME, prepare=prep)
    fake_clock(L)
    advance(stub, 6)
    P = req(L, 'src/platform')
    R = req(L, 'src/roles')
    check(P.isAdmin() is True and R.canAssign() is True, 'szerveradminként adhat szerepet')
    stub.deliverFrom(1, 'cht.driftjudge.hello.v1', L.table_from({'steamId': OTHER, 'role': '', 'appVersion': '0.3.15'}))
    advance(stub, 1)
    D = req(L, 'src/ui_drivers')
    # what the store answers after the save (the role list is re-read right after it)
    stub.webResponses[roles_url()] = json.dumps({'ok': True, 'roles': [{'h': hash_id(OTHER), 'role': 'judge'}]})
    stub.uiPress['Bíró##role_judge_Pilóta 1'] = True
    D.drawTab(app)
    check(R.roleOf(OTHER) == 'judge', 'mentés közben is már bíróként mutatja')
    advance(stub, 1)
    posts = role_posts(stub)
    check(len(posts) == 1 and posts[0][0] == NEW_URL and posts[0][1]['steamId'] == OTHER and posts[0][1]['role'] == 'judge',
          'a „Bíró” gomb elküldi: Pilóta 1 Steam ID-ja → bíró')
    b = posts[0][1] if posts else {}
    check(b.get('bySteamId') == ME and b.get('admin') is True and b.get('name') == 'Pilóta 1', 'naplózva, ki jelölte ki (Steam ID, admin)')
    check(len(sent_with(stub, 'cht.driftjudge.role.v1')) == 1 and str(sent_with(stub, 'cht.driftjudge.role.v1')[0].steamId) == OTHER,
          'utána jelez a gépének (azonnal újraolvassa)')
    check(R.roleOf(OTHER) == 'judge', 'a listában rögtön bíróként látszik')
    # take it away again
    stub.webResponses[roles_url()] = json.dumps({'ok': True, 'roles': []})
    stub.uiPress['Pilóta##role_pilot_Pilóta 1'] = True
    D.drawTab(app)
    advance(stub, 1)
    posts = role_posts(stub)
    check(len(posts) == 2 and posts[1][1]['role'] == 'pilot' and R.roleOf(OTHER) is None, '„Pilóta” gomb: visszavonja')
    # an unknown PC (no hello): no buttons, a note instead; a failed save is reported
    N = req(L, 'src/netsync')
    N.peers[1] = None
    stub.uiPress['Bíró##role_judge_Pilóta 1'] = True
    D.drawTab(app)
    advance(stub, 1)
    stub.uiPress = L.table()
    check(len(role_posts(stub)) == 2, 'akitől nem jött Steam ID, annak nem lehet szerepet adni')
    ok = R.assign(1, 'judge')
    check(ok is False, '…és a program meg is mondja')
    check(not errors(g), 'hiba nélkül')


def not_admin():
    print('Nem admin:')

    def prep(stub, L):
        stub.webResponses[roles_url()] = json.dumps({'ok': True, 'roles': []})
    L, g, stub, app = online_base({'layout': 'Teszt', 'pilotScores': 1}, steam_id=ME, prepare=prep)
    fake_clock(L)
    advance(stub, 6)
    R = req(L, 'src/roles')
    check(R.canAssign() is False, 'pilóta nem adhat szerepet')
    stub.deliverFrom(1, 'cht.driftjudge.hello.v1', L.table_from({'steamId': OTHER, 'role': '', 'appVersion': '0.3.15'}))
    stub.uiPress['Bíró##role_judge_Pilóta 1'] = True
    req(L, 'src/ui_drivers').drawTab(app)
    check(len(role_posts(stub)) == 0, 'nála nincs „Bíró” gomb')
    # session message carries the Steam ID (Belépések lap)
    advance(stub, 10)
    sess = [json.loads(stub.webPosts[i].body) for i in range(1, len(stub.webPosts) + 1)]
    sess = [s for s in sess if s.get('type') == 'session']
    check(len(sess) == 1 and sess[0].get('steamId') == ME, 'a belépés sorában a Steam ID is benne van')
    draw_all(g)
    check(not errors(g), 'hiba nélkül')


if __name__ == '__main__':
    basics()
    hello()
    assigned_role()
    admin_assigns()
    not_admin()
    print(f'\n{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        print('HIBÁK:', FAILS)
        sys.exit(1)
