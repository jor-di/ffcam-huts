#!/usr/bin/env python3
"""Associate GPS coordinates to each hut of huts.json, using OpenStreetMap data.

FFCAM's booking data has no coordinates, so this downloads the huts in France from
OSM (Overpass API) and matches them, in order of confidence:
  1. override  coordinates_overrides.json (manual entries for huts OSM can't match)
  2. website   OSM `website` = https://<email_user>.ffcam.fr  (FFCAM email == site subdomain)
  3. name      same normalized name ("Non Gardé" winter rooms use their hut's name)
  4. fuzzy     close name, only among huts operated by the Club Alpin in OSM

Writes hut_coordinates.json. Re-run after ./refresh_huts.py when huts are added.
"""

import difflib
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from ffcam import load_huts, norm

HERE = Path(__file__).parent
OUTPUT = HERE / "hut_coordinates.json"
OVERRIDES = HERE / "coordinates_overrides.json"
OVERPASS_URLS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
QUERY = """[out:json][timeout:180];
area["ISO3166-1"="FR"][admin_level=2]->.fr;
( nwr["tourism"~"^(alpine_hut|wilderness_hut)$"](area.fr);
  nwr["website"~"ffcam\\\\.fr"](area.fr);
  nwr["contact:website"~"ffcam\\\\.fr"](area.fr); );
out center tags;"""
CLUB_ALPIN = re.compile(r"ffcam|\bcaf\b|club alpin", re.I)


def fetch_osm(attempts=4):
    body = urllib.parse.urlencode({"data": QUERY}).encode()
    for attempt in range(attempts):
        for url in OVERPASS_URLS:
            try:
                req = urllib.request.Request(url, body, {"User-Agent": "ffcam-huts-script"})
                with urllib.request.urlopen(req, timeout=240) as resp:
                    return json.load(resp)["elements"]
            except Exception as e:  # servers are often busy: try the next one
                print(f"  {url}: {e}", file=sys.stderr)
        wait = 30 * 2**attempt
        print(f"All Overpass servers failed, retrying in {wait}s...", file=sys.stderr)
        time.sleep(wait)
    sys.exit("Could not reach the Overpass API, try again later.")


def ffcam_subdomain(url):
    m = re.search(r"https?://([a-z0-9.-]+)\.ffcam\.fr", url or "", re.I)
    return m and m.group(1).lower()


def to_coords(el, how):
    tags, center = el["tags"], el.get("center", el)
    ele = tags.get("ele")
    return {
        "lat": round(center["lat"], 6),
        "lon": round(center["lon"], 6),
        "ele": int(float(ele)) if ele and re.fullmatch(r"[\d.]+", ele) else None,
        "osm": f"{el['type']}/{el['id']}",
        "osm_name": tags.get("name"),
        "website": tags.get("website") or tags.get("contact:website"),
        "match": how,
    }


def main():
    huts = load_huts()["huts"]
    overrides = {k: v for k, v in json.loads(OVERRIDES.read_text()).items() if not k.startswith("_")}

    print("Downloading OSM huts (can take a minute)...", file=sys.stderr)
    osm = [e for e in fetch_osm() if e.get("tags", {}).get("name") and (e.get("center") or "lat" in e)]
    print(f"{len(osm)} OSM huts", file=sys.stderr)

    by_site, by_name = {}, {}
    for e in osm:
        t = e["tags"]
        for key in ("website", "contact:website", "url"):
            if sub := ffcam_subdomain(t.get(key)):
                by_site.setdefault(sub, e)
        by_name.setdefault(norm(t["name"]), []).append(e)
    # when several OSM huts share a name, prefer the Club Alpin one
    for cands in by_name.values():
        cands.sort(key=lambda e: not CLUB_ALPIN.search(e["tags"].get("operator", "")))
    club_names = [n for n, c in by_name.items() if CLUB_ALPIN.search(c[0]["tags"].get("operator", ""))]

    result, unmatched = {}, []
    for hut in huts:
        hid, key = hut["id"], norm(hut["name"])
        if hut.get("lat") is not None and hut.get("lon") is not None:  # manual huts carry their position
            coords = {"lat": hut["lat"], "lon": hut["lon"], "ele": hut.get("ele"), "osm": None,
                      "osm_name": None, "website": hut.get("site"), "match": "manual"}
        elif hid in overrides:
            o = overrides[hid]
            coords = {"lat": o["lat"], "lon": o["lon"], "ele": o.get("ele"), "osm": o.get("osm"),
                      "osm_name": o.get("name"), "website": o.get("website"), "match": "override"}
        elif hut.get("email_user") in by_site:
            coords = to_coords(by_site[hut["email_user"]], "website")
        elif key in by_name:
            coords = to_coords(by_name[key][0], "name")
        elif close := difflib.get_close_matches(key, club_names, n=1, cutoff=0.8):
            coords = to_coords(by_name[close[0]][0], "fuzzy")
        else:
            unmatched.append(hut)
            continue
        result[hid] = {"name": hut["name"], **coords}

    # "Non Gardé" winter rooms: reuse their guarded sibling when found
    for hut in list(unmatched):
        sibling = next((h for h in huts if h["id"] in result and h["id"] != hut["id"]
                        and norm(h["name"]) == norm(hut["name"])), None)
        if sibling:
            result[hut["id"]] = {**result[sibling["id"]], "name": hut["name"], "match": "sibling"}
            unmatched.remove(hut)

    OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    counts = {}
    for c in result.values():
        counts[c["match"]] = counts.get(c["match"], 0) + 1
    print(f"Wrote {len(result)}/{len(huts)} hut coordinates to {OUTPUT} {counts}", file=sys.stderr)
    for c in result.values():
        if c["match"] == "fuzzy":
            print(f"  check fuzzy match: {c['name']} -> {c['osm_name']}", file=sys.stderr)
    for hut in unmatched:
        print(f"  NOT FOUND: {hut['id']} {hut['name']} (add it to {OVERRIDES.name})", file=sys.stderr)


if __name__ == "__main__":
    main()
