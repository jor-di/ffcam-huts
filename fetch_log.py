"""Fetch log: did each hut's availability fetch go well? (feeds the /releves/ page)

For every run, each hut gets a state:
  ok    the source answered with nights
  warn  the source answered, but with no night at all (often a format change on the source side)
  err   the request failed (timeout, HTTP error, page without data...)
  skip  not fetched: hut without online booking we can read (portal MANUAL)

history/fetch_log.json (on the `data` branch, next to the availability history) keeps:
  last_run      the latest run, with one entry per hut (state, nights received, seconds, message)
  runs          a summary of the last MAX_RUNS runs: per source counts + the huts with a problem
  last_success  per hut, the time of the latest ok / warn fetch
"""

import datetime as dt
import json
import os
from pathlib import Path

LOG_FILE = Path(__file__).with_name("history") / "fetch_log.json"
MAX_RUNS = 48
SOURCE_ORDER = ["FFCAM", "VANOISE", "NEOUVIELLE", "BOREON", "OPENSYSTEM", "REFUGEPRO", "MANUAL"]


def classify(hut, data, err):
    """-> (state, nights received, message)"""
    if hut.get("portal") == "MANUAL":
        return "skip", None, "Non relevé : réservation hors ligne (téléphone, email, formulaire)"
    if err:
        return "err", 0, err[:300]
    days = set((data or {}).get("opening") or {}) | set((data or {}).get("free") or {})
    if not days:
        return "warn", 0, "Réponse vide : aucune nuit dans la réponse"
    known = [v for v in data["opening"].values() if v and v != "UNKNOW"]
    if not known:  # normal for a hut closed for the season: informational only
        return "ok", len(days), "Pas de calendrier d'ouverture publié sur la période (refuge fermé ?)"
    return "ok", len(days), ""


def trigger():
    """What started this run: the workflow_dispatch "source" input (cron-job.org, button),
    else the GitHub Actions event name, else 'local'."""
    if os.environ.get("TRIGGER_SOURCE"):
        return os.environ["TRIGGER_SOURCE"]
    return {"schedule": "planifié (GitHub)", "push": "push sur main", "workflow_dispatch": "manuel (Actions)"}.get(
        os.environ.get("GITHUB_EVENT_NAME", ""), "local")


def record(results, timings, fetched_at, seconds, path=LOG_FILE):
    """results: [(hut, data, error)]; timings: {hut_id: seconds}. Returns the run summary."""
    log = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    huts, sources, problems = [], {}, []
    for hut, data, err in results:
        state, nights, msg = classify(hut, data, err)
        src = hut.get("portal", "FFCAM")
        s = sources.setdefault(src, {"total": 0, "ok": 0, "warn": 0, "err": 0, "skip": 0, "seconds": 0.0})
        s["total"] += 1
        s[state] += 1
        s["seconds"] = round(s["seconds"] + timings.get(hut["id"], 0.0), 2)
        huts.append({"id": hut["id"], "state": state, "nights": nights, "seconds": round(timings.get(hut["id"], 0.0), 2), "msg": msg})
        if state in ("err", "warn"):
            problems.append({"id": hut["id"], "state": state, "msg": msg})
        if state in ("ok", "warn"):
            log.setdefault("last_success", {})[hut["id"]] = fetched_at
    run = {"at": fetched_at, "seconds": round(seconds, 1), "trigger": trigger(), "requests": sum(1 for h in huts if h["state"] != "skip"),
           "sources": {k: sources[k] for k in sorted(sources, key=lambda k: SOURCE_ORDER.index(k) if k in SOURCE_ORDER else 99)},
           "problems": problems}
    log["last_run"] = {**{k: v for k, v in run.items() if k != "problems"}, "huts": huts}
    log["runs"] = ([run] + log.get("runs", []))[:MAX_RUNS]
    # one small item per line: git stores only the lines that changed
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(log, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return run


def load(path=LOG_FILE):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None
