#!/bin/sh
# From your machine: send code + hut data to the server.
#   ./deploy/push.sh debian@1.2.3.4                  # code and hut data (huts, GPS, links)
#   ./deploy/push.sh debian@1.2.3.4 --with-history   # first time only: also send local history/
#
# The server's history/ is the reference once it runs: it is never overwritten by a normal push.
# secrets.env is never sent (the server doesn't need the Skitour key to update availability).
set -eu

SERVER=${1:?usage: deploy/push.sh user@server [--with-history]}
APP=/opt/ffcam-huts
cd "$(dirname "$0")/.."

EXCLUDES="--exclude secrets.env --exclude availability_*.csv --exclude map.html --exclude data/"
[ "${2:-}" = "--with-history" ] || EXCLUDES="$EXCLUDES --exclude history/"

ssh "$SERVER" "sudo mkdir -p $APP"
# shellcheck disable=SC2086
rsync -av --rsync-path="sudo rsync" $EXCLUDES ./ "$SERVER:$APP/"
# give the files back to the service user (once setup_server.sh has created it)
ssh "$SERVER" "id refuges >/dev/null 2>&1 && sudo chown -R refuges:refuges $APP || true"
echo "Pushed to $SERVER:$APP"
