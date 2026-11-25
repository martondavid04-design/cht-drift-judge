"""Synthetic drift runs through the whole app (gates → zones → result), for regression checks.

A straight 140 m test strip along +z: START z=0, JUDGING z=20, FINISH z=130, an OZ zone (outer line at
x=+5, z 40–90) and an IZ zone (inner line at x=-5, z 95–120). The car drives along +z at a given speed and
drift angle; the result of every scenario is compared with tests/baseline.json.
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import runtime, load_app, load_online, errors  # noqa: E402

LAYOUT = {
    'format': 'cht-drift-layout', 'version': 1, 'track': 'trackwood_pro_reverse_2026', 'name': 'Teszt',
    'weighting': 'auto',
    'gates': {
        'start': {'a': {'x': -8, 'y': 0, 'z': 0}, 'b': {'x': 8, 'y': 0, 'z': 0}},
        'judging': {'a': {'x': -8, 'y': 0, 'z': 20}, 'b': {'x': 8, 'y': 0, 'z': 20}},
        'finish': {'a': {'x': -8, 'y': 0, 'z': 130}, 'b': {'x': 8, 'y': 0, 'z': 130}},
    },
    'zones': [
        {'id': 'z1', 'name': 'OZ 1', 'type': 'OZ', 'side': 1, 'sideSet': True,
         'points': [{'x': 5, 'y': 0, 'z': z} for z in range(40, 91, 5)]},
        {'id': 'z2', 'name': 'IZ 2', 'type': 'IZ', 'side': -1, 'sideSet': True,
         'points': [{'x': -5, 'y': 0, 'z': z} for z in range(95, 121, 5)]},
    ],
}

SCENARIOS = {
    # name: (speed km/h, angle deg, x offset of the car centre, angle wobble deg)
    'jo_futas': (60, 45, 2.0, 3),
    'kis_szog': (60, 15, 2.0, 1),
    'nagy_szog_beforgas': (55, 100, 2.0, 0),
    'lassu_gurulas': (15, 2, 0.0, 0),
    'tavol_a_vonaltol': (60, 45, -2.0, 3),
}

TRACK_KEY = 'trackwood_pro_reverse_2026'
ROOT = 'C:/Users/T/Documents/Assetto Corsa/CHT Drift Judge'


def put_layout(g, L):
    fs = g.__FS
    fs[ROOT + '/layouts/' + TRACK_KEY + '/Teszt.json'] = json.dumps(LAYOUT)
    fs[ROOT + '/settings.json'] = json.dumps({'scoring': {}, 'ui': {}, 'activeLayouts': {TRACK_KEY: 'Teszt'}})


def drive(L, g, speed, angle, xoff, wobble, dt=1 / 60):
    stub = g.STUB
    v = speed / 3.6
    z = -10.0
    t = 0.0
    place = stub.placeCar
    step = stub.frameStep
    while z < 140:
        a = angle + wobble * math.sin(t * 2.0)
        if z < 22:
            a = min(a, angle) * min(1.0, max(0.0, (z + 10) / 25))
        yaw = -math.radians(a)
        place(0, xoff, z, yaw, speed, a)
        step(dt)
        z += v * dt
        t += dt
    for _ in range(30):
        place(0, xoff, z, 0, 0, 0)
        step(dt)
        z += 0.0


def summarize(res):
    if res is None:
        return None
    sp = res.split
    out = {
        'final': round(res.final or 0, 3),
        'zeroRun': bool(res.zeroRun),
        'zoneSum': round(res.zoneSum or 0, 3),
    }
    if sp is not None:
        out['line'] = round(sp.line or 0, 3)
        out['angle'] = round(sp.angle or 0, 3)
        out['style'] = round(sp.style or 0, 3)
    reasons = res.zeroReasons
    out['zeroReasons'] = [reasons[i] for i in range(1, len(reasons) + 1)] if reasons is not None else []
    return out


def run_all(online=False, bundle=None):
    results = {}
    for name, (speed, angle, xoff, wobble) in SCENARIOS.items():
        L, g, stub = runtime(online=online)
        if online:
            put_online_layout(g, L)
            load_online(L, g, bundle) if bundle else load_online(L, g)
        else:
            put_layout(g, L)
            load_app(L, g)
        for _ in range(5):
            stub.frameStep(1 / 60)
        drive(L, g, speed, angle, xoff, wobble)
        app = g.__CHT_APP
        results[name] = summarize(app.lastResult)
        errs = errors(g)
        if errs:
            results[name + '__errors'] = errs
    return results


def put_online_layout(g, L):
    # the online script downloads the layout from GitHub; the stub answers the request with this JSON
    base = 'https://raw.githubusercontent.com/martondavid04-design/cht-drift-judge/main/layouts/'
    g.STUB.webResponses[base + TRACK_KEY + '/Teszt.json'] = json.dumps(LAYOUT)
    cfg = L.table()
    cfg['layout'] = 'Teszt'
    g.STUB.serverConfig = cfg


if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'check'
    res = run_all()
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'baseline.json')
    if mode == 'baseline':
        json.dump(res, open(path, 'w'), indent=1, ensure_ascii=False)
        print(json.dumps(res, indent=1, ensure_ascii=False))
    else:
        base = json.load(open(path))
        print(json.dumps(res, indent=1, ensure_ascii=False))
        print('EGYEZIK' if base == res else 'ELTÉR a baseline-tól!')
