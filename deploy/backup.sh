#!/bin/sh
# From your machine: copy the server's history/ (the only data that can't be rebuilt) to history-backup/.
#   ./deploy/backup.sh debian@1.2.3.4
# To run it daily from your machine: crontab -e, then for example
#   30 21 * * * /home/jordi/code/perso/ffcam-huts/deploy/backup.sh debian@1.2.3.4 >/dev/null 2>&1
set -eu

SERVER=${1:?usage: deploy/backup.sh user@server}
cd "$(dirname "$0")/.."
mkdir -p history-backup
rsync -a "$SERVER:/opt/ffcam-huts/history/" history-backup/
echo "Backed up to $(pwd)/history-backup ($(du -sh history-backup | cut -f1))"
