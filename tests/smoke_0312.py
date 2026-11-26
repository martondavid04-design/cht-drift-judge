"""Smoke tests for 0.3.12: shared layouts – „Feltöltés mindenkinek”, sync from GitHub and the uploaded ones.

Run: python3 tests/smoke_0312.py   (after python3 tools/build.py)
"""
import copy
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import runtime, load_app, errors  # noqa: E402
import scenarios  # noqa: E402
from smoke_038 import online_base, req, lua_list, draw_all  # noqa: E402

FAILS = []
OKS = []
GH = 'https://raw.githubusercontent.com/martondavid04-design/cht-drift-judge/main/layouts/' + scenarios.TRACK_KEY + '/'


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def variant(name='Teszt', dx=0.0):
    l = copy.deepcopy(scenarios.LAYOUT)
    l['name'] = name
    for p in l['zones'][0]['points']:
        p['x'] = p['x'] + dx
    return l


import re  # noqa: E402
_SRC = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app', 'CHT_DriftJudge', 'src', 'upload.lua'), encoding='utf-8').read()
SHEET_URL = re.search(r"M.url = '([^']+)'", _SRC).group(1) + '?action=layouts&track=' + scenarios.TRACK_KEY


def sheet_url(L=None):
    return SHEET_URL


def sheet_body(items):
    return json.dumps({'ok': True, 'track': scenarios.TRACK_KEY, 'layouts': items})


def local_text(L, name):
    return L.eval("(__CHT_REQUIRE__ or require)('src/storage').readText((__CHT_REQUIRE__ or require)('src/storage').layoutPath('" + name + "'))")


def names(L):
    return lua_list(L.eval("(__CHT_REQUIRE__ or require)('src/storage').listLayouts()"))


def frames(stub, n=3):
    for _ in range(n):
        stub.frameStep(1 / 60)


def app_with(github=None, index=None, sheet=None, local=True):
    L, g, stub = runtime()
    if local:
        scenarios.put_layout(g, L)
    if github:
        for n, t in github.items():
            stub.webResponses[GH + n + '.json'] = t
    if index is not None:
        stub.webResponses[GH + 'index.json'] = json.dumps(index)
    if sheet is not None:
        stub.webResponses[sheet_url(L)] = sheet_body(sheet)
    load_app(L, g)
    frames(stub)
    return L, g, stub, g.__CHT_APP


def installed():
    print('Telepített app – közös pályatervek:')
    same = json.dumps(scenarios.LAYOUT)
    L, g, stub, app = app_with(github={'Teszt': same}, index=['Teszt'])
    check(app.remote.state == 'ok' and 'Teszt' in lua_list(app.remote.names), 'a GitHubról letöltötte (a telepített app is)')
    check(names(L) == ['Teszt'], 'azonos tartalom: nincs „(helyi)” másolat')
    check(app.settings.layoutSync[scenarios.TRACK_KEY]['Teszt'] is not None, 'megjegyzi, melyik közös változat van a gépen')
    pretty = json.dumps(scenarios.LAYOUT, indent=2)
    L, g, stub, app = app_with(github={'Teszt': pretty}, index=['Teszt'])
    check(names(L) == ['Teszt'] and local_text(L, 'Teszt') == pretty, 'másképp írt, de azonos terv: nincs másolat, a közös szöveg kerül a gépre')
    # an update comes (uploaded), the PC's copy is unchanged → replaced and reloaded
    newer = json.dumps(variant(dx=2.0))
    stub.webResponses[sheet_url(L)] = sheet_body([{'name': 'Teszt', 'author': 'Béla', 'time': '2026-11-26 12:00:00', 'text': newer}])
    app.syncSharedLayouts(True)
    frames(stub)
    check(local_text(L, 'Teszt') == newer and names(L) == ['Teszt'], 'új közös változat, a gépen nem módosították: frissül')
    x = app.layout.zones[1].points[1].x
    check(abs(x - (scenarios.LAYOUT['zones'][0]['points'][0]['x'] + 2.0)) < 1e-6, 'a használatban lévő terv is az új')
    check('Béla' in str(app.remote['from']['Teszt']), 'látszik, ki töltötte fel')
    # edited here, the shared one unchanged → the edit stays
    app.layout.zones[1].points[1].x = 77
    app.dirty = True
    app.saveLayout()
    app.syncSharedLayouts(True)
    frames(stub)
    check(abs(app.layout.zones[1].points[1].x - 77) < 1e-6 and names(L) == ['Teszt'], 'itt módosították, a közös nem változott: a módosítás marad')
    # edited here and the shared one changed too → both kept
    newest = json.dumps(variant(dx=4.0))
    stub.webResponses[sheet_url(L)] = sheet_body([{'name': 'Teszt', 'author': 'Cili', 'time': '2026-11-26 13:00:00', 'text': newest}])
    app.syncSharedLayouts(True)
    frames(stub)
    check('Teszt (helyi)' in names(L) and local_text(L, 'Teszt') == newest, 'mindkettő változott: a gépen lévő „Teszt (helyi)” néven megmarad, a közös a helyére')
    S = req(L, 'src/storage')
    mine = S.readJSON(S.layoutPath('Teszt (helyi)'))
    check(abs(mine.zones[1].points[1].x - 77) < 1e-6, '…és a „(helyi)” a módosított')
    check('megmaradt' in str(app.statusMessage), 'szól is róla')
    # the uploaded one wins over GitHub
    L, g, stub, app = app_with(github={'Teszt': same}, index=['Teszt'], sheet=[{'name': 'Teszt', 'author': 'Ati', 'time': 't', 'text': newer}])
    check(local_text(L, 'Teszt') == newer, 'ugyanaz a név a GitHubon és feltöltve: a feltöltött (újabb) nyer')
    draw_all(g)
    check(not errors(g), 'Pálya fül a megosztás gombjaival hiba nélkül')


