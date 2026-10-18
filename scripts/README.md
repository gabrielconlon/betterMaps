# Offline transit bundle pipeline

`build_transit_bundle.py` turns the TFI GTFS feed into the files the app ships /
downloads for offline Dublin transit:

| Output | Lives | Size (2026-10-18 feed) |
| --- | --- | --- |
| `transit_stops.json` | `BetterMaps/Resources/Transit/` (committed, bundled) | 544 KB (target <= 800 KB) |
| `transit_lines.json` | same | 20 KB (target <= 300 KB) |
| `transit_routes.json` | same | 26 KB (target <= 100 KB) |
| `transit_timetable.sqlite(.gz)` | `scripts/out/` locally (gitignored); published to the `transit-data` GitHub release | 30.2 MB raw / 12.6 MB gz (targets 60 / 15 MB) |

The app reads the timetable from
`https://github.com/gabrielconlon/betterMaps/releases/download/transit-data/transit_timetable.sqlite.gz`
and the matching `manifest.json` (`{"built","feedVersion","sha256","bytes","schemaVersion":1, ...}`)
next to it.

Python 3.12+ standard library only. No third-party packages.

## Running it

```sh
# fetch the feed into a scratch dir (GTFS_All.zip; GTFS_Realtime.zip is the fallback)
curl -sSfL -o /tmp/gtfs_in/GTFS_All.zip https://www.transportforireland.ie/transitData/Data/GTFS_All.zip

python3 -I scripts/build_transit_bundle.py \
  --input /tmp/gtfs_in/GTFS_All.zip \
  --out-dir BetterMaps/Resources/Transit \
  --timetable-out scripts/out/transit_timetable.sqlite \
  --manifest scripts/out/manifest.json
```

Flags:

| Flag | Default | Meaning |
| --- | --- | --- |
| `--input` | required | GTFS zip, or a directory of GTFS `.txt` files (used for the test fixture) |
| `--out-dir` | required | where the three JSON files go |
| `--timetable-out` | required unless `--no-timetable` | SQLite path; `<path>.gz` is written next to it unless `--no-gzip` |
| `--bbox` | `53.15,53.65,-6.65,-5.95` | `minLat,maxLat,minLon,maxLon` |
| `--days` | `60` | service window starting at `--today` (inclusive) |
| `--today` | now (UTC) | `YYYY-MM-DD`; pin it for reproducible builds and tests |
| `--no-timetable` | | only build the JSON files |
| `--no-gzip` | | skip the `.gz` |
| `--manifest PATH` | | also write the release manifest JSON for the `.gz` |
| `--drop-headsign` | | omit `trips.headsign` (only ~1 MB raw; not needed today) |

Progress goes to stderr, a summary (counts, sizes, timings) to stdout. The real
feed (9.35M stop_times rows, 160 MB zip) builds in about 20 s on an M-series Mac
and about a minute on a GitHub runner.

Treat a downloaded feed as untrusted data: keep it in its own directory and run
the script with `python3 -I` (as above) so nothing from that directory can be
imported.

## What the script does

1. **Calendar**: expands `calendar.txt` over the window, applies
   `calendar_dates.txt` (type 1 adds, type 2 removes). Services with no day in
   the window are dropped, and with them their trips.
2. **Stops**: keeps `location_type` 0 stops inside the bbox that have at least
   one stop_time on an active trip. A parent station (`location_type` 1) whose
   children are served is emitted once with the children folded into `altIds`
   (the current TFI feed has no parent stations).
3. **Kind** per stop from the route types that serve it: `0` → `luas`,
   `2` + "DART" in the route name → `dart`, other `2` → `rail`, else `bus`.
   Multi-kind stops get the highest-priority kind (`dart > rail > luas > bus`)
   as `kind` plus a `kinds` array (13 stops today, e.g. Connolly is
   `dart` + `rail`).
4. **Luas**: `line` is `red`/`green` from the route name. The feed has two
   same-named platforms per Luas stop; those within 250 m are merged into the
   platform with the most stop_times, the other id goes into `altIds`
   (61 merges today). `altIds` are still real stops in the SQLite `stops`
   table, so departures for a merged stop = departures for `id` ∪ `altIds`.
5. **stop_times**: streamed once with `csv.reader`, inserted in 50k-row batches
   into a scratch table inside one transaction (`journal_mode=OFF`,
   `synchronous=OFF`), then copied sorted into the `WITHOUT ROWID` primary key.
   Rows with `pickup_type=1` (drop-off only, i.e. the terminal stop of a trip)
   are not departures and are skipped (~194k rows), but they still count
   towards stop classification and `stop_routes`.
