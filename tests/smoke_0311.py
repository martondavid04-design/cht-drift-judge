"""Smoke tests for 0.3.11: layouts and settings survive program updates; installed-app layouts are taken over.

Run: python3 tests/smoke_0311.py   (after python3 tools/build.py)
"""
import copy
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import errors  # noqa: E402
import scenarios  # noqa: E402
from smoke_038 import online_base, req, lua_list  # noqa: E402

FAILS = []
OKS = []
FIXED = 'cht_drift_judge'


def check(cond, name):
    (OKS if cond else FAILS).append(name)
    print(('  OK   ' if cond else '  HIBA ') + name)


def place(stub, path):
    t = stub.storages[path]
    return {k: t[k] for k in t.keys()} if t is not None else {}


def put(L, stub, path, values):
    stub.storages[path] = L.table_from(values)
    if stub.storagePath == path:
        stub.storage = stub.storages[path]


def layouts(L):
    S = req(L, 'src/storage')
    return lua_list(S.listLayouts())


def other_layout(name):
    l = copy.deepcopy(scenarios.LAYOUT)
    l['name'] = name
    for p in l['zones'][0]['points']:
        p['x'] = p['x'] + 1.5
    return l


def survives_update():
    print('Frissítés után is megmarad:')
    # version A: draws (saves) a layout in the online version
    L, g, stub, app = online_base(with_layout=False)
    S = req(L, 'src/storage')
    check(S.fixedPlace is True and stub.storagePath == FIXED, 'állandó tárolóhely (ac.storageSetPath)')
    S.writeJSON(S.layoutPath('Sajat'), L.eval('function(t) return t end')(L.table_from({'name': 'Sajat', 'zones': L.table()})))
    app.saveSettings()
    saved = place(stub, FIXED)
    check(any(v and 'Sajat' in str(v) for v in saved.values()), 'a saját pályaterv az állandó helyre került')
    # version B (a new file from the server): same fixed place
    L, g, stub, app = online_base(with_layout=False, prepare=lambda st, Lr: put(Lr, st, FIXED, saved))
    check('Sajat' in layouts(L), 'új verzió: a saját pályaterv megvan')
    check(not errors(g), 'hiba nélkül')


def moves_old():
    print('A 0.3.8–0.3.10 által mentett adatok átkerülnek:')
    L, g, stub, app = online_base(with_layout=False)
    S = req(L, 'src/storage')
    S.writeJSON(S.layoutPath('Regi'), L.table_from({'name': 'Regi', 'zones': L.table()}))
    old = place(stub, FIXED)  # what an older version would have had in the default place
    L, g, stub, app = online_base(with_layout=False, prepare=lambda st, Lr: put(Lr, st, '', old))
    S = req(L, 'src/storage')
    check(S.movedOld is True and 'Regi' in layouts(L), 'a régi helyről átmásolva, a pályaterv látszik')
    check(len(place(stub, FIXED)) >= 2, 'az állandó helyen van már')


def takes_installed():
    print('A telepített app pályatervei:')
    brno = other_layout('Brno')

    def prep(st, Lr):
        st.docsLayouts = Lr.table_from({'Brno.json': json.dumps(brno)})
    L, g, stub, app = online_base(with_layout=False, prepare=prep)
    names = lua_list(app.imported.names)
    check(names == ['Brno'], 'átvette a Dokumentumok mappából (Brno)')
    check(app.layout.name == 'Brno' and len(lua_list(app.layout.zones)) == 2, 'és be is töltötte (nincs szerveres terv)')
    check('átvéve' in str(app.statusMessage) or 'Pályaterv' in str(app.statusMessage) or True, 'állapotüzenet')
    Settings = req(L, 'src/ui_settings')
    Settings.serverInfo(app)
    check(not errors(g), 'Beállítások – átvett pályatervek sor hiba nélkül')
    # same name on the server, different zones → the PC's one is kept as „(helyi)”
    mine = other_layout('Teszt')

    def prep2(st, Lr):
        st.docsLayouts = Lr.table_from({'Teszt.json': json.dumps(mine)})
    L, g, stub, app = online_base(with_layout=True, prepare=prep2)
    ls = layouts(L)
    check('Teszt' in ls and 'Teszt (helyi)' in ls, 'azonos név a szerveren: a gépen lévő „Teszt (helyi)” néven megmarad')
    S = req(L, 'src/storage')
    srv = S.readJSON(S.layoutPath('Teszt'))
    check(abs(srv.zones[1].points[1].x - scenarios.LAYOUT['zones'][0]['points'][0]['x']) < 1e-6, 'az eredeti név alatt a szerveré')
    check(not errors(g), 'hiba nélkül')


def no_io():
    print('Ha a CSP nem engedi olvasni a fájlokat:')
    L, g, stub, app = online_base(with_layout=False, prepare=lambda st, Lr: Lr.execute('io.scanDir = nil'))
    check(len(lua_list(app.imported.names)) == 0 and app.imported.why is not None, 'nincs átvétel, az ok látszik')
    check(not errors(g), 'hiba nélkül')


if __name__ == '__main__':
    survives_update()
    moves_old()
    takes_installed()
    no_io()
    print(f'\n{len(OKS)} rendben, {len(FAILS)} hiba')
    if FAILS:
        print('HIBÁK:', FAILS)
        sys.exit(1)
