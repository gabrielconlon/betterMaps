#!/usr/bin/env python3
"""Does a public cycling router's "quiet roads" preference change Dublin routes?

Run: python3 -I scripts/cycling_quiet_eval.py
Engines: FOSSGIS Valhalla (use_roads 0.0 vs 1.0), BRouter (safety / trekking vs fastbike).
"""
import json
import math
import statistics
import time
import urllib.error
import urllib.request

UA = "BetterMaps-research/0.1 (gabe.conlon@gmail.com)"
SLEEP = 1.0
TIMEOUT = 60
SAMPLE_M = 25.0
NEAR_M = 50.0
CHANGED = 0.25

PAIRS = [
    ("Rathmines-PhoenixPark", (53.3215, -6.2650), (53.3560, -6.3300)),
    ("Sandymount-Smithfield", (53.3330, -6.2150), (53.3480, -6.2780)),
    ("Drumcondra-Ballsbridge", (53.3690, -6.2550), (53.3290, -6.2300)),
    ("Clontarf-Trinity", (53.3640, -6.2000), (53.3438, -6.2546)),
    ("Rathfarnham-CanalDock", (53.2900, -6.2850), (53.3395, -6.2395)),
    ("Dundrum-Stoneybatter", (53.2910, -6.2450), (53.3520, -6.2800)),
    ("Kilmainham-Fairview", (53.3420, -6.3050), (53.3640, -6.2400)),
    ("Blackrock-Ranelagh", (53.3015, -6.1780), (53.3260, -6.2560)),
    ("Cabra-Donnybrook", (53.3650, -6.2900), (53.3200, -6.2336)),
    ("Glasnevin-Ringsend", (53.3730, -6.2700), (53.3420, -6.2250)),
]

# engine label -> (quiet variants, fast variant)
ENGINES = {
    "valhalla": ["use_roads=0.0"],
    "brouter-safety": ["safety"],
    "brouter-trekking": ["trekking"],
}


def http(req):
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read().decode("utf-8"))


def decode_polyline(s, prec=6):
    pts, i, lat, lon, f = [], 0, 0, 0, 10 ** prec
    while i < len(s):
        for which in (0, 1):
            shift = result = 0
            while True:
                b = ord(s[i]) - 63
                i += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            d = ~(result >> 1) if result & 1 else result >> 1
            if which == 0:
                lat += d
            else:
                lon += d
        pts.append((lat / f, lon / f))
    return pts


def valhalla(a, b, use_roads):
    body = {
        "locations": [{"lat": a[0], "lon": a[1]}, {"lat": b[0], "lon": b[1]}],
        "costing": "bicycle",
        "costing_options": {"bicycle": {"use_roads": use_roads, "bicycle_type": "Hybrid", "use_hills": 0.3}},
        "units": "kilometers",
    }
    req = urllib.request.Request(
        "https://valhalla1.openstreetmap.de/route",
        data=json.dumps(body).encode(),
        headers={"User-Agent": UA, "Content-Type": "application/json"},
        method="POST",
    )
    return decode_polyline(http(req)["trip"]["legs"][0]["shape"], 6)


def brouter(a, b, profile):
    url = (
        "https://brouter.de/brouter?lonlats=%f,%f|%f,%f&profile=%s&alternativeidx=0&format=geojson"
        % (a[1], a[0], b[1], b[0], profile)
    )
    d = http(urllib.request.Request(url, headers={"User-Agent": UA}))
    coords = d["features"][0]["geometry"]["coordinates"]
    return [(c[1], c[0]) for c in coords]


def hav(p, q):
    r = 6371000.0
    la1, la2 = math.radians(p[0]), math.radians(q[0])
    dl = math.radians(q[1] - p[1])
    dp = la2 - la1
    h = math.sin(dp / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def length_km(pts):
    return sum(hav(pts[i], pts[i + 1]) for i in range(len(pts) - 1)) / 1000.0


def resample(pts, step=SAMPLE_M):
    out = [pts[0]]
    carry = 0.0
    for i in range(len(pts) - 1):
        p, q = pts[i], pts[i + 1]
        seg = hav(p, q)
        if seg == 0:
            continue
        pos = step - carry
        while pos <= seg:
            t = pos / seg
            out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
            pos += step
        carry = seg - (pos - step)
    out.append(pts[-1])
    return out


def divergence(quiet, fast):
    qs, fs = resample(quiet), resample(fast)
    # grid index on fast samples (~0.001 deg ~ 70-110 m cells)
    cell = 0.001
    grid = {}
    for p in fs:
        grid.setdefault((int(p[0] / cell), int(p[1] / cell)), []).append(p)
    far = 0
    for p in qs:
        ci, cj = int(p[0] / cell), int(p[1] / cell)
        near = False
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for f in grid.get((ci + di, cj + dj), ()):
                    if hav(p, f) <= NEAR_M:
                        near = True
                        break
                if near:
                    break
            if near:
                break
        if not near:
            far += 1
    return far / len(qs)


def call(fn, *args):
    try:
        pts = fn(*args)
        time.sleep(SLEEP)
        return pts, None
    except urllib.error.HTTPError as e:
        err = "HTTP %d" % e.code
    except Exception as e:  # timeouts, parse errors, etc.
        err = type(e).__name__ + ": " + str(e)[:60]
    time.sleep(SLEEP)
    return None, err


def main():
    rows = []  # (pair, engine, qkm, fkm, div, changed, err)
    for name, a, b in PAIRS:
        fast_v, e1 = call(valhalla, a, b, 1.0)
        quiet_v, e2 = call(valhalla, a, b, 0.0)
        fast_b, e3 = call(brouter, a, b, "fastbike")
        results = [("valhalla", quiet_v, fast_v, e2 or e1)]
        for prof, label in (("safety", "brouter-safety"), ("trekking", "brouter-trekking")):
            q, e = call(brouter, a, b, prof)
            results.append((label, q, fast_b, e or e3))
        for eng, q, f, err in results:
            if q and f:
                d = divergence(q, f)
                rows.append((name, eng, length_km(q), length_km(f), d, d > CHANGED, None))
            else:
                rows.append((name, eng, None, None, None, None, err))

    print("%-24s %-17s %8s %8s %6s %s" % ("pair", "engine", "quiet_km", "fast_km", "div", "changed"))
    for name, eng, qk, fk, d, ch, err in rows:
        if err:
            print("%-24s %-17s ERROR %s" % (name, eng, err))
        else:
            print("%-24s %-17s %8.2f %8.2f %6.2f %s" % (name, eng, qk, fk, d, "YES" if ch else "no"))

    print("\nSummary")
    for eng in ("valhalla", "brouter-safety", "brouter-trekking"):
        er = [r for r in rows if r[1] == eng]
        ok = [r for r in er if not r[6]]
        errs = sorted({r[6] for r in er if r[6]})
        med = statistics.median(r[4] for r in ok) if ok else float("nan")
        print(
            "%-17s changed %d/10  median divergence %.2f  ok %d  errors: %s"
            % (eng, sum(1 for r in ok if r[5]), med, len(ok), ", ".join(errs) or "none")
        )


if __name__ == "__main__":
    main()
