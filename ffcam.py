"""Shared helpers for the FFCAM booking site (centrale.ffcam.fr).

How the FFCAM booking widget works (https://www.ffcam.fr/reserver-votre-refuge-en-ligne.html):
  1. The page embeds an iframe served by centrale.ffcam.fr/index.php. That HTML
     contains `structuresList = {...}`: every hut (id, name, type, ...).
  2. Picking a hut POSTs `action=availability` to the same index.php. The HTML that
     comes back contains, for two full months starting at the requested date's month:
       BK.availability       {date: free beds}
       BK.totalAvailability  {date: capacity}
       BK.openingCalendar    {date: OPEN | CLOSE | UNGUARDED}

The same server runs other booking portals, chosen with `apporigin`. Each portal lists its
own huts (some shared with FFCAM), e.g. VANOISE adds the Vanoise national park huts.
Availability must be requested through a portal that lists the hut.
"""

import html as htmllib
import json
import os
import re
import time
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

BASE_URL = "https://centrale.ffcam.fr/index.php"
HEADERS = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) ffcam-huts-script"}
HUTS_FILE = Path(__file__).with_name("huts.json")
# Portals (apporigin) to collect huts from. Others exist: NEOUVIELLE (3 huts), BOREON (1),
# ENTREPYRPYRENEES (Spanish/Andorran Pyrenees), ITFFCAM (all of them + Morocco).
DEFAULT_PORTALS = ["FFCAM", "VANOISE"]
TYPES = {
    "BK_STRUCTURECATEGORY:REFUGE": "refuge",
    "BK_STRUCTURECATEGORY:REFUGEHG_withBooking": "refuge_non_garde",
    "BK_STRUCTURECATEGORY:CHALET": "chalet",
    "BK_STRUCTURECATEGORY:CENTRE": "centre",
}


SECRETS_FILE = Path(__file__).with_name("secrets.env")


def secret(name):
    """An API key from the environment, else from secrets.env (KEY=value lines)."""
    if os.environ.get(name):
        return os.environ[name]
    if SECRETS_FILE.exists():
        for line in SECRETS_FILE.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() == name and not key.strip().startswith("#"):
                return value.strip() or None
    return None


def http(params, method="GET", retries=3):
    data = urllib.parse.urlencode(params)
    if method == "GET":
        req = urllib.request.Request(f"{BASE_URL}?{data}", headers=HEADERS)
    else:
        req = urllib.request.Request(f"{BASE_URL}?", data=data.encode(), headers=HEADERS)
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except Exception:
            if attempt == retries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def js_var(html, name):
    """Extract a `name = {...};` JSON literal from the page's inline JS."""
    m = re.search(rf"{re.escape(name)}\s*=\s*(.*?);\s*\n", html)
    return json.loads(m.group(1)) if m else None


def norm(name):
    """Normalize a hut name for matching: no accents, case, 'refuge/chalet/de/la...' or 'Non Gardé'."""
    name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().lower()
    name = re.sub(r"\(.*?\)|non garde", " ", name)
    name = re.sub(r"\b(refuge|chalet|alpin|caf|du|de|des|la|le|les|l|d)\b", " ", name)
    return re.sub(r"[^a-z0-9]", "", name)


def hut_site(subdomain):
    """Return https://<subdomain>.ffcam.fr/ if that hut website exists (unknown ones redirect to www.ffcam.fr)."""
    if not re.fullmatch(r"[a-z0-9-]+", subdomain or ""):
        return None
    url = f"https://{subdomain}.ffcam.fr/"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=20) as resp:
            return url if resp.geturl().startswith(url) else None
    except Exception:
        return None


def email_user(raw):
    """Emails are obfuscated as `name<a></a><ff></ff><d></d><fr></fr>`: keep the part before @.
    It usually equals the hut's website subdomain (name.ffcam.fr), handy to match OSM data."""
    user = (raw or "").split("<a></a>")[0].replace("<d></d>", ".")
    return re.sub(r"<[^>]*>", "", user) or None


def fetch_huts(portals=DEFAULT_PORTALS):
    """Fetch the hut lists of the given portals, as compact dicts (first portal listing a hut wins)."""
    structures = {}
    for portal in portals:
        html = http({"mode": "FORM", "_lang": "FR", "init": 1, "apporigin": portal})
        found = js_var(html, "structuresList")
        if not found:
            raise RuntimeError(f"Could not find the hut list (structuresList) of portal {portal}.")
        for hut_id, s in found.items():
            structures.setdefault(hut_id, (portal, s))
    return [
        {
            "id": hut_id,
            "portal": portal,
            "name": htmllib.unescape(s.get("name", "")).strip(),
            "short_name": htmllib.unescape(s.get("shortName", "")).strip(),
            "type": TYPES.get(s.get("structureType"), s.get("structureType")),
            "email_user": email_user(s.get("email")),
            "max_pax_per_booking": s.get("maxPax"),
            "max_nights": s.get("maxDays"),
            "booking_delay_days": s.get("bookingDelay"),
            "product_categories": [p.get("oid") for p in s.get("productsCategories", [])],
        }
        for hut_id, (portal, s) in structures.items()
    ]


def load_huts(path=HUTS_FILE):
    if not Path(path).exists():
        raise SystemExit(f"{path} not found: run ./refresh_huts.py first.")
    return json.loads(Path(path).read_text(encoding="utf-8"))


def fetch_availability(hut_id, date, portal="FFCAM"):
    """Return free beds / capacity / opening status per day, for 2 months from date's month."""
    html = http(
        {
            "action": "availability",
            "apporigin": portal,
            "structure": hut_id,
            "productCategory": "nomatter",  # all accommodation types together
            "pax": 1,
            "date": date.isoformat(),
        },
        method="POST",
    )
    return {
        "free": js_var(html, "BK.availability") or {},
        "capacity": js_var(html, "BK.totalAvailability") or {},
        "opening": js_var(html, "BK.openingCalendar") or {},
    }
