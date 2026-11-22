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

Open System (portal "OPENSYSTEM"): 12 Vanoise national park huts (Leisse, Fond des Fours...)
book through Open System / Alliance Réseaux instead. Their sites (refuge-xxx.vanoise.com) embed
a widget with a product id `ui:"OPRF-92948"`, whose planning is a public JSON(P) endpoint:
  https://etape-rest.for-system.com/index.aspx/index.aspx?ref=json-planning-refuge&q=92948,<date>
returning 30 days, from <date> - 15 days to <date> + 14 days: [{"s": free beds,
"f": 1 if closed, "d": days *before* <date>}] (the day is <date> - d). No capacity is given.
"""

import datetime as dt
import html as htmllib
import threading
import json
import os
import re
import time
import unicodedata
import urllib.parse
import urllib.request
from contextlib import contextmanager
from pathlib import Path

BASE_URL = "https://centrale.ffcam.fr/index.php"
HEADERS = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) ffcam-huts-script"}
HUTS_FILE = Path(__file__).with_name("huts.json")
# Portals (apporigin) to collect huts from. Others exist:
# ENTREPYRPYRENEES (Spanish/Andorran Pyrenees), ITFFCAM (all of them + Morocco).
DEFAULT_PORTALS = ["FFCAM", "VANOISE", "NEOUVIELLE", "BOREON", "OPENSYSTEM", "MANUAL"]
# MANUAL: huts listed by hand in manual_huts.json. Those with a "refugepro" slug book through
# Refuge Pro (the hut's own booking software) and get availability (portal REFUGEPRO);
# the others have no online booking we can read (phone / mail / form).
MANUAL_HUTS_FILE = Path(__file__).with_name("manual_huts.json")
REFUGEPRO_EMBED = "https://refuge-pro.com/embed/calendrier/{slug}"
# Open System huts are discovered from this site's "other huts" menu (all the park's huts)
OPENSYSTEM_ENTRY = "https://refuge-leisse.vanoise.com/"
OPENSYSTEM_PLANNING = "https://etape-rest.for-system.com/index.aspx/index.aspx?ref=json-planning-refuge&q={num},{date}"
TYPES = {
    "BK_STRUCTURECATEGORY:REFUGE": "refuge",
    "BK_STRUCTURECATEGORY:REFUGEHG_withBooking": "refuge_non_garde",
    "BK_STRUCTURECATEGORY:CHALET": "chalet",
    "BK_STRUCTURECATEGORY:CENTRE": "centre",
}


SECRETS_FILE = Path(__file__).with_name("secrets.env")

# Politeness: whatever the number of worker threads, each site gets at most PER_HOST_LIMIT
# requests at a time, and at least PER_HOST_GAP seconds between two request starts.
PER_HOST_LIMIT = 2
PER_HOST_GAP = 0.3
_host_lock = threading.Lock()
_host_slots = {}
_host_next = {}


@contextmanager
def polite(url):
    """Wait for a free slot and the minimum gap for this URL's site, then run the request."""
    host = urllib.parse.urlsplit(url).hostname
    with _host_lock:
        slots = _host_slots.setdefault(host, threading.Semaphore(PER_HOST_LIMIT))
    with slots:
        with _host_lock:  # reserve the next start time for this site
            now = time.monotonic()
            start = max(now, _host_next.get(host, 0.0))
            _host_next[host] = start + PER_HOST_GAP
        time.sleep(max(0.0, start - now))
        yield


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
            with polite(req.full_url), urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except Exception:
            if attempt == retries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def get_url(url, retries=3):
    for attempt in range(retries):
        try:
            with polite(url), urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=30) as resp:
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
        with polite(url), urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=20) as resp:
            return url if resp.geturl().startswith(url) else None
    except Exception:
        return None


def email_user(raw):
    """Emails are obfuscated as `name<a></a><ff></ff><d></d><fr></fr>`: keep the part before @.
    It usually equals the hut's website subdomain (name.ffcam.fr), handy to match OSM data."""
    user = (raw or "").split("<a></a>")[0].replace("<d></d>", ".")
    return re.sub(r"<[^>]*>", "", user) or None


def fetch_opensystem_huts(entry=OPENSYSTEM_ENTRY):
    """Vanoise park huts booked through Open System: id OPRF-<n>, name, site."""
    page = get_url(entry)
    sites = {u.rstrip("/"): htmllib.unescape(n).strip()
             for u, n in re.findall(r'href="(https://refuge-[a-z-]+\.vanoise\.com)/?"[^>]*>\s*([^<]+?)\s*<', page)}
    # the entry hut is not in its own menu: take its name from the page title ("Accueil | Refuge de la Leisse")
    title = re.search(r"<title>([^<]+)</title>", page)
    parts = [t.strip() for t in htmllib.unescape(title.group(1)).split("|")] if title else [entry]
    sites.setdefault(entry.rstrip("/"), next((t for t in parts if t.lower().startswith("refuge")), parts[-1]))
    huts = []
    for site, name in sorted(sites.items()):
        html = get_url(site + "/")
        m = re.search(r'ui:"OPRF-(\d+)"', html)
        if not m:
            continue  # this hut books through the FFCAM centrale (VANOISE portal) instead
        huts.append({
            "id": f"OPRF-{m.group(1)}", "portal": "OPENSYSTEM", "name": name,
            "short_name": re.sub(r"^Refuge (de la |de l'|du |des |de |d')", "", name),
            "type": "refuge", "email_user": None, "site": site + "/",
            "max_pax_per_booking": None, "max_nights": None, "booking_delay_days": None, "product_categories": [],
        })
    return huts


