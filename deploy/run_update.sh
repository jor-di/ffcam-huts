#!/bin/sh
# Runs on the server (cron, every 2 hours): fetch availability, record history, rebuild the map.
set -eu

APP=${APP:-/opt/ffcam-huts}
WEB=${WEB:-/var/www/refuges}

# never run two updates at the same time
exec 9>/tmp/ffcam-huts.lock
flock -n 9 || { echo "$(date -Is) previous update still running, skipping"; exit 0; }

echo "$(date -Is) update start"
mkdir -p "$APP/data"
python3 "$APP/ffcam_availability.py" -o "$APP/data/latest.csv"
# write to a temp file then rename, so visitors never get a half-written page
python3 "$APP/build_map.py" "$APP/data/latest.csv" -o "$WEB/index.html.tmp"
mv "$WEB/index.html.tmp" "$WEB/index.html"
echo "$(date -Is) update done"
