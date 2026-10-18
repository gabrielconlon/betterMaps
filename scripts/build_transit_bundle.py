#!/usr/bin/env python3
"""Build the BetterMaps offline transit bundle from a TFI GTFS feed.

Outputs (all deterministic, sorted by id so git diffs stay stable):

  <out-dir>/transit_stops.json    Dublin-bbox stops with kind/line/code
  <out-dir>/transit_lines.json    Luas/DART/rail polylines: each line's longest shape plus
                                  one entry per branch other shapes add (ids dart, dart-2, ...)
  <out-dir>/transit_routes.json   routes that serve at least one Dublin-bbox stop
  <timetable-out>                 integer-coded SQLite timetable (+ .gz next to it)

Python stdlib only. Streams the big CSVs (stop_times.txt is ~9M rows) and
never materialises them in memory; stop_times go straight into SQLite in
batches inside one transaction.

Usage:
  python3 -I scripts/build_transit_bundle.py \
      --input GTFS_All.zip --out-dir BetterMaps/Resources/Transit \
      --timetable-out build/transit_timetable.sqlite

`--input` may be a GTFS zip or a directory of GTFS .txt files.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import gzip
import hashlib
import io
import json
import math
import os
import re
import sqlite3
import sys
import time
import zipfile

SCHEMA_VERSION = 1
DEFAULT_BBOX = "53.15,53.65,-6.65,-5.95"  # minLat,maxLat,minLon,maxLon (Dublin)
DP_TOLERANCE_DEG = 0.00007  # ~8 m, in degrees of latitude
LINE_TRIM_MARGIN_DEG = 0.05  # polylines are trimmed to bbox expanded by this (~5 km)
LUAS_DEDUPE_METRES = 250.0
KIND_PRIORITY = {"dart": 0, "rail": 1, "luas": 2, "bus": 3}
# transit_lines.json: every shape of a line is considered, longest first. A
# shape's stretches within LINE_COVER_METRES of what is already kept are
# dropped (reversed duplicates, short workings, sub-sections); a leftover
# stretch is emitted only if it strays more than LINE_BRANCH_METRES from the
# kept network somewhere, so a parallel track a few metres over is not drawn twice.
LINE_COVER_METRES = 15.0
LINE_BRANCH_METRES = 40.0
LINE_SAMPLE_METRES = 20.0
# Coverage gate: every DART / rail / Luas station must be this close to a line
# of its kind (Luas: of its own Red/Green line) or the build fails.
COVERAGE_MAX_METRES = 150.0
GATED_KINDS = ("dart", "luas", "rail")
M_PER_DEG = 6371000.0 * math.pi / 180.0

T0 = time.monotonic()


def log(msg: str) -> None:
    sys.stderr.write(f"[{time.monotonic() - T0:7.1f}s] {msg}\n")
    sys.stderr.flush()


# --------------------------------------------------------------------------- #
# GTFS source (zip or directory)
# --------------------------------------------------------------------------- #


class GTFSSource:
    """Read GTFS tables from a zip file or a directory, streaming, BOM-safe."""

    def __init__(self, path: str):
        self.path = path
        self.zip: zipfile.ZipFile | None = None
        self.names: dict[str, str] = {}
        if os.path.isdir(path):
            for n in os.listdir(path):
                if n.endswith(".txt"):
                    self.names[n] = os.path.join(path, n)
        elif zipfile.is_zipfile(path):
            self.zip = zipfile.ZipFile(path)
            for info in self.zip.infolist():
                base = info.filename.rsplit("/", 1)[-1]
                if base.endswith(".txt") and not info.is_dir() and base not in self.names:
                    self.names[base] = info.filename
        else:
            raise SystemExit(f"--input must be a GTFS zip or a directory: {path}")

    def has(self, name: str) -> bool:
        return name in self.names

    def _open(self, name: str) -> io.TextIOWrapper:
        if self.zip is not None:
            raw = self.zip.open(self.names[name])
        else:
            raw = open(self.names[name], "rb")
        # utf-8-sig strips a leading BOM if present (the TFI feed sometimes has one).
        return io.TextIOWrapper(raw, encoding="utf-8-sig", newline="")

    def reader(self, name: str, required: tuple[str, ...] = ()):
        """Return (column index map, csv row iterator, file handle)."""
        f = self._open(name)
        r = csv.reader(f)
        header = next(r, None)
        if header is None:
            raise SystemExit(f"{name}: empty file")
        header = [h.strip().lstrip("﻿") for h in header]
        idx = {h: i for i, h in enumerate(header)}
        missing = [c for c in required if c not in idx]
        if missing:
            raise SystemExit(f"{name}: missing required columns {missing}; header={header}")
        return idx, r, f

    def mtime_yyyymmdd(self, name: str) -> str:
        if self.zip is not None:
            y, m, d, *_ = self.zip.getinfo(self.names[name]).date_time
            return f"{y:04d}{m:02d}{d:02d}"
        ts = os.path.getmtime(self.names[name])
        return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y%m%d")


def col(row: list[str], i: int | None) -> str:
    """Safe column accessor for possibly-short rows and optional columns."""
    if i is None or i >= len(row):
        return ""
    return row[i]


# --------------------------------------------------------------------------- #
# Geometry helpers
# --------------------------------------------------------------------------- #


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def polyline_length_m(pts: list[tuple[float, float]]) -> float:
    return sum(haversine_m(a[0], a[1], b[0], b[1]) for a, b in zip(pts, pts[1:]))


def douglas_peucker(points: list[tuple[float, float]], tol_deg: float) -> list[tuple[float, float]]:
    """Iterative Douglas-Peucker on (lat, lon) points.

    Longitude is scaled by cos(lat) so the tolerance is isotropic in metres.
    """
    n = len(points)
    if n <= 2:
        return list(points)
    cosl = math.cos(math.radians(points[0][0]))
    xy = [(lon * cosl, lat) for lat, lon in points]
    keep = [False] * n
    keep[0] = keep[-1] = True
    tol2 = tol_deg * tol_deg
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        ax, ay = xy[a]
        bx, by = xy[b]
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        maxd = -1.0
        idx = -1
        for i in range(a + 1, b):
            px, py = xy[i]
            if l2 == 0.0:
                d2 = (px - ax) ** 2 + (py - ay) ** 2
            else:
                t = ((px - ax) * dx + (py - ay) * dy) / l2
                if t < 0.0:
                    t = 0.0
                elif t > 1.0:
                    t = 1.0
                cx, cy = ax + t * dx, ay + t * dy
                d2 = (px - cx) ** 2 + (py - cy) ** 2
            if d2 > maxd:
                maxd, idx = d2, i
        if maxd > tol2:
            keep[idx] = True
            stack.append((a, idx))
            stack.append((idx, b))
    return [p for p, k in zip(points, keep) if k]


def trim_to_bbox(points: list[tuple[float, float]], bbox: tuple[float, float, float, float], margin: float):
    """Keep the run from the first to the last point inside the expanded bbox."""
    min_lat, max_lat, min_lon, max_lon = bbox
    min_lat -= margin
    max_lat += margin
    min_lon -= margin
    max_lon += margin
    inside = [i for i, (la, lo) in enumerate(points) if min_lat <= la <= max_lat and min_lon <= lo <= max_lon]
    if not inside:
        return []
    return points[inside[0] : inside[-1] + 1]


def round_coords(points: list[tuple[float, float]]) -> list[list[float]]:
    out: list[list[float]] = []
    for la, lo in points:
        p = [round(la, 5), round(lo, 5)]
        if not out or out[-1] != p:
            out.append(p)
    return out


class SegmentIndex:
    """Polyline segments on a uniform grid in local equirectangular metres.

    `nearest(p, radius)` returns the distance from `p` to the closest segment
    if one is within `radius`, else infinity. Only cells overlapping the
    search square are visited, so queries stay cheap however many lines exist.
    """

    def __init__(self, ref_lat: float, cell_m: float = 250.0):
        self.cosl = math.cos(math.radians(ref_lat))
        self.cell = cell_m
        self.grid: dict[tuple[int, int], list[tuple[float, float, float, float]]] = {}
        self.segments: list[tuple[float, float, float, float]] = []

    def xy(self, lat: float, lon: float) -> tuple[float, float]:
        return lon * self.cosl * M_PER_DEG, lat * M_PER_DEG

    def add(self, pts: list[tuple[float, float]]) -> None:
        c = self.cell
        xy = [self.xy(la, lo) for la, lo in pts]
        for (ax, ay), (bx, by) in zip(xy, xy[1:]):
            seg = (ax, ay, bx, by)
            self.segments.append(seg)
            for gx in range(math.floor(min(ax, bx) / c), math.floor(max(ax, bx) / c) + 1):
                for gy in range(math.floor(min(ay, by) / c), math.floor(max(ay, by) / c) + 1):
                    self.grid.setdefault((gx, gy), []).append(seg)

    @staticmethod
    def _seg_dist(px: float, py: float, seg: tuple[float, float, float, float]) -> float:
        ax, ay, bx, by = seg
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        t = 0.0 if l2 == 0.0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
        return math.hypot(px - ax - t * dx, py - ay - t * dy)

    def nearest(self, p: tuple[float, float], radius: float) -> float:
        px, py = p
        c = self.cell
        best = math.inf
        for gx in range(math.floor((px - radius) / c), math.floor((px + radius) / c) + 1):
            for gy in range(math.floor((py - radius) / c), math.floor((py + radius) / c) + 1):
                for seg in self.grid.get((gx, gy), ()):
                    d = self._seg_dist(px, py, seg)
                    if d < best:
                        best = d
        return best if best <= radius else math.inf

    def nearest_exact(self, p: tuple[float, float]) -> float:
        """Brute-force distance to the closest segment (for reporting)."""
        return min((self._seg_dist(p[0], p[1], s) for s in self.segments), default=math.inf)


def novel_runs(pts: list[tuple[float, float]], index: SegmentIndex) -> list[list[tuple[float, float]]]:
    """The stretches of `pts` that `index` does not already cover.

    A segment is covered when sample points every LINE_SAMPLE_METRES along it
    are all within LINE_COVER_METRES of the index. Maximal runs of uncovered
    segments are returned (each run starts and ends on the vertex where it
    leaves / rejoins the kept network), keeping only runs that stray more than
    LINE_BRANCH_METRES from it somewhere.
    """
    xy = [index.xy(la, lo) for la, lo in pts]
    probe = LINE_BRANCH_METRES + 1.0
    runs: list[list[tuple[float, float]]] = []
    start = None
    run_max = 0.0
    for i in range(len(pts) - 1):
        (ax, ay), (bx, by) = xy[i], xy[i + 1]
        n = max(1, math.ceil(math.hypot(bx - ax, by - ay) / LINE_SAMPLE_METRES))
        seg_max = max(index.nearest((ax + (bx - ax) * k / n, ay + (by - ay) * k / n), probe) for k in range(n + 1))
        if seg_max > LINE_COVER_METRES:
            if start is None:
                start, run_max = i, 0.0
            run_max = max(run_max, seg_max)
        elif start is not None:
            if run_max > LINE_BRANCH_METRES:
                runs.append(pts[start : i + 1])
            start = None
    if start is not None and run_max > LINE_BRANCH_METRES:
        runs.append(pts[start:])
    return runs


# --------------------------------------------------------------------------- #
# Small parsers
# --------------------------------------------------------------------------- #


def parse_gtfs_time(t: str) -> int:
    """'25:10:00' -> 90600. Hours may exceed 23."""
    parts = t.strip().split(":")
    if len(parts) == 2:
        parts.append("0")
    if len(parts) != 3:
        raise ValueError(t)
    h, m, s = (int(p) for p in parts)
    return h * 3600 + m * 60 + s


def parse_bbox(s: str) -> tuple[float, float, float, float]:
    try:
        a, b, c, d = (float(x) for x in s.split(","))
    except ValueError:
        raise SystemExit("--bbox must be minLat,maxLat,minLon,maxLon")
    if a >= b or c >= d:
        raise SystemExit("--bbox must be minLat,maxLat,minLon,maxLon with min < max")
    return a, b, c, d


def normalise_name(name: str) -> str:
    s = name.lower()
    s = s.replace("&", " and ")
    s = re.sub(r"\bluas\b", " ", s)
    s = re.sub(r"[^a-z0-9áéíóú]+", " ", s)
    return " ".join(s.split())


def route_kind(route_type: str, short: str, long: str) -> str:
    if route_type == "0":
        return "luas"
    if route_type == "2":
        if "dart" in short.lower() or "dart" in long.lower():
            return "dart"
        return "rail"
    return "bus"


def luas_line(short: str, long: str) -> str | None:
    s = (short + " " + long).lower()
    if "red" in s:
        return "red"
    if "green" in s:
        return "green"
    return None


def encode_json(obj) -> bytes:
    return (json.dumps(obj, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def write_bytes(path: str, data: bytes) -> int:
    with open(path, "wb") as f:
        f.write(data)
    return len(data)


def dump_json(path: str, obj) -> int:
    return write_bytes(path, encode_json(obj))


def human(n: int) -> str:
    if n >= 1 << 20:
        return f"{n / (1 << 20):.2f} MB"
    if n >= 1 << 10:
        return f"{n / (1 << 10):.1f} KB"
    return f"{n} B"


# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True, help="GTFS zip file or directory of GTFS .txt files")
    ap.add_argument("--out-dir", required=True, help="directory for transit_stops/lines/routes.json")
    ap.add_argument("--timetable-out", help="path for transit_timetable.sqlite (a .gz is written next to it)")
    ap.add_argument("--bbox", default=DEFAULT_BBOX, help=f"minLat,maxLat,minLon,maxLon (default {DEFAULT_BBOX})")
    ap.add_argument("--days", type=int, default=60, help="service window length in days (default 60)")
    ap.add_argument("--today", help="YYYY-MM-DD start of the window (default: today, UTC)")
    ap.add_argument("--no-timetable", action="store_true", help="skip the SQLite timetable")
    ap.add_argument("--no-gzip", action="store_true", help="do not gzip the timetable")
    ap.add_argument("--manifest", help="also write a manifest.json describing the .gz (built, feedVersion, sha256, bytes)")
    ap.add_argument("--drop-headsign", dest="keep_headsign", action="store_false", default=True,
                    help="omit trips.headsign to shrink the timetable")
    args = ap.parse_args(argv)

    if not args.no_timetable and not args.timetable_out:
        ap.error("--timetable-out is required unless --no-timetable is given")
    if args.days < 1:
        ap.error("--days must be >= 1")

    bbox = parse_bbox(args.bbox)
    min_lat, max_lat, min_lon, max_lon = bbox
    today = dt.date.fromisoformat(args.today) if args.today else dt.datetime.now(dt.timezone.utc).date()
    window_dates = [today + dt.timedelta(days=i) for i in range(args.days)]
    window_str = [d.strftime("%Y%m%d") for d in window_dates]
    window_set = set(window_str)
    valid_from, valid_to = window_str[0], window_str[-1]
    built = today.isoformat()

    src = GTFSSource(args.input)
    for required in ("stops.txt", "routes.txt", "trips.txt", "stop_times.txt"):
        if not src.has(required):
            raise SystemExit(f"GTFS input is missing {required}")
    if not src.has("calendar.txt") and not src.has("calendar_dates.txt"):
        raise SystemExit("GTFS input needs calendar.txt and/or calendar_dates.txt")
    os.makedirs(args.out_dir, exist_ok=True)

    timings: dict[str, float] = {}

    def mark(name: str, start: float) -> None:
        timings[name] = time.monotonic() - start

    # ---- feed_info -------------------------------------------------------- #
    feed_version = ""
    if src.has("feed_info.txt"):
        idx, rows, f = src.reader("feed_info.txt")
        for row in rows:
            feed_version = col(row, idx.get("feed_version")).strip()
            break
        f.close()
    if not feed_version:
        feed_version = src.mtime_yyyymmdd("stop_times.txt")
    log(f"feed version {feed_version}; window {valid_from}..{valid_to} ({args.days} days); bbox {bbox}")

    # ---- calendar ---------------------------------------------------------- #
    t = time.monotonic()
    service_dates: dict[str, set[str]] = {}
    if src.has("calendar.txt"):
        idx, rows, f = src.reader("calendar.txt", ("service_id", "start_date", "end_date"))
        day_cols = [idx.get(d) for d in ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")]
        for row in rows:
            sid = col(row, idx["service_id"])
            if not sid:
                continue
            start, end = col(row, idx["start_date"]).strip(), col(row, idx["end_date"]).strip()
            flags = [col(row, c).strip() == "1" for c in day_cols]
            days = service_dates.setdefault(sid, set())
            for d, ds in zip(window_dates, window_str):
                if start <= ds <= end and flags[d.weekday()]:
                    days.add(ds)
        f.close()
    if src.has("calendar_dates.txt"):
        idx, rows, f = src.reader("calendar_dates.txt", ("service_id", "date", "exception_type"))
        for row in rows:
            sid, ds, ex = col(row, idx["service_id"]), col(row, idx["date"]).strip(), col(row, idx["exception_type"]).strip()
            if not sid or ds not in window_set:
                continue
            days = service_dates.setdefault(sid, set())
            if ex == "1":
                days.add(ds)
            elif ex == "2":
                days.discard(ds)
        f.close()
    active_services = {sid for sid, days in service_dates.items() if days}
    mark("calendar", t)
    log(f"services: {len(service_dates)} defined, {len(active_services)} active in window")

    # ---- stops ------------------------------------------------------------- #
    t = time.monotonic()
    # all stops (needed for parent lookups); candidates = inside bbox, boardable
    stop_info: dict[str, tuple[str, float, float, str, str, str]] = {}  # id -> (name, lat, lon, code, loc_type, parent)
    idx, rows, f = src.reader("stops.txt", ("stop_id", "stop_name", "stop_lat", "stop_lon"))
    i_code, i_lt, i_par = idx.get("stop_code"), idx.get("location_type"), idx.get("parent_station")
    for row in rows:
        sid = col(row, idx["stop_id"])
        if not sid:
            continue
        try:
            lat, lon = float(col(row, idx["stop_lat"])), float(col(row, idx["stop_lon"]))
        except ValueError:
            continue
        stop_info[sid] = (col(row, idx["stop_name"]).strip(), lat, lon, col(row, i_code).strip(),
                          col(row, i_lt).strip() or "0", col(row, i_par).strip())
    f.close()

    def in_bbox(lat: float, lon: float) -> bool:
        return min_lat <= lat <= max_lat and min_lon <= lon <= max_lon

    candidate_ids = sorted(sid for sid, (_, lat, lon, _, lt, _) in stop_info.items() if lt == "0" and in_bbox(lat, lon))
    stop_tmp: dict[str, int] = {sid: i + 1 for i, sid in enumerate(candidate_ids)}  # provisional ints
    mark("stops", t)
    log(f"stops: {len(stop_info)} in feed, {len(candidate_ids)} inside bbox")

    # ---- routes ------------------------------------------------------------ #
    t = time.monotonic()
    route_info: dict[str, tuple[str, str, int, str, str | None]] = {}  # id -> (short, long, type, kind, luas_line)
    idx, rows, f = src.reader("routes.txt", ("route_id", "route_type"))
    for row in rows:
        rid = col(row, idx["route_id"])
        if not rid:
            continue
        short, long = col(row, idx.get("route_short_name")).strip(), col(row, idx.get("route_long_name")).strip()
        rtype_s = col(row, idx["route_type"]).strip()
        try:
            rtype = int(rtype_s)
        except ValueError:
            rtype = 3
        kind = route_kind(rtype_s, short, long)
        route_info[rid] = (short, long, rtype, kind, luas_line(short, long) if kind == "luas" else None)
    f.close()
    route_ids_sorted = sorted(route_info)
    route_tmp: dict[str, int] = {rid: i + 1 for i, rid in enumerate(route_ids_sorted)}
    route_tmp_rev = {v: k for k, v in route_tmp.items()}
    mark("routes", t)
    log(f"routes: {len(route_info)}")

    # ---- trips ------------------------------------------------------------- #
    t = time.monotonic()
    idx, rows, f = src.reader("trips.txt", ("route_id", "service_id", "trip_id"))
    i_hs, i_dir, i_shape = idx.get("trip_headsign"), idx.get("direction_id"), idx.get("shape_id")
    trip_rows: dict[str, tuple[int, str, int, str, str]] = {}  # trip_id -> (route_tmp, service_id, dir, headsign, shape_id)
    skipped_trips = 0
    for row in rows:
        tid = col(row, idx["trip_id"])
        rid = col(row, idx["route_id"])
        sid = col(row, idx["service_id"])
        if not tid or sid not in active_services or rid not in route_tmp:
            skipped_trips += 1
            continue
        d = col(row, i_dir).strip()
        trip_rows[tid] = (route_tmp[rid], sid, 1 if d == "1" else 0, col(row, i_hs).strip(), col(row, i_shape).strip())
    f.close()
    trip_ids_sorted = sorted(trip_rows)
    trip_tmp: dict[str, int] = {tid: i + 1 for i, tid in enumerate(trip_ids_sorted)}
    # per provisional trip int (index = int): route_tmp, dir, shape
    trip_route = [0] * (len(trip_ids_sorted) + 1)
    for tid, ti in trip_tmp.items():
        trip_route[ti] = trip_rows[tid][0]
    mark("trips", t)
    log(f"trips: {len(trip_rows)} on active services ({skipped_trips} skipped)")

    # ---- SQLite scaffold --------------------------------------------------- #
    build_timetable = not args.no_timetable
    conn: sqlite3.Connection | None = None
    if build_timetable:
        tt_path = args.timetable_out
        os.makedirs(os.path.dirname(os.path.abspath(tt_path)), exist_ok=True)
        for p in (tt_path, tt_path + "-journal", tt_path + ".gz"):
            if os.path.exists(p):
                os.remove(p)
        conn = sqlite3.connect(tt_path)
        conn.execute("PRAGMA journal_mode=OFF")
        conn.execute("PRAGMA synchronous=OFF")
        conn.execute("PRAGMA temp_store=FILE")
        conn.execute("PRAGMA cache_size=-200000")  # 200 MB page cache during build
        conn.execute("CREATE TABLE st_raw(stop INTEGER NOT NULL, dep INTEGER NOT NULL, trip INTEGER NOT NULL, "
                     "seq INTEGER NOT NULL)")
        conn.execute("BEGIN")

    # ---- stop_times (streamed) --------------------------------------------- #
    t = time.monotonic()
    idx, rows, f = src.reader("stop_times.txt", ("trip_id", "stop_id"))
    i_trip, i_stop = idx["trip_id"], idx["stop_id"]
    i_dep, i_arr, i_pick = idx.get("departure_time"), idx.get("arrival_time"), idx.get("pickup_type")
    i_seq = idx.get("stop_sequence")
    if i_dep is None and i_arr is None:
        raise SystemExit("stop_times.txt has neither departure_time nor arrival_time")
    stop_rows_all: dict[int, int] = {}          # provisional stop int -> row count (any pickup type)
    stop_route_pairs: set[tuple[int, int]] = set()
    trips_seen: set[int] = set()
    time_cache: dict[str, int] = {}
    batch: list[tuple[int, int, int]] = []
    n_rows = n_kept = n_dropoff_only = n_bad = 0
    trip_get, stop_get = trip_tmp.get, stop_tmp.get
    for row in rows:
        n_rows += 1
        try:
            ti = trip_get(row[i_trip])
            if ti is None:
                continue
            si = stop_get(row[i_stop])
            if si is None:
                continue
            ts = (row[i_dep] if i_dep is not None else "") or (row[i_arr] if i_arr is not None else "")
            dep = time_cache.get(ts)
            if dep is None:
                dep = time_cache[ts] = parse_gtfs_time(ts)
        except (IndexError, ValueError):
            n_bad += 1
            continue
        stop_rows_all[si] = stop_rows_all.get(si, 0) + 1
        stop_route_pairs.add((si, trip_route[ti]))
        trips_seen.add(ti)
        if i_pick is not None and len(row) > i_pick and row[i_pick] == "1":
            n_dropoff_only += 1  # terminal stop: nothing departs from here on this trip
            continue
        n_kept += 1
        if build_timetable:
            try:
                seq = int(row[i_seq]) if i_seq is not None else n_rows
            except (IndexError, ValueError):
                seq = n_rows
            batch.append((si, dep, ti, seq))
            if len(batch) >= 50000:
                conn.executemany("INSERT INTO st_raw VALUES(?,?,?,?)", batch)
                batch.clear()
                if n_kept % 1000000 < 50000:
                    log(f"  stop_times: {n_rows:,} read, {n_kept:,} kept")
    if build_timetable and batch:
        conn.executemany("INSERT INTO st_raw VALUES(?,?,?,?)", batch)
        batch.clear()
    f.close()
    mark("stop_times", t)
    log(f"stop_times: {n_rows:,} rows read; {n_kept:,} departures kept; "
        f"{n_dropoff_only:,} drop-off-only skipped; {n_bad} unparsable")

    # ---- final id assignment (contiguous, sorted by GTFS id) -------------- #
    served_tmp = sorted(stop_rows_all)                                  # provisional ints, sorted == gtfs order
    served_ids = [candidate_ids[i - 1] for i in served_tmp]
    stop_final: dict[int, int] = {tmp: i + 1 for i, tmp in enumerate(served_tmp)}

    used_routes_tmp = sorted({r for _, r in stop_route_pairs})
    route_final: dict[int, int] = {tmp: i + 1 for i, tmp in enumerate(used_routes_tmp)}
    used_route_ids = [route_tmp_rev[r] for r in used_routes_tmp]

    trips_final_tmp = sorted(trips_seen)  # every active trip touching a bbox stop (drives shape selection)
    log(f"after pruning: {len(served_ids)} stops, {len(used_route_ids)} routes, {len(trips_final_tmp)} trips")

    # ---- trip-pattern dedupe (lossless for departure queries) ------------- #
    # TFI publishes many trips that differ only by service_id (term-time /
    # holiday / Saturday variants with identical stops and times). Trips with an
    # identical (route, dir, headsign, ordered stop+dep pattern) are merged into
    # one trip whose service runs on the union of the members' days. The schema
    # never exposes GTFS trip ids, so the app sees exactly the same departures.
    rep_tmps: list[int] = []                           # representative trip per pattern (provisional ints)
    trip_to_rep: dict[int, int] = {}                   # member -> representative (provisional ints)
    rep_service_days: dict[int, frozenset[str]] = {}   # representative -> dates it runs
    service_names: dict[frozenset[str], str] = {}      # date set -> service gtfs_id ("A" or "A+B+C")
    if build_timetable:
        assert conn is not None
        t = time.monotonic()
        sig_by_trip: dict[int, bytes] = {}
        cur_trip = None
        h = None
        for trip, stop, dep in conn.execute("SELECT trip, stop, dep FROM st_raw ORDER BY trip, seq, stop, dep"):
            if trip != cur_trip:
                if cur_trip is not None:
                    sig_by_trip[cur_trip] = h.digest()
                cur_trip = trip
                h = hashlib.blake2b(digest_size=16)
            h.update(b"%d:%d," % (stop, dep))
        if cur_trip is not None:
            sig_by_trip[cur_trip] = h.digest()
        groups: dict[tuple, list[int]] = {}
        for tmp in sorted(sig_by_trip):
            rt, _, d, hs, _ = trip_rows[trip_ids_sorted[tmp - 1]]
            groups.setdefault((rt, d, hs, sig_by_trip[tmp]), []).append(tmp)
        for members in sorted(groups.values()):  # members ascending; sorted by smallest member -> deterministic
            rep = members[0]
            rep_tmps.append(rep)
            member_services = sorted({trip_rows[trip_ids_sorted[m - 1]][1] for m in members})
            days = frozenset().union(*(service_dates[s] for s in member_services))
            service_names.setdefault(days, "+".join(member_services))
            rep_service_days[rep] = days
            for m in members:
                trip_to_rep[m] = rep
        mark("patterns", t)
        log(f"trip patterns: {len(sig_by_trip)} trips with departures -> {len(rep_tmps)} unique patterns, "
            f"{len(service_names)} services after merging")
    rep_tmps.sort()
    trip_final: dict[int, int] = {tmp: i + 1 for i, tmp in enumerate(rep_tmps)}
    services_sorted = sorted(service_names.items(), key=lambda kv: kv[1])  # [(days, name)] by name
    service_final_by_days: dict[frozenset[str], int] = {days: i + 1 for i, (days, _) in enumerate(services_sorted)}

    # ---- per-stop classification ------------------------------------------ #
    stop_kinds: dict[int, set[str]] = {}
    stop_luas_lines: dict[int, dict[str, int]] = {}
    for si, rt in stop_route_pairs:
        _, _, _, kind, lline = route_info[route_tmp_rev[rt]]
        stop_kinds.setdefault(si, set()).add(kind)
        if kind == "luas" and lline:
            stop_luas_lines.setdefault(si, {})[lline] = stop_luas_lines.get(si, {}).get(lline, 0) + 1

    # ---- shapes ------------------------------------------------------------ #
    t = time.monotonic()
    # representative shape per (route_tmp, dir): the shape used by most trips
    shape_use: dict[tuple[int, int], dict[str, int]] = {}
    for tmp in trips_final_tmp:
        rt, _, d, _, shape_id = trip_rows[trip_ids_sorted[tmp - 1]]
        if shape_id:
            su = shape_use.setdefault((rt, d), {})
            su[shape_id] = su.get(shape_id, 0) + 1
    rep_shape: dict[tuple[int, int], str] = {}
    for key, uses in shape_use.items():
        rep_shape[key] = sorted(uses.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]

    # transit_lines.json keys: "luas-red" / "luas-green" / "dart" / "rail-<route id>".
    # Every distinct shape of an active trip counts, not just the dominant one
    # per direction: DART branches (Howth), Luas spurs (Saggart, Broombridge)
    # and rail short workings (M3 Parkway, Docklands) only exist as minority shapes.
    line_meta: dict[str, dict] = {}
    line_shapes: dict[str, set[str]] = {}
    for (rt, _), uses in shape_use.items():
        rid = route_tmp_rev[rt]
        short, long, _, kind, lline = route_info[rid]
        if kind == "luas" and lline:
            lkey = f"luas-{lline}"
            line_meta[lkey] = {"id": lkey, "kind": "luas", "line": lline, "name": f"Luas {lline.capitalize()} Line"}
        elif kind == "dart":
            lkey = "dart"
            line_meta[lkey] = {"id": lkey, "kind": "dart", "name": "DART"}
        elif kind == "rail":
            lkey = f"rail-{rid}"
            line_meta[lkey] = {"id": lkey, "kind": "rail", "name": long or short or rid}
        else:
            continue
        line_shapes.setdefault(lkey, set()).update(uses)
    needed_shapes = set(rep_shape.values()).union(*line_shapes.values())
    shape_pts: dict[str, list[tuple[float, float, float]]] = {s: [] for s in needed_shapes}
    if needed_shapes and src.has("shapes.txt"):
        idx, rows, f = src.reader("shapes.txt", ("shape_id", "shape_pt_lat", "shape_pt_lon"))
        i_sid, i_lat, i_lon, i_seq = idx["shape_id"], idx["shape_pt_lat"], idx["shape_pt_lon"], idx.get("shape_pt_sequence")
        n_shape_rows = 0
        for row in rows:
            n_shape_rows += 1
            lst = shape_pts.get(row[i_sid])
            if lst is None:
                continue
            try:
                seq = float(row[i_seq]) if i_seq is not None and row[i_seq] else float(len(lst))
                lst.append((seq, float(row[i_lat]), float(row[i_lon])))
            except (IndexError, ValueError):
                continue
        f.close()
        log(f"shapes: {n_shape_rows:,} rows read for {len(needed_shapes)} shapes "
            f"(per-route representatives + every Luas/DART/rail shape)")
    elif needed_shapes:
        log("shapes.txt missing: no polylines will be emitted")

    simplified: dict[str, list[tuple[float, float]]] = {}
    raw_pts = simp_pts = 0
    for sid, lst in shape_pts.items():
        if not lst:
            continue
        lst.sort(key=lambda p: p[0])
        pts = [(la, lo) for _, la, lo in lst]
        pts = trim_to_bbox(pts, bbox, LINE_TRIM_MARGIN_DEG)
        if len(pts) < 2:
            continue
        raw_pts += len(pts)
        s = douglas_peucker(pts, DP_TOLERANCE_DEG)
        simp_pts += len(s)
        simplified[sid] = s
    mark("shapes", t)
    log(f"shapes: {raw_pts:,} points simplified to {simp_pts:,}")

    # ---- transit_stops.json ----------------------------------------------- #
    t = time.monotonic()
    primary_kind: dict[int, str] = {}
    for si in served_tmp:
        kinds = stop_kinds.get(si, set())
        primary_kind[si] = sorted(kinds, key=lambda k: KIND_PRIORITY[k])[0] if kinds else "bus"

    # Luas dedupe: same normalised name within 250 m -> keep the most-served, merge ids into altIds
    alt_ids: dict[int, list[str]] = {}
    merged_away: set[int] = set()
    luas_groups: dict[str, list[int]] = {}
    for si in served_tmp:
        if primary_kind[si] == "luas":
            luas_groups.setdefault(normalise_name(stop_info[candidate_ids[si - 1]][0]), []).append(si)
    for members in luas_groups.values():
        if len(members) < 2:
            continue
        members.sort(key=lambda s: (-stop_rows_all[s], candidate_ids[s - 1]))
        kept: list[int] = []
        for s in members:
            _, la, lo, _, _, _ = stop_info[candidate_ids[s - 1]]
            target = None
            for k in kept:
                _, kla, klo, _, _, _ = stop_info[candidate_ids[k - 1]]
                if haversine_m(la, lo, kla, klo) <= LUAS_DEDUPE_METRES:
                    target = k
                    break
            if target is None:
                kept.append(s)
            else:
                alt_ids.setdefault(target, []).append(candidate_ids[s - 1])
                merged_away.add(s)

    # Parent stations (none in the current TFI feed, but handle generically):
    # a station whose boardable children are served gets emitted once, with the
    # children folded into altIds; the children themselves are not emitted twice.
    parent_children: dict[str, list[int]] = {}
    for si in served_tmp:
        parent = stop_info[candidate_ids[si - 1]][5]
        if parent and parent in stop_info and stop_info[parent][4] == "1":
            parent_children.setdefault(parent, []).append(si)

    stops_out = []
    kind_counts: dict[str, int] = {}
    seen_ids: set[str] = set()

    def stop_entry(gtfs_id: str, name: str, lat: float, lon: float, kinds: set[str], luas_votes: dict[str, int],
                   code: str, alts: list[str]):
        kind = sorted(kinds, key=lambda k: KIND_PRIORITY[k])[0] if kinds else "bus"
        e: dict = {"id": gtfs_id, "name": name, "lat": round(lat, 5), "lon": round(lon, 5), "kind": kind}
        if kind == "bus" and code and code != "0":
            e["code"] = code
        if kind == "luas" and luas_votes:
            e["line"] = sorted(luas_votes.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
        if len(kinds) > 1:
            e["kinds"] = sorted(kinds, key=lambda k: KIND_PRIORITY[k])
        if alts:
            e["altIds"] = sorted(alts)
        kind_counts[kind] = kind_counts.get(kind, 0) + 1
        return e

    emitted_children: set[int] = set()
    for parent, children in parent_children.items():
        name, lat, lon, code, _, _ = stop_info[parent]
        kinds: set[str] = set()
        votes: dict[str, int] = {}
        for c in children:
            kinds |= stop_kinds.get(c, set())
            for ln, n in stop_luas_lines.get(c, {}).items():
                votes[ln] = votes.get(ln, 0) + n
            emitted_children.add(c)
        stops_out.append(stop_entry(parent, name, lat, lon, kinds, votes, code,
                                    [candidate_ids[c - 1] for c in children]))
    for si in served_tmp:
        if si in merged_away or si in emitted_children:
            continue
        gtfs_id = candidate_ids[si - 1]
        name, lat, lon, code, _, _ = stop_info[gtfs_id]
        stops_out.append(stop_entry(gtfs_id, name, lat, lon, stop_kinds.get(si, set()),
                                    stop_luas_lines.get(si, {}), code, alt_ids.get(si, [])))
    stops_out.sort(key=lambda e: e["id"])
    for e in stops_out:  # self-check
        if e["id"] in seen_ids:
            raise SystemExit(f"duplicate stop id {e['id']}")
        seen_ids.add(e["id"])
        if not in_bbox(e["lat"], e["lon"]) and e["id"] not in parent_children:
            raise SystemExit(f"stop {e['id']} outside bbox")
        if not e["kind"]:
            raise SystemExit(f"stop {e['id']} has empty kind")
    stops_json = {"version": 1, "built": built, "feedVersion": feed_version, "stops": stops_out}
    # The three JSONs are written together after the coverage gate passes.
    stops_data = encode_json(stops_json)
    stops_bytes = len(stops_data)
    mark("stops_json", t)
    log(f"transit_stops.json: {len(stops_out)} stops, {human(stops_bytes)}; kinds {kind_counts}; "
        f"{len(merged_away)} Luas platforms merged")

    # ---- transit_routes.json ---------------------------------------------- #
    t = time.monotonic()
    routes_out = []
    for rid in used_route_ids:
        short, long, rtype, _, _ = route_info[rid]
        routes_out.append({"id": rid, "short": short, "long": long, "type": rtype})
    routes_out.sort(key=lambda e: e["id"])
    routes_data = encode_json({"version": 1, "routes": routes_out})
    routes_bytes = len(routes_data)
    mark("routes_json", t)
    log(f"transit_routes.json: {len(routes_out)} routes, {human(routes_bytes)}")

    # ---- transit_lines.json ----------------------------------------------- #
    t = time.monotonic()

    # Dedupe scope: each Luas line on its own, the DART, and all rail routes
    # together (Irish Rail publishes inbound and outbound as separate routes
    # over the same track). Within a scope, shapes go longest first; each one
    # contributes only the stretches nothing kept so far already covers, so a
    # branch becomes its own short entry that starts at the junction.
    ref_lat = (min_lat + max_lat) / 2

    def scope_of(lkey: str) -> str:
        return "rail" if lkey.startswith("rail-") else lkey

    candidates: dict[str, list[tuple[float, str, str]]] = {}  # scope -> [(length, line key, shape id)]
    for lkey, sids in line_shapes.items():
        for sid in sids:
            pts = simplified.get(sid)
            if pts:
                candidates.setdefault(scope_of(lkey), []).append((polyline_length_m(pts), lkey, sid))
    pieces: dict[str, list[list[list[float]]]] = {}  # line key -> rounded polylines, in acceptance order
    n_shapes_used = 0
    for scope in sorted(candidates):
        index = SegmentIndex(ref_lat)
        for _, lkey, sid in sorted(candidates[scope], key=lambda c: (-c[0], c[1], c[2])):
            runs = novel_runs(simplified[sid], index)
            if runs:
                n_shapes_used += 1
            for run in runs:
                coords = round_coords(run)
                if len(coords) < 2:
                    continue
                index.add([(la, lo) for la, lo in coords])
                pieces.setdefault(lkey, []).append(coords)
    lines_out = []
    for lkey in sorted(pieces):
        for n, coords in enumerate(pieces[lkey], start=1):
            entry = dict(line_meta[lkey])
            if n > 1:
                entry["id"] = f"{lkey}-{n}"
            entry["coords"] = coords
            lines_out.append(entry)
    line_ids = [e["id"] for e in lines_out]
    if len(set(line_ids)) != len(line_ids):
        raise SystemExit("duplicate line id in transit_lines.json")
    lines_data = encode_json({"version": 1, "lines": lines_out})
    lines_bytes = len(lines_data)
    n_line_points = sum(len(e["coords"]) for e in lines_out)
    mark("lines_json", t)
    log(f"transit_lines.json: {len(lines_out)} entries from {n_shapes_used} of "
        f"{sum(len(c) for c in candidates.values())} shapes, {n_line_points:,} points, {human(lines_bytes)}")

    # ---- coverage gate ----------------------------------------------------- #
    # Every DART / rail / Luas station must sit within COVERAGE_MAX_METRES of a
    # line of its kind (a Luas stop: of its own Red/Green line), otherwise the
    # map shows stations with no track and the build fails. Stops are inside
    # the bbox and lines are only trimmed outside bbox + LINE_TRIM_MARGIN_DEG,
    # so no station is legitimately off its line.
    gate_index: dict[str, SegmentIndex] = {}
    for e in lines_out:
        for gk in {e["kind"], f"luas-{e['line']}" if e["kind"] == "luas" and e.get("line") else e["kind"]}:
            gate_index.setdefault(gk, SegmentIndex(ref_lat)).add([(la, lo) for la, lo in e["coords"]])
    coverage_max: dict[str, float] = {}
    offenders = []
    for e in stops_out:
        kind = e["kind"]
        if kind not in GATED_KINDS:
            continue
        gk = f"luas-{e['line']}" if kind == "luas" and e.get("line") in ("red", "green") else kind
        index = gate_index.get(gk)
        p = index.xy(e["lat"], e["lon"]) if index else (0.0, 0.0)
        d = index.nearest(p, COVERAGE_MAX_METRES) if index else math.inf
        if d == math.inf and index is not None:
            d = index.nearest_exact(p)
        coverage_max[gk] = max(coverage_max.get(gk, 0.0), d)
        if d > COVERAGE_MAX_METRES:
            offenders.append((d, gk, e["id"], e["name"]))
    log("coverage: max station-to-line distance " +
        ", ".join(f"{k}={v:.0f} m" for k, v in sorted(coverage_max.items())))
    if offenders:
        for d, gk, sid, name in sorted(offenders, key=lambda o: (-o[0], o[2])):
            sys.stderr.write(f"  uncovered {gk:10s} {sid:14s} {name}: {d:,.0f} m from the nearest line\n")
        raise SystemExit(f"coverage gate failed: {len(offenders)} station(s) more than "
                         f"{COVERAGE_MAX_METRES:.0f} m from a line of their kind; nothing written")

    stops_bytes = write_bytes(os.path.join(args.out_dir, "transit_stops.json"), stops_data)
    routes_bytes = write_bytes(os.path.join(args.out_dir, "transit_routes.json"), routes_data)
    lines_bytes = write_bytes(os.path.join(args.out_dir, "transit_lines.json"), lines_data)

    # ---- SQLite timetable -------------------------------------------------- #
    tt_bytes = gz_bytes = 0
    n_stop_times = n_service_days = 0
    sha256 = ""
    if build_timetable:
        assert conn is not None
        t = time.monotonic()
        c = conn
        c.executescript("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE stops(id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL);
            CREATE UNIQUE INDEX stops_gtfs ON stops(gtfs_id);
            CREATE TABLE routes(id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL, short TEXT, long TEXT, type INTEGER NOT NULL);
            CREATE TABLE services(id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL);
            CREATE TABLE service_days(date TEXT NOT NULL, service INTEGER NOT NULL, PRIMARY KEY(date, service)) WITHOUT ROWID;
            CREATE TABLE trips(id INTEGER PRIMARY KEY, route INTEGER NOT NULL, service INTEGER NOT NULL, dir INTEGER NOT NULL, headsign TEXT);
            CREATE TABLE stop_times(stop INTEGER NOT NULL, dep INTEGER NOT NULL, trip INTEGER NOT NULL, PRIMARY KEY(stop, dep, trip)) WITHOUT ROWID;
            CREATE TABLE stop_routes(stop INTEGER NOT NULL, route INTEGER NOT NULL, PRIMARY KEY(stop, route)) WITHOUT ROWID;
            CREATE TABLE route_shapes(route INTEGER NOT NULL, dir INTEGER NOT NULL, polyline BLOB NOT NULL, PRIMARY KEY(route, dir)) WITHOUT ROWID;
            CREATE TABLE stop_map(old INTEGER PRIMARY KEY, new INTEGER NOT NULL);
            CREATE TABLE trip_map(old INTEGER PRIMARY KEY, new INTEGER NOT NULL);
        """)
        c.executemany("INSERT INTO meta VALUES(?,?)", [
            ("schemaVersion", str(SCHEMA_VERSION)), ("built", built), ("feedVersion", feed_version),
            ("validFrom", valid_from), ("validTo", valid_to), ("bbox", args.bbox),
        ])
        c.executemany("INSERT INTO stops VALUES(?,?)", [(stop_final[tmp], candidate_ids[tmp - 1]) for tmp in served_tmp])
        c.executemany("INSERT INTO routes VALUES(?,?,?,?,?)", [
            (route_final[route_tmp[rid]], rid, route_info[rid][0], route_info[rid][1], route_info[rid][2])
            for rid in used_route_ids
        ])
        c.executemany("INSERT INTO services VALUES(?,?)",
                      [(service_final_by_days[days], name) for days, name in services_sorted])
        sd_rows = sorted((d, service_final_by_days[days]) for days, _ in services_sorted for d in days)
        c.executemany("INSERT INTO service_days VALUES(?,?)", sd_rows)
        n_service_days = len(sd_rows)
        c.executemany("INSERT INTO trips VALUES(?,?,?,?,?)", [
            (trip_final[tmp], route_final[trip_rows[trip_ids_sorted[tmp - 1]][0]],
             service_final_by_days[rep_service_days[tmp]], trip_rows[trip_ids_sorted[tmp - 1]][2],
             (trip_rows[trip_ids_sorted[tmp - 1]][3] or None) if args.keep_headsign else None)
            for tmp in rep_tmps
        ])
        c.executemany("INSERT INTO stop_routes VALUES(?,?)",
                      sorted((stop_final[s], route_final[r]) for s, r in stop_route_pairs))
        c.executemany("INSERT INTO route_shapes VALUES(?,?,?)", sorted(
            (route_final[rt], d, json.dumps(round_coords(simplified[sid]), separators=(",", ":")).encode("utf-8"))
            for (rt, d), sid in rep_shape.items() if sid in simplified and rt in route_final
        ))
        c.executemany("INSERT INTO stop_map VALUES(?,?)", stop_final.items())
        c.executemany("INSERT INTO trip_map VALUES(?,?)", [(m, trip_final[rep]) for m, rep in trip_to_rep.items()])
        log("timetable: remapping stop_times into final ids (sorted insert)")
        c.execute("""
            INSERT OR IGNORE INTO stop_times(stop, dep, trip)
            SELECT sm.new, r.dep, tm.new FROM st_raw r
              JOIN stop_map sm ON sm.old = r.stop
              JOIN trip_map tm ON tm.old = r.trip
            ORDER BY 1, 2, 3
        """)
        c.execute("DROP TABLE st_raw")
        c.execute("DROP TABLE stop_map")
        c.execute("DROP TABLE trip_map")
        c.execute("COMMIT")
        n_stop_times = c.execute("SELECT count(*) FROM stop_times").fetchone()[0]
        log(f"timetable: {n_stop_times:,} stop_times rows; VACUUM")
        c.execute("VACUUM")
        c.close()
        tt_bytes = os.path.getsize(args.timetable_out)
        mark("timetable", t)
        if not args.no_gzip:
            t = time.monotonic()
            gz_path = args.timetable_out + ".gz"
            h = hashlib.sha256()
            with open(args.timetable_out, "rb") as fin, open(gz_path, "wb") as fout:
                with gzip.GzipFile(fileobj=fout, mode="wb", compresslevel=9, mtime=0) as gz:
                    while True:
                        chunk = fin.read(1 << 20)
                        if not chunk:
                            break
                        gz.write(chunk)
            with open(gz_path, "rb") as fin:
                while True:
                    chunk = fin.read(1 << 20)
                    if not chunk:
                        break
                    h.update(chunk)
            sha256 = h.hexdigest()
            gz_bytes = os.path.getsize(gz_path)
            mark("gzip", t)
            if args.manifest:
                dump_json(args.manifest, {"built": built, "feedVersion": feed_version, "sha256": sha256,
                                          "bytes": gz_bytes, "rawBytes": tt_bytes, "schemaVersion": SCHEMA_VERSION,
                                          "validFrom": valid_from, "validTo": valid_to})

    # ---- summary (stdout) ------------------------------------------------- #
    total = time.monotonic() - T0
    print("transit bundle summary")
    print(f"  feed version     {feed_version}")
    print(f"  window           {valid_from}..{valid_to} ({args.days} days), built {built}")
    print(f"  stops            {len(stops_out)} emitted ({', '.join(f'{k}={v}' for k, v in sorted(kind_counts.items()))}); "
          f"{len(served_ids)} served ids in bbox; {len(merged_away)} Luas platforms merged")
    print(f"  routes           {len(routes_out)}")
    print(f"  lines            {len(lines_out)} entries ({n_line_points:,} points); coverage max "
          + ", ".join(f"{k}={v:.0f} m" for k, v in sorted(coverage_max.items())))
    print(f"  trips            {len(trips_final_tmp)} active in bbox -> {len(rep_tmps)} unique patterns "
          f"(services {len(services_sorted)}, service_days {n_service_days})")
    print(f"  stop_times       {n_rows:,} read -> {n_kept:,} departures ({n_dropoff_only:,} drop-off-only dropped)")
    print(f"  transit_stops.json   {stops_bytes:>10,} B  ({human(stops_bytes)})")
    print(f"  transit_lines.json   {lines_bytes:>10,} B  ({human(lines_bytes)})")
    print(f"  transit_routes.json  {routes_bytes:>10,} B  ({human(routes_bytes)})")
    if build_timetable:
        print(f"  timetable sqlite     {tt_bytes:>10,} B  ({human(tt_bytes)}), {n_stop_times:,} stop_times rows")
        if gz_bytes:
            print(f"  timetable sqlite.gz  {gz_bytes:>10,} B  ({human(gz_bytes)}) sha256={sha256}")
    print("  timings          " + ", ".join(f"{k}={v:.1f}s" for k, v in timings.items()) + f", total={total:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
