#!/usr/bin/env python3
"""Build an interactive map (map.html) from an availability CSV made by ffcam_availability.py,
and the fetch log page (releves/index.html next to it) from history/fetch_log.json.

Usage:
  ./build_map.py                          # latest ffcam_*.csv in this folder
  ./build_map.py ffcam_2026-11-21.csv -o weekend.html

Open the HTML file in a browser (it needs internet access for the map tiles).
"""

import argparse
import csv
import json
import re
import sys
from pathlib import Path

import fetch_log
from ffcam import load_huts, secret

HERE = Path(__file__).parent


def to_int(v):
    return int(v) if v not in (None, "") else None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("csv", nargs="?", help="availability CSV (default: latest ffcam_*.csv)")
    p.add_argument("-o", "--output", default=str(HERE / "map.html"))
    p.add_argument("--ign-key", default=secret("IGN_API_KEY"),
                   help="IGN API key to add the SCAN 25 layer (default: secrets.env or env IGN_API_KEY); it ends up in the HTML")
    p.add_argument("--log", type=Path, default=fetch_log.LOG_FILE, help="fetch log to show (default: history/fetch_log.json)")
    p.add_argument("--log-output", type=Path, help="fetch log page (default: releves/index.html next to the map)")
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
                "maxPax": to_int(r["max_pax_per_booking"]), "url": r.get("hut_url") or None, "phone": r.get("phone") or None, "email": r.get("email") or None, "c2c": r.get("c2c_url") or None, "skitour": r.get("skitour_url") or None, "portal": r.get("portal") or "FFCAM", "nights": {},
            })
            hut["nights"][r["date"]] = {
                "opening": r["opening"] or None, "free": to_int(r["free_beds"]),
                "capacity": to_int(r["capacity"]), "error": r["error"] or None, "booking": r.get("booking") or None,
            }

    data = {"dates": sorted(dates), "fetchedAt": fetched_at, "source": path.name, "huts": list(huts.values()),
            "ignKey": args.ign_key}
    template = (HERE / "map_template.html").read_text(encoding="utf-8")
    html = template.replace("__DATA__", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(html, encoding="utf-8")
    print(f"Wrote {args.output} ({len(huts)} huts, nights: {', '.join(data['dates'])})", file=sys.stderr)
    build_log_page(args, template)


def build_log_page(args, map_template):
    """The /releves/ page: did each hut's fetch go well (see fetch_log.py)."""
    log = fetch_log.load(args.log) or {}
    names = {h["id"]: {"name": h["name"].replace("  ", " ").replace(" (FFCAM)", ""), "portal": h.get("portal", "FFCAM")}
             for h in load_huts()["huts"]}
    data = {"last_run": log.get("last_run"), "runs": log.get("runs", []), "last_success": log.get("last_success", {}), "huts": names}
    favicon = re.search(r'<link rel="icon" type="image/svg\+xml" href="([^"]+)"', map_template)
    page = (HERE / "log_template.html").read_text(encoding="utf-8")
    page = page.replace("__FAVICON__", favicon.group(1) if favicon else "")
    page = page.replace("__LOG__", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
    out = args.log_output or Path(args.output).parent / "releves" / "index.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8")
    state = "no run yet" if not data["last_run"] else f"run of {data['last_run']['at']}"
    print(f"Wrote {out} (fetch log, {state})", file=sys.stderr)


if __name__ == "__main__":
    main()
