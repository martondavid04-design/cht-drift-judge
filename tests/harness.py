"""Loads the CSP stub + CHT Drift Judge in a fresh LuaJIT runtime (app mode or online mode)."""
import os
from lupa import luajit21 as lj

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, 'app', 'CHT_DriftJudge')
TESTS = os.path.join(ROOT, 'tests')
BUNDLE = os.path.join(ROOT, 'online', 'cht_drift_judge.lua')


def runtime(online=False, steam_id=None, online_extras=False, server_config=None, web=None):
    L = lj.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    if online:
        g.__STUB_ONLINE = True
    if steam_id:
        g.STUB_STEAM_ID = steam_id
    if online_extras:
        g.STUB_ONLINE_EXTRAS = True
    stub_src = open(os.path.join(TESTS, 'csp_stub.lua'), encoding='utf-8').read()
    L.execute(stub_src)
    stub = g.STUB
    if server_config:
        t = L.table()
        for k, v in server_config.items():
            t[k] = v
        stub.serverConfig = t
    if web:
        for k, v in web.items():
            stub.webResponses[k] = v
    return L, g, stub


def load_app(L, g):
    """App mode: CSP loads CHT_DriftJudge.lua from the app folder; require('src/x') resolves there."""
    g.package.path = APP.replace('\\', '/') + '/?.lua;' + str(g.package.path)
    src = open(os.path.join(APP, 'CHT_DriftJudge.lua'), encoding='utf-8').read()
    L.execute(src)


def load_online(L, g, path=BUNDLE):
    """Online mode: one bundled file, no package.path to the app folder (like a script downloaded from a URL)."""
    g.package.path = '/nonexistent/?.lua'
    src = open(path, encoding='utf-8').read()
    fn = L.eval('function(src) local f, e = loadstring(src, "=cht_drift_judge.lua"); if not f then error(e) end; return f() end')
    fn(src)


def frames(L, g, n, dt=1 / 60):
    step = g.STUB.frameStep
    for _ in range(n):
        step(dt)


def errors(g):
    return [g.STUB.errors[i] for i in range(1, len(g.STUB.errors) + 1)]
