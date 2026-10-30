# Cycling engine evaluation: "quiet roads" in Dublin

Date: 2026-10-30

## Method

Script: `scripts/cycling_quiet_eval.py` (`python3 -I scripts/cycling_quiet_eval.py`, stdlib only).
Ten Dublin origin/destination pairs, roughly 5-9 km of route each (centre, suburbs, coast). For each pair:

- FOSSGIS Valhalla (`valhalla1.openstreetmap.de/route`), costing `bicycle`, Hybrid, `use_hills` 0.3. Quiet = `use_roads` 0.0, fast = `use_roads` 1.0.
- BRouter (`brouter.de/brouter`). Quiet = `safety`, also `trekking`; fast = `fastbike`.

Both routes are resampled every 25 m. Divergence = fraction of quiet-route samples farther than 50 m from every fast-route sample. A pair counts as "changed" if divergence > 0.25. Adoption rule: an engine is adopted only if it changes >= 5 of 10 pairs. One call per second, User-Agent `BetterMaps-research/0.1`. No HTTP errors occurred.

## Results

| Pair | Engine | Quiet km | Fast km | Divergence | Changed |
|---|---|---|---|---|---|
| Rathmines-PhoenixPark | valhalla | 7.72 | 7.72 | 0.00 | no |
| Rathmines-PhoenixPark | brouter-safety | 7.25 | 7.53 | 0.81 | yes |
| Rathmines-PhoenixPark | brouter-trekking | 7.42 | 7.53 | 0.78 | yes |
| Sandymount-Smithfield | valhalla | 5.51 | 5.51 | 0.00 | no |
| Sandymount-Smithfield | brouter-safety | 6.09 | 5.43 | 0.65 | yes |
| Sandymount-Smithfield | brouter-trekking | 5.78 | 5.43 | 0.41 | yes |
| Drumcondra-Ballsbridge | valhalla | 5.92 | 5.99 | 0.16 | no |
| Drumcondra-Ballsbridge | brouter-safety | 5.87 | 5.80 | 0.79 | yes |
| Drumcondra-Ballsbridge | brouter-trekking | 5.87 | 5.80 | 0.79 | yes |
| Clontarf-Trinity | valhalla | 5.96 | 5.67 | 0.16 | no |
| Clontarf-Trinity | brouter-safety | 6.04 | 6.20 | 0.30 | yes |
| Clontarf-Trinity | brouter-trekking | 6.14 | 6.20 | 0.31 | yes |
| Rathfarnham-CanalDock | valhalla | 7.77 | 7.80 | 0.39 | yes |
| Rathfarnham-CanalDock | brouter-safety | 7.78 | 7.53 | 0.35 | yes |
| Rathfarnham-CanalDock | brouter-trekking | 7.64 | 7.53 | 0.23 | no |
| Dundrum-Stoneybatter | valhalla | 8.82 | 8.82 | 0.00 | no |
| Dundrum-Stoneybatter | brouter-safety | 9.30 | 8.99 | 0.49 | yes |
| Dundrum-Stoneybatter | brouter-trekking | 9.52 | 8.99 | 0.61 | yes |
| Kilmainham-Fairview | valhalla | 6.30 | 6.14 | 0.70 | yes |
| Kilmainham-Fairview | brouter-safety | 6.85 | 6.11 | 0.74 | yes |
| Kilmainham-Fairview | brouter-trekking | 6.36 | 6.11 | 0.61 | yes |
| Blackrock-Ranelagh | valhalla | 7.32 | 6.92 | 0.66 | yes |
| Blackrock-Ranelagh | brouter-safety | 7.73 | 6.60 | 0.80 | yes |
| Blackrock-Ranelagh | brouter-trekking | 6.88 | 6.60 | 0.40 | yes |
| Cabra-Donnybrook | valhalla | 7.68 | 7.68 | 0.00 | no |
| Cabra-Donnybrook | brouter-safety | 8.46 | 7.48 | 0.95 | yes |
| Cabra-Donnybrook | brouter-trekking | 8.34 | 7.48 | 0.94 | yes |
| Glasnevin-Ringsend | valhalla | 6.06 | 5.94 | 0.38 | yes |
| Glasnevin-Ringsend | brouter-safety | 6.14 | 5.89 | 0.91 | yes |
| Glasnevin-Ringsend | brouter-trekking | 6.14 | 5.89 | 0.91 | yes |

## Per-engine summary

| Engine | Pairs changed | Median divergence | HTTP errors |
|---|---|---|---|
| Valhalla (use_roads 0 vs 1) | 4 / 10 | 0.16 | none |
| BRouter safety vs fastbike | 10 / 10 | 0.76 | none |
| BRouter trekking vs fastbike | 9 / 10 | 0.61 | none |

Caveat: divergence says the route differs, not that it is actually quieter. It was not checked against road class or cycle-infrastructure data. Quiet BRouter routes were 0-1 km longer than fast ones in most pairs (up to +0.98 km, Cabra-Donnybrook), which fits a real detour onto quieter streets, but this needs spot checks on a map. Also, `fastbike` itself differs from `safety` in more than traffic preference (different base profile), so BRouter's divergence is partly profile difference, not only a quiet-roads slider.

## Recommendation

BRouter with the `safety` profile (10/10 changed, median divergence 0.76) clears the >= 5 of 10 rule; `trekking` (9/10) is a fallback. FOSSGIS Valhalla's `use_roads` slider changed only 4/10 pairs (median 0.16) and returned identical geometry for 4 pairs, so by the rule it is not adopted. Before shipping, spot-check a few BRouter safety routes visually, and note that neither server is suitable as a production dependency: both are community fair-use services, so a self-hosted BRouter (or a hosted instance with agreement) is the safer path for an App Store app.

## Terms of the public servers

- BRouter (brouter.de): free community service, fair-use and non-commercial; attribution to BRouter and OpenStreetMap contributors is requested. No SLA. I did not fetch a terms page programmatically; this is from the BRouter project's published guidance.
- FOSSGIS Valhalla (valhalla.openstreetmap.de): a FOSSGIS e.V. community demo/service with a usage policy on that site. The page is a JavaScript app, and fetching it with curl returned only "You need to enable JavaScript to run this app", so I could not quote the policy text. Treat it as fair-use, non-commercial and low-volume, and read the policy in a browser before relying on it.
- Both are OpenStreetMap-derived; ODbL attribution applies to any displayed output.
- This spike made 30 requests per pair set at 1 request/second with an identifying User-Agent, in line with fair use.
