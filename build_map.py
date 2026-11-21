#!/usr/bin/env python3
"""Build an interactive map (map.html) from an availability CSV made by ffcam_availability.py.

Usage:
  ./build_map.py                          # latest ffcam_*.csv in this folder
  ./build_map.py ffcam_2026-11-21.csv -o weekend.html

Open the HTML file in a browser (it needs internet access for the map tiles).
"""

import argparse
import csv
import json
import sys
from pathlib import Path

from ffcam import secret

HERE = Path(__file__).parent


def to_int(v):
    return int(v) if v not in (None, "") else None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("csv", nargs="?", help="availability CSV (default: latest ffcam_*.csv)")
    p.add_argument("-o", "--output", default=str(HERE / "map.html"))
    p.add_argument("--ign-key", default=secret("IGN_API_KEY"),
                   help="IGN API key to add the SCAN 25 layer (default: secrets.env or env IGN_API_KEY); it ends up in the HTML")
    args = p.parse_args()

    path = Path(args.csv) if args.csv else max(HERE.glob("ffcam_*.csv"), key=lambda f: f.stat().st_mtime, default=None)
    if not path:
        sys.exit("No CSV found: run ./ffcam_availability.py first.")

    huts, dates, fetched_at = {}, [], None
    with open(path, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if not r.get("lat"):
                continue
            fetched_at = r["fetched_at"]
            if r["date"] not in dates:
                dates.append(r["date"])
            hut = huts.setdefault(r["hut_id"], {
                "id": r["hut_id"], "name": r["name"], "type": r["type"],
                "lat": float(r["lat"]), "lon": float(r["lon"]), "ele": to_int(r["ele"]),
                "maxPax": to_int(r["max_pax_per_booking"]), "url": r.get("hut_url") or None, "c2c": r.get("c2c_url") or None, "skitour": r.get("skitour_url") or None, "portal": r.get("portal") or "FFCAM", "nights": {},
            })
            hut["nights"][r["date"]] = {
                "opening": r["opening"] or None, "free": to_int(r["free_beds"]),
                "capacity": to_int(r["capacity"]), "error": r["error"] or None,
            }

    data = {"dates": sorted(dates), "fetchedAt": fetched_at, "source": path.name, "huts": list(huts.values()),
            "ignKey": args.ign_key}
    template = (HERE / "map_template.html").read_text(encoding="utf-8")
    html = template.replace("__DATA__", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
    Path(args.output).write_text(html, encoding="utf-8")
    print(f"Wrote {args.output} ({len(huts)} huts, nights: {', '.join(data['dates'])})", file=sys.stderr)


if __name__ == "__main__":
    main()