6. **Trip-pattern merge (lossless)**: TFI publishes many trips that are
   identical in route, direction, headsign and the full ordered (stop, dep)
   sequence and differ only by `service_id` (term-time / holiday / Saturday
   variants). Those are merged into one trip whose service runs on the union of
   the members' days; merged services get `gtfs_id = "A+B+C"`. 126,575 trips
   collapse to 43,587 patterns and 5.2M stop_times rows to 1.93M, which is what
   brings the timetable from 79 MB / 22.9 MB gz down to 30 MB / 12.6 MB gz.
   Departure queries return exactly the same rows either way; the schema never
   exposed GTFS trip ids.
7. **Shapes**: the shape used by the most trips per (route, direction) is
   loaded from `shapes.txt`, trimmed to the bbox expanded by 0.05° (so
   inter-city rail lines stop a few km outside Dublin instead of running to
   Cork), and Douglas–Peucker-simplified with a 0.00007° (~8 m) tolerance.
   `transit_lines.json` has one polyline per Luas line / DART / rail route
   (directions merged by taking the longest); the SQLite `route_shapes` table
   has one per route and direction, for every route including buses.
8. All outputs are sorted by id and written with compact separators, so a
   rebuild from the same feed and `--today` is byte-identical.

Luas branches: `luas-red` is the single longest Red shape (Saggart–The Point);
the Tallaght spur is not in `transit_lines.json`, but it is in `route_shapes`.

## JSON schemas

`transit_stops.json`

```json
{"version":1,"built":"2026-10-18","feedVersion":"<feed_info.feed_version>",
 "stops":[
  {"id":"8220DB000002","name":"Parnell Square West","lat":53.35224,"lon":-6.26372,"kind":"bus","code":"2"},
  {"id":"8220GA00408","name":"Abbey St.","lat":53.3485,"lon":-6.25845,"kind":"luas","line":"red","altIds":["8220GA00409"]},
  {"id":"8220IR0007","name":"Connolly","lat":53.35125,"lon":-6.2497,"kind":"dart","kinds":["dart","rail"]},
  {"id":"8260IR0058","name":"Maynooth","lat":53.37804,"lon":-6.59057,"kind":"rail"}]}
```

`code` only on bus stops (the plate number); `line` only on Luas stops;
`kinds` only when more than one; `altIds` only when ids were merged.

`transit_lines.json`

```json
{"version":1,"lines":[
  {"id":"luas-red","kind":"luas","line":"red","name":"Luas Red Line","coords":[[53.34768,-6.26528],...]},
  {"id":"luas-green","kind":"luas","line":"green","name":"Luas Green Line","coords":[...]},
  {"id":"dart","kind":"dart","name":"DART","coords":[...]},
  {"id":"rail-DUB-MAYNOOTH-O","kind":"rail","name":"Dublin - Maynooth","coords":[...]}]}
```

`transit_routes.json`

```json
{"version":1,"routes":[{"id":"10000 RED g a","short":"Red","long":"The Point - Tallaght","type":0},
                       {"id":"978 39A a","short":"39A","long":"Ongar - UCD","type":3}]}
```

## SQLite schema (`schemaVersion` 1)

```sql
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);   -- schemaVersion, built, feedVersion, validFrom, validTo, bbox
CREATE TABLE stops(id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL);
CREATE UNIQUE INDEX stops_gtfs ON stops(gtfs_id);
CREATE TABLE routes(id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL, short TEXT, long TEXT, type INTEGER NOT NULL);
CREATE TABLE services(id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL);   -- "A" or merged "A+B+C"
CREATE TABLE service_days(date TEXT NOT NULL, service INTEGER NOT NULL, PRIMARY KEY(date, service)) WITHOUT ROWID;  -- YYYYMMDD
CREATE TABLE trips(id INTEGER PRIMARY KEY, route INTEGER NOT NULL, service INTEGER NOT NULL, dir INTEGER NOT NULL, headsign TEXT);
CREATE TABLE stop_times(stop INTEGER NOT NULL, dep INTEGER NOT NULL, trip INTEGER NOT NULL, PRIMARY KEY(stop, dep, trip)) WITHOUT ROWID;
CREATE TABLE stop_routes(stop INTEGER NOT NULL, route INTEGER NOT NULL, PRIMARY KEY(stop, route)) WITHOUT ROWID;
CREATE TABLE route_shapes(route INTEGER NOT NULL, dir INTEGER NOT NULL, polyline BLOB NOT NULL, PRIMARY KEY(route, dir)) WITHOUT ROWID; -- UTF-8 JSON [[lat,lon],...]
```

`dep` is seconds after midnight of the *service day* and may exceed 86400
(max in the current feed is 111000 = 06:50 next morning). Departures board
query for GTFS stop `S` on calendar day `D` from time `T` seconds:

```sql
SELECT st.dep, r.short, t.headsign, t.dir
FROM stop_times st
JOIN stops s        ON s.id = st.stop
JOIN trips t        ON t.id = st.trip
JOIN routes r       ON r.id = t.route
JOIN service_days d ON d.service = t.service AND d.date = :D
WHERE s.gtfs_id IN (:S, :altIds...) AND st.dep >= :T
ORDER BY st.dep LIMIT 20;
```

