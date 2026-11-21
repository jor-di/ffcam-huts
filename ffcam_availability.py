#!/usr/bin/env python3
"""Fetch FFCAM hut availability for the huts listed in huts.json and store it in a CSV.

Run ./refresh_huts.py first to create huts.json.

Usage:
  ./ffcam_availability.py                       # this weekend from tonight on + next weekend (Fri, Sat, Sun)
  ./ffcam_availability.py --date 2027-07-03 --nights 2
  ./ffcam_availability.py --date 2027-07-03 -o out.csv
"""

import argparse
import csv
import datetime as dt
import json
import sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

import history
from ffcam import fetch_availability, load_huts


def hut_url(hut, osm_website):
    """The hut's FFCAM site; else its OSM website (only FFCAM ones for FFCAM huts: OSM may list other sites)."""
    if hut.get("site"):
        return hut["site"]
    if osm_website and (".ffcam.fr" in osm_website or hut.get("portal", "FFCAM") != "FFCAM"):
        return osm_website
    return None


def weekend_nights(today=None):
    """The Friday, Saturday and Sunday nights of the current weekend that are not over yet.

    Mon-Fri: the coming Fri, Sat, Sun. Saturday: Sat (tonight), Sun. Sunday: Sun (tonight).
    The display moves to the next weekend on Monday.
    """
    today = today or dt.date.today()
    friday = today + dt.timedelta(days=4 - today.weekday())  # Mon=0 ... Fri=4, Sat/Sun go back
    return [d for d in (friday + dt.timedelta(days=i) for i in range(3)) if d >= today]


def next_weekend_nights(today=None):
    """Friday, Saturday and Sunday nights of the weekend after the current one (the map's
    "avant-dernière couchette" mode). Always inside the fetched window (today -> end of next month)."""
    today = today or dt.date.today()
    friday = today + dt.timedelta(days=4 - today.weekday() + 7)
    return [friday + dt.timedelta(days=i) for i in range(3)]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--date", type=dt.date.fromisoformat, help="first night (default: this weekend, from tonight)")
    p.add_argument("--nights", type=int, help="number of consecutive nights with --date (default: 1)")
    p.add_argument("-o", "--output", help="CSV path (default: ffcam_<date>.csv)")
    p.add_argument("--workers", type=int, default=4, help="parallel requests (default: 4)")
    p.add_argument("--no-history", action="store_true", help="don't record changes in history/ (see history.py)")
    args = p.parse_args()

    if args.date:
        dates = [args.date + dt.timedelta(days=i) for i in range(args.nights or 1)]
    else:
        dates = weekend_nights() + next_weekend_nights()
    start = dates[0]
    output = args.output or f"ffcam_{start.isoformat()}.csv"
    # FFCAM returns the requested date's month + the next one. By default ask from today, so the
    # history always covers today -> end of next month (the next weekend is always inside);
    # with --date, ask from that date.
    fetch_from = start if args.date else dt.date.today()

    huts = load_huts()["huts"]
    coords_file = Path(__file__).with_name("hut_coordinates.json")
    coords = json.loads(coords_file.read_text(encoding="utf-8")) if coords_file.exists() else {}
    links_file = Path(__file__).with_name("hut_links.json")  # from ./refresh_links.py
    links = json.loads(links_file.read_text(encoding="utf-8")) if links_file.exists() else {}
    if not coords:
        print("No hut_coordinates.json: run ./refresh_coordinates.py to add GPS columns.", file=sys.stderr)
    print(f"{len(huts)} huts, fetching availability for {', '.join(map(str, dates))}...", file=sys.stderr)

    def work(hut):
        try:
            return hut, fetch_availability(hut["id"], fetch_from, hut.get("portal", "FFCAM")), None
        except Exception as e:  # keep going, record the error
            return hut, None, str(e)

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(work, huts))

    fetched_at = dt.datetime.now().isoformat(timespec="seconds")
    if not args.no_history:
        n = history.record(results, fetched_at)
        print(f"History: {n} changes appended to {history.HISTORY_DIR.name}/", file=sys.stderr)
    rows, errors = [], 0
    for hut, data, err in results:
        errors += bool(err)
        for d in dates:
            key = d.isoformat()
            # nights beyond the returned 2-month window come back empty
            free = data["free"].get(key) if data else None
            capacity = data["capacity"].get(key) if data else None
            opening = data["opening"].get(key) if data else None
            rows.append(
                {
                    "date": key,
                    "weekday": d.strftime("%A"),
                    "hut_id": hut["id"],
                    "name": hut["name"],
                    "portal": hut.get("portal", "FFCAM"),
                    "short_name": hut["short_name"],
                    "type": hut["type"],
                    "opening": opening,
                    "free_beds": free,
                    "capacity": capacity,
                    "booked": capacity - free if isinstance(free, int) and isinstance(capacity, int) else None,
                    "bookable": bool(opening == "OPEN" and free),
                    "max_pax_per_booking": hut["max_pax_per_booking"],
                    "lat": coords.get(hut["id"], {}).get("lat"),
                    "lon": coords.get(hut["id"], {}).get("lon"),
                    "ele": coords.get(hut["id"], {}).get("ele"),
                    "hut_url": hut_url(hut, coords.get(hut["id"], {}).get("website")),
                    "c2c_url": (links.get(hut["id"], {}).get("c2c") or {}).get("url"),
                    "skitour_url": (links.get(hut["id"], {}).get("skitour") or {}).get("url"),
                    "fetched_at": fetched_at,
                    "error": err,
                }
            )

    rows.sort(key=lambda r: (r["date"], not r["bookable"], -(r["free_beds"] or 0), r["name"]))
    with open(output, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    bookable = sum(r["bookable"] for r in rows)
    print(f"Wrote {len(rows)} rows to {output} ({bookable} bookable hut-nights, {errors} errors)", file=sys.stderr)


if __name__ == "__main__":
    main()
