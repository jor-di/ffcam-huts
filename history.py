"""Availability history: append-only CSV files recording every change (storage only).

Each availability fetch returns ~2 months of days per hut. For every (hut, night) still to
come, we compare (opening, free beds, capacity) with the last recorded state and append a
row only when it changed. The first run records everything (baseline).

Files (in history/):
  availability_YYYY-MM.csv   one file per month of fetch, columns:
                             fetched_at, hut_id, date, opening, free_beds, capacity
  state.json                 last recorded state per "hut_id|date" (to detect changes)

To rebuild the state of any (hut, night) at a given time, take the last row with
fetched_at <= that time.
"""

import csv
import datetime as dt
import json
from pathlib import Path

HISTORY_DIR = Path(__file__).with_name("history")
STATE_FILE = HISTORY_DIR / "state.json"
FIELDS = ["fetched_at", "hut_id", "date", "opening", "free_beds", "capacity"]


def record(results, fetched_at, today=None):
    """results: [(hut, data, error)] as returned by ffcam_availability.py. Returns rows appended."""
    today = (today or dt.date.today()).isoformat()
    HISTORY_DIR.mkdir(exist_ok=True)
    state = json.loads(STATE_FILE.read_text(encoding="utf-8")) if STATE_FILE.exists() else {}

    changes = []
    for hut, data, err in results:
        if err or not data:
            continue  # a failed fetch (or a manual hut, nothing fetched) says nothing about availability
        days = set(data["opening"]) | set(data["free"]) | set(data["capacity"])
        for day in sorted(d for d in days if d >= today):
            value = [data["opening"].get(day), data["free"].get(day), data["capacity"].get(day)]
            key = f"{hut['id']}|{day}"
            if state.get(key) != value:
                state[key] = value
                changes.append(dict(zip(FIELDS, [fetched_at, hut["id"], day, *value])))

    # forget nights that are over
    state = {k: v for k, v in state.items() if k.split("|", 1)[1] >= today}

    if changes:
        path = HISTORY_DIR / f"availability_{fetched_at[:7]}.csv"
        new_file = not path.exists()
        with open(path, "a", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=FIELDS)
            if new_file:
                writer.writeheader()
            writer.writerows(changes)
    # one "hut|night" per line, so git only stores the lines that changed
    lines = [f"{json.dumps(k)}:{json.dumps(v, separators=(',', ':'))}" for k, v in sorted(state.items())]
    STATE_FILE.write_text("{\n" + ",\n".join(lines) + "\n}\n", encoding="utf-8")
    return len(changes)