def fetch_huts(portals=DEFAULT_PORTALS):
    """Fetch the hut lists of the given portals, as compact dicts (first portal listing a hut wins)."""
    structures = {}
    extra = fetch_opensystem_huts() if "OPENSYSTEM" in portals else []
    if "MANUAL" in portals and MANUAL_HUTS_FILE.exists():
        for h in json.loads(MANUAL_HUTS_FILE.read_text(encoding="utf-8"))["huts"]:
            extra.append({**h, "portal": "REFUGEPRO" if h.get("refugepro") else "MANUAL", "email_user": None, "max_pax_per_booking": None,
                          "max_nights": None, "booking_delay_days": None, "product_categories": []})
    portals = [p for p in portals if p not in ("OPENSYSTEM", "MANUAL")]
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
    ] + extra


def load_huts(path=HUTS_FILE):
    if not Path(path).exists():
        raise SystemExit(f"{path} not found: run ./refresh_huts.py first.")
    return json.loads(Path(path).read_text(encoding="utf-8"))


def fetch_opensystem_availability(hut_id, date):
    """Open System planning: 30 days from `date` (capacity unknown, so None)."""
    query = date + dt.timedelta(days=15)  # the answer covers query-15 .. query+14
    text = get_url(OPENSYSTEM_PLANNING.format(num=hut_id.split("-", 1)[1], date=query.isoformat()))
    data = json.loads(text[text.index("(") + 1:text.rindex(")")])
    out = {"free": {}, "capacity": {}, "opening": {}}
    for e in (data[0]["planning"] if data else []):
        day = (query - dt.timedelta(days=e["d"])).isoformat()
        out["free"][day] = e["s"]
        out["capacity"][day] = None
        out["opening"][day] = "CLOSE" if e["f"] else "OPEN"
    return out


# How a night can be booked, read from the classes of each day of the FFCAM calendar:
#   "day dispo"                      -> online
#   "day complet waitinglistday"     -> waitlist (full, waiting list open)
#   "day completWeb completWebInfo"  -> phone (no longer sold online: "Réserver par téléphone / mail")
BOOKING_CLASSES = [("waitinglistday", "waitlist"), ("completWeb", "phone"), ("dispo", "online")]


def booking_modes(html):
    modes = {}
    for classes, day in re.findall(r'<div class="(day[^"]*)">\s*<a [^>]*data-date="(\d{4}-\d{2}-\d{2})"', html):
        for token, mode in BOOKING_CLASSES:
            if token in classes.split():
                modes[day] = mode
                break
    return modes


def fetch_refugepro_availability(slug, today=None):
    """Refuge Pro: the calendar a hut embeds on its site (refuge-pro.com/embed/calendrier/<slug>).
    The page is a Next.js render whose payload holds availability.data = about a year of
    {"date", "capacity", "booked", "free", "status": open|closed, "isFull"}, plus the hut's rules."""
    page = get_url(REFUGEPRO_EMBED.format(slug=slug))
    chunks = re.findall(r'self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)', page)
    flight = "".join(json.loads(f'"{c}"') for c in chunks)
    start = flight.find('"availability":{')
    if start < 0:
        raise RuntimeError(f"no availability in the Refuge Pro calendar of {slug}")
    # the availability object is plain JSON: read it with a decoder from its first brace
    info, _ = json.JSONDecoder().raw_decode(flight, start + len('"availability":'))
    today = today or dt.date.today()
    cutoff = (today + dt.timedelta(days=info.get("bookingCutoffDays") or 0)).isoformat()
    season = info.get("nextSeasonOpening") or {}
    not_yet = season.get("ouvreLe") and today.isoformat() < season["ouvreLe"]
    out = {"free": {}, "capacity": {}, "opening": {}, "booking": {}}
    for d in info.get("data", []):
        day, is_open = d["date"], d.get("status") == "open"
        out["free"][day], out["capacity"][day] = d.get("free"), d.get("capacity")
        out["opening"][day] = "OPEN" if is_open else "CLOSE"
        if not is_open:
            continue
        if d.get("isFull") or not d.get("free"):
            out["booking"][day] = "waitlist" if info.get("waitlistEnabled") else None
        elif day < cutoff or (not_yet and day >= season.get("premiereNuit", "9999")):
            out["booking"][day] = "phone"  # not (or no longer) open to online booking
            out["free"][day] = 0
        else:
            out["booking"][day] = "online"
    return out


def fetch_availability(hut_id, date, portal="FFCAM", slug=None):
    """Return free beds / capacity / opening status / booking mode per day, for 2 months from date's month."""
    if portal == "REFUGEPRO":
        return fetch_refugepro_availability(slug)
    if portal == "MANUAL":
        return None  # no online availability: shown as "Sur demande"
    if portal == "OPENSYSTEM":
        return fetch_opensystem_availability(hut_id, date)
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
        "booking": booking_modes(html),
    }
