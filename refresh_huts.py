#!/usr/bin/env python3
"""Refresh huts.json with the current list of FFCAM huts (ids, names, types...).

Also finds each hut's own FFCAM website (https://<name>.ffcam.fr/): <name> is usually the
part before @ of the hut's email; "Non Gardé" winter rooms share their guarded hut's site.

Huts come from several booking portals (default: FFCAM + VANOISE, see ffcam.DEFAULT_PORTALS).

Run it once, then again whenever FFCAM adds or removes huts.
  ./refresh_huts.py
  ./refresh_huts.py --portals FFCAM VANOISE NEOUVIELLE
"""

import argparse

import datetime as dt
import json
import sys
from concurrent.futures import ThreadPoolExecutor

from ffcam import DEFAULT_PORTALS, HUTS_FILE, fetch_huts, hut_site, norm


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--portals", nargs="+", default=DEFAULT_PORTALS, help=f"booking portals (default: {' '.join(DEFAULT_PORTALS)})")
    args = p.parse_args()

    huts = sorted(fetch_huts(args.portals), key=lambda h: h["name"])

    users = sorted({h["email_user"] for h in huts if h.get("email_user")})
    with ThreadPoolExecutor(max_workers=6) as pool:
        sites = dict(zip(users, pool.map(hut_site, users)))
    for h in huts:
        h["site"] = h.get("site") or sites.get(h.get("email_user"))  # Open System huts already have theirs
    for h in huts:  # winter rooms with a generic email: use the guarded hut's site
        if not h["site"]:
            h["site"] = next((o["site"] for o in huts if o["site"] and norm(o["name"]) == norm(h["name"])), None)
    old = {h["id"] for h in json.loads(HUTS_FILE.read_text())["huts"]} if HUTS_FILE.exists() else set()
    new = {h["id"] for h in huts}

    HUTS_FILE.write_text(
        json.dumps(
            {"refreshed_at": dt.datetime.now().isoformat(timespec="seconds"), "huts": huts},
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    per_portal = {pt: sum(h["portal"] == pt for h in huts) for pt in args.portals}
    print(f"Huts per portal: {per_portal}", file=sys.stderr)
    print(f"Wrote {len(huts)} huts to {HUTS_FILE} ({sum(bool(h['site']) for h in huts)} with a website)", file=sys.stderr)
    for h in huts:
        if not h["site"]:
            print(f"  no website found: {h['name']}", file=sys.stderr)
    if old:
        names = {h["id"]: h["name"] for h in huts}
        for hut_id in sorted(new - old):
            print(f"  + {hut_id} {names[hut_id]}", file=sys.stderr)
        for hut_id in sorted(old - new):
            print(f"  - {hut_id}", file=sys.stderr)


if __name__ == "__main__":
    main()
