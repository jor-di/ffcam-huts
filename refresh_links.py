#!/usr/bin/env python3
"""Find each hut's page on Camptocamp (C2C) and Skitour, written to hut_links.json.

Run after ./refresh_coordinates.py: huts are matched by position (and name) around
their GPS coordinates.

  - Camptocamp: public API, no key. Searches C2C huts within ~1.5 km of each hut.
  - Skitour: official API, needs your personal key (free, from your skitour.fr profile page):
      read from secrets.env (SKITOUR_API_KEY=...), the environment, or --skitour-key xxxx
    Without a key, Skitour links are kept from the previous run (or left empty).
    Skitour's terms ask that pages using its data link to skitour.fr: the map does.

Usage:
  ./refresh_links.py
"""

import argparse
import difflib
import json
import math
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from ffcam import load_huts, norm, secret

HERE = Path(__file__).parent
COORDS = HERE / "hut_coordinates.json"
OUTPUT = HERE / "hut_links.json"
UA = {"User-Agent": "ffcam-huts-script", "Accept": "application/json"}
C2C_API = "https://api.camptocamp.org/waypoints"
C2C_PAGE = "https://www.camptocamp.org/waypoints/{id}"
SKITOUR_API = "https://skitour.fr/api/refuges"
SKITOUR_PAGE = "https://skitour.fr/refuges/{id}"
RADIUS_M = 1500       # search radius around the hut
MAX_DIST_M = 400      # a candidate this close is accepted even with a different name
MIN_NAME_SCORE = 0.6  # name similarity needed for candidates further away


def get_json(url, headers=None):
    req = urllib.request.Request(url, headers={**UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def distance_m(lat1, lon1, lat2, lon2):
    p = math.pi / 180
    a = (math.sin((lat2 - lat1) * p / 2) ** 2
         + math.cos(lat1 * p) * math.cos(lat2 * p) * math.sin((lon2 - lon1) * p / 2) ** 2)
    return 12742000 * math.asin(math.sqrt(a))


def name_score(a, b):
    return difflib.SequenceMatcher(None, norm(a), norm(b)).ratio()


def best_match(hut, coords, candidates):
    """candidates: [(id, name, lat, lon)] -> (id, name, distance) of the best one, or None."""
    scored = []
    for cid, cname, clat, clon in candidates:
        d = distance_m(coords["lat"], coords["lon"], clat, clon)
        s = name_score(hut["name"], cname)
        if d <= MAX_DIST_M or (s >= MIN_NAME_SCORE and d <= RADIUS_M):
            scored.append((s - d / RADIUS_M, cid, cname, round(d)))
    if not scored:
        return None
    _, cid, cname, d = max(scored)
    return cid, cname, d


# ---------- Camptocamp ----------
def to_mercator(lat, lon):
    x = lon * 20037508.34 / 180
    y = math.log(math.tan((90 + lat) * math.pi / 360)) * 20037508.34 / math.pi
    return x, y


def from_mercator(x, y):
    lon = x / 20037508.34 * 180
    lat = 360 / math.pi * math.atan(math.exp(y / 20037508.34 * math.pi)) - 90
    return lat, lon


def c2c_candidates(coords):
    x, y = to_mercator(coords["lat"], coords["lon"])
    r = RADIUS_M * 1.45  # mercator metres are stretched by ~1/cos(lat) at 45°N
    url = f"{C2C_API}?bbox={x - r},{y - r},{x + r},{y + r}&wtyp=hut,gite,shelter&limit=50"
    out = []
    for w in get_json(url).get("documents", []):
        locales = {loc.get("lang"): loc.get("title") for loc in w.get("locales", [])}
        name = locales.get("fr") or next(iter(locales.values()), "")
        gx, gy = json.loads(w["geometry"]["geom"])["coordinates"][:2]
        out.append((w["document_id"], name, *from_mercator(gx, gy)))
    return out


# ---------- Skitour ----------
def skitour_candidates(key):
    data = get_json(SKITOUR_API, {"cle": key})
    if isinstance(data, dict) and data.get("ERROR"):
        raise RuntimeError(f"Skitour API error: {data['ERROR']}")
    out = []
    for r in data:
        try:
            out.append((r["id"], r["refuge"], float(r["latlon"][0]), float(r["latlon"][1])))
        except (KeyError, ValueError, TypeError, IndexError):
            continue
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--skitour-key", default=secret("SKITOUR_API_KEY"), help="Skitour API key (default: secrets.env or env SKITOUR_API_KEY)")
    args = p.parse_args()

    huts = load_huts()["huts"]
    if not COORDS.exists():
        sys.exit("hut_coordinates.json not found: run ./refresh_coordinates.py first.")
    coords = json.loads(COORDS.read_text(encoding="utf-8"))
    previous = json.loads(OUTPUT.read_text(encoding="utf-8")) if OUTPUT.exists() else {}
    located = [h for h in huts if h["id"] in coords]
    links = {h["id"]: {"name": h["name"]} for h in located}

    print(f"Camptocamp: searching around {len(located)} huts...", file=sys.stderr)

    def c2c(hut):
        try:
            return hut, best_match(hut, coords[hut["id"]], c2c_candidates(coords[hut["id"]])), None
        except Exception as e:
            return hut, None, str(e)

    with ThreadPoolExecutor(max_workers=3) as pool:
        for hut, match, err in pool.map(c2c, located):
            if err:
                print(f"  C2C error for {hut['name']}: {err}", file=sys.stderr)
                links[hut["id"]]["c2c"] = previous.get(hut["id"], {}).get("c2c")
            elif match:
                cid, cname, d = match
                links[hut["id"]]["c2c"] = {"url": C2C_PAGE.format(id=cid), "name": cname, "distance_m": d}

    if args.skitour_key:
        print("Skitour: downloading the hut list...", file=sys.stderr)
        candidates = skitour_candidates(args.skitour_key)
        print(f"  {len(candidates)} Skitour huts", file=sys.stderr)
        for hut in located:
            if match := best_match(hut, coords[hut["id"]], candidates):
                sid, sname, d = match
                links[hut["id"]]["skitour"] = {"url": SKITOUR_PAGE.format(id=sid), "name": sname, "distance_m": d}
    else:
        print("Skitour: no API key (SKITOUR_API_KEY in secrets.env), keeping previous Skitour links.", file=sys.stderr)
        for hid in links:
            if sk := previous.get(hid, {}).get("skitour"):
                links[hid]["skitour"] = sk

    OUTPUT.write_text(json.dumps(links, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    n_c2c = sum(bool(v.get("c2c")) for v in links.values())
    n_sk = sum(bool(v.get("skitour")) for v in links.values())
    print(f"Wrote {OUTPUT}: {n_c2c}/{len(links)} Camptocamp, {n_sk}/{len(links)} Skitour links", file=sys.stderr)
    for v in links.values():
        c = v.get("c2c")
        if c and name_score(v["name"], c["name"]) < MIN_NAME_SCORE:
            print(f"  check C2C match (different name): {v['name']} -> {c['name']} ({c['distance_m']} m)", file=sys.stderr)
        if not c:
            print(f"  no C2C page: {v['name']}", file=sys.stderr)


if __name__ == "__main__":
    main()