For the early-morning hours also run the same query with `d.date = D-1` and
`st.dep >= T + 86400` to pick up after-midnight trips of the previous service
day. Integer ids are contiguous and assigned in sorted GTFS-id order; they are
only stable within one build, so always join through `stops.gtfs_id`.

## Test fixture: `BetterMaps-Tests/Fixtures/gtfs_mini/`

A hand-made GTFS directory (`shapes.txt` deliberately starts with a UTF-8 BOM,
and its rows are out of sequence order). Regenerate the committed SQLite with:

```sh
python3 -I scripts/build_transit_bundle.py \
  --input BetterMaps-Tests/Fixtures/gtfs_mini --out-dir /tmp/mini_out \
  --timetable-out BetterMaps-Tests/Fixtures/gtfs_mini/timetable_mini.sqlite \
  --no-gzip --today 2026-10-18
```

Contents: 9 stops (3 bus, 3 Luas platforms, 2 DART, Greystones outside the
bbox), 3 routes, 7 trips, services `WK` (Mon–Fri), `DAILY`, `SAT`, one
`calendar_dates` exception (`WK` removed on 2026-10-26).

Expected numbers with `--today 2026-10-18` (window 20261018–20261216), for
the Swift tests to assert:

| Check | Expected |
| --- | --- |
| `meta` | `schemaVersion=1`, `built=2026-10-18`, `feedVersion=mini-2026-10`, `validFrom=20261018`, `validTo=20261216` |
| `count(*) stops` | 8 (`8350IR0122` Greystones excluded; both Abbey St platforms kept) |
| `count(*) routes` | 3 (`MINI-39A` type 3, `MINI-DART` type 2, `MINI-RED` type 0) |
| `services` | 3: `DAILY` (60 days), `SAT+WK` (50 days, merged from trips T1+T7), `WK` (42 days) |
| `count(*) service_days` | 152; no `WK`/`SAT+WK` row on `20261026` |
| `count(*) trips` | 6 (T1 and T7 merged; T2, T3, T4, T5, T6) |
| `count(*) stop_times` | 9 (18 GTFS rows − 6 drop-off-only − 3 merged duplicates) |
| departures at `8220DB000002` on 2026-10-20 (Tue) with `dep >= 28800` | `[29100, 90600]`, both `39A` headsign `UCD` |
| the `25:10:00` trip | `dep = 90600` at `8220DB000002`, `90780` at `8220DB000003` |
| departures at `8220DB000002` on 2026-10-26 (exception) | none |
| departures at `8220DB000002` on 2026-10-24 (Sat) | `[29100]` only, service `SAT+WK` |
| `8220DB000004` (Eden Quay, terminus) | in `stops` and `stop_routes`, 0 rows in `stop_times` |
| departures at `8220IR0025` (Tara Street) | `[28500]` DART headsign `Greystones` |
| `route_shapes` | 4 rows; `MINI-39A` dir 0 has 4 points (DP dropped one), DART polyline keeps Greystones (bbox margin) |
| `transit_stops.json` | 7 stops: bus `8220DB000002/3/4` with codes `2/3/4`, Luas `8220GA00404` Jervis and `8220GA00408` Abbey St. (`line: red`, `altIds: ["8220GA00409"]`), DART `8220IR0025`, `8240IR0017` |
| `transit_lines.json` | 2 lines: `dart` (6 points), `luas-red` (3 points, the longer of the two Red shapes) |
| `transit_routes.json` | 3 routes, sorted `MINI-39A`, `MINI-DART`, `MINI-RED` |

## GitHub Action (`.github/workflows/transit-bundle.yml`)

Runs Mondays 03:00 UTC and on `workflow_dispatch`:

1. checkout, Python 3.12, download `GTFS_All.zip` (fallback `GTFS_Realtime.zip`);
2. run the script into `BetterMaps/Resources/Transit/` + `scripts/out/`;
3. fail if the `.gz` is over 20 MB (warn over 15 MB);
4. upload `transit_timetable.sqlite.gz` + `manifest.json` to the rolling
   pre-release tagged **`transit-data`** (`softprops/action-gh-release@v2`,
   assets overwritten in place, same download URL every week);
5. open or update a PR from branch `bot/transit-bundle`
   (`peter-evans/create-pull-request@v6`) if any of the three JSON files
   changed.

Repository settings the owner must enable once:

- **Settings → Actions → General → Workflow permissions**: "Read and write
  permissions" and tick **"Allow GitHub Actions to create and approve pull
  requests"**, otherwise step 5 fails with "GitHub Actions is not permitted to
  create or approve pull requests".
- Nothing else: the release upload uses the built-in `GITHUB_TOKEN`
  (`contents: write`).

The release tag `transit-data` is created on the first run and never moves;
only its assets are replaced. The app should download the manifest first and
skip the 12 MB download when `sha256` matches what it already has.