def publishing():
    print('Feltöltés mindenkinek:')
    L, g, stub, app = app_with()
    app.settings.ui.uploadData = False  # test data off: publishing is still allowed (it is a click)
    app.layout.zones[1].points[1].x = 55
    app.dirty = True
    app.publishLayout(False)
    frames(stub, 4)
    posts = [json.loads(stub.webPosts[i].body) for i in range(1, len(stub.webPosts) + 1)]
    lay = [p for p in posts if p.get('type') == 'layout']
    check(len(lay) == 1, 'elküldte (a tesztadat-küldés kikapcsolása mellett is)')
    if lay:
        p = lay[0]
        check(p['name'] == 'Teszt' and p['track'] == scenarios.TRACK_KEY and p['layoutText'] == local_text(L, 'Teszt'), 'a mentett terv pontos szövegét küldte, pálya és név')
        check(json.loads(p['layoutText'])['zones'][0]['points'][0]['x'] == 55, 'a módosítással együtt (előtte mentette)')
    check(app.publishing.state == 'ok' and 'Feltöltve mindenkinek' in str(app.statusMessage), 'visszajelzés: feltöltve')
    check(app.serverLayouts['Teszt'] is True, 'közös tervként jelöli')
    # others get it; on this PC no duplicate
    text = local_text(L, 'Teszt')
    stub.webResponses[sheet_url(L)] = sheet_body([{'name': 'Teszt', 'author': 'Teszt Pilóta', 'time': 'most', 'text': text}])
    app.syncSharedLayouts(True)
    frames(stub)
    check(names(L) == ['Teszt'], 'a feltöltő gépén a visszajövő terv nem okoz másolatot')
    # failure
    stub.webPostMode = 'badkey'
    app.publishLayout(False)
    frames(stub, 4)
    check(app.publishing.state == 'error' and 'Nem sikerült' in str(app.statusMessage), 'hiba esetén szól')
    stub.webPostMode = 'ok'
    # take down
    app.publishLayout(True)
    frames(stub, 4)
    posts = [json.loads(stub.webPosts[i].body) for i in range(1, len(stub.webPosts) + 1)]
    down = [p for p in posts if p.get('type') == 'layout' and p.get('deleted')]
    check(len(down) == 1 and 'layoutText' not in down[0], 'levétel: csak a nevet küldi, törölve jelöléssel')
    check(names(L) == ['Teszt'], 'levételkor a gépen lévő példány megmarad')


def online():
    print('Online változat – közös pályatervek:')
    verseny = json.dumps(variant('Verseny', dx=1.0))

    def prep(st, Lr):
        st.webResponses[GH + 'Verseny.json'] = verseny
    L, g, stub, app = online_base({'layout': 'Verseny'}, prepare=prep)
    frames(stub)
    check(app.layout.name == 'Verseny', 'a szerver által kért terv (layout = Verseny) töltődik be')
    check(set(['Teszt', 'Verseny']) <= set(names(L)), 'a többi közös terv is a gépre kerül')
    # redirect (the Google script answers with 302)
    url = sheet_url(L)
    stub.webRedirects = L.table_from({url: 'https://script.googleusercontent.com/echo?x=1'})
    stub.webResponses['https://script.googleusercontent.com/echo?x=1'] = sheet_body([{'name': 'Uj', 'author': 'Ati', 'time': 't', 'text': json.dumps(variant('Uj'))}])
    app.syncSharedLayouts(True)
    frames(stub)
    check('Uj' in names(L), 'a Google átirányítását követi (302 → a válasz)')
    check(not errors(g), 'hiba nélkül')


if __name__ == '__main__':
    installed()
    publishing()
    online()
    print(f'\n{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        print('HIBÁK:', FAILS)
        sys.exit(1)
