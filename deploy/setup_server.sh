#!/bin/sh
# One-time server setup, run ON THE SERVER as root after ./deploy/push.sh:
#   sudo /opt/ffcam-huts/deploy/setup_server.sh                     # http://<IP>/, public
#   sudo /opt/ffcam-huts/deploy/setup_server.sh --password jordi    # + login/password
#   sudo /opt/ffcam-huts/deploy/setup_server.sh --domain refuges.mondomaine.fr --email moi@example.com
#        HTTPS with a free Let's Encrypt certificate (auto-renewed). The domain's DNS (A/AAAA
#        record) must already point to this server. --email is optional (expiry warnings).
#        With --domain, the site only answers on that name: other projects can live on the
#        same server under their own (sub)domains.
# Options can be combined. Assumptions: Debian 12 / Ubuntu 24.04 (OVH images). Safe to re-run.
# Ruby: the distribution's package (Debian 12: 3.1, Ubuntu 24.04: 3.2) is enough, even though
# .ruby-version (used by GitHub Actions) names a newer one: the code only uses the standard
# library and was checked on Ruby 3.1, 3.2, 3.3 and 4.0 (tests/unit.sh, tests/check.sh).
set -eu

DOMAIN= EMAIL= AUTH_USER=
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN=${2:?--domain needs a name}; shift 2 ;;
        --email) EMAIL=${2:?--email needs an address}; shift 2 ;;
        --password) AUTH_USER=${2:?--password needs a user name}; shift 2 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

APP=/opt/ffcam-huts
WEB=/var/www/refuges
USER_NAME=refuges

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

echo "== packages"
apt-get update -q
apt-get install -y -q ruby nginx rsync apache2-utils
[ -z "$DOMAIN" ] || apt-get install -y -q certbot python3-certbot-nginx

echo "== timezone Europe/Paris (dates in history and 'today' follow French time)"
timedatectl set-timezone Europe/Paris || true

echo "== system user '$USER_NAME' (runs the updates, owns the data)"
id "$USER_NAME" >/dev/null 2>&1 || useradd --system --home-dir "$APP" --shell /usr/sbin/nologin "$USER_NAME"
mkdir -p "$WEB" /var/log/ffcam-huts "$APP/history" "$APP/data"
chown -R "$USER_NAME:$USER_NAME" "$APP" "$WEB" /var/log/ffcam-huts
chmod +x "$APP"/rb/*.rb "$APP"/deploy/*.sh

echo "== nginx"
cp "$APP/deploy/nginx.conf" /etc/nginx/sites-available/refuges
ln -sf /etc/nginx/sites-available/refuges /etc/nginx/sites-enabled/refuges
rm -f /etc/nginx/sites-enabled/default
if [ -n "$DOMAIN" ]; then
    # answer only on this name (not as the catch-all site), so other projects can share the server
    sed -i "s|listen 80 default_server;|listen 80;|; s|listen \[::\]:80 default_server;|listen [::]:80;|; s|server_name _;.*|server_name $DOMAIN;|" \
        /etc/nginx/sites-available/refuges
fi
if [ -n "$AUTH_USER" ]; then
    echo "Password for user '$AUTH_USER':"
    htpasswd -c /etc/nginx/refuges.htpasswd "$AUTH_USER"
    printf 'auth_basic "Refuges";\nauth_basic_user_file /etc/nginx/refuges.htpasswd;\n' > /etc/nginx/refuges-auth.conf
    sed -i 's|# include /etc/nginx/refuges-auth.conf;|include /etc/nginx/refuges-auth.conf;|' /etc/nginx/sites-available/refuges
fi
nginx -t
systemctl reload nginx

if [ -n "$DOMAIN" ]; then
    echo "== HTTPS certificate for $DOMAIN (Let's Encrypt)"
    if [ -n "$EMAIL" ]; then ACCOUNT="--email $EMAIL"; else ACCOUNT="--register-unsafely-without-email"; fi
    # adds the HTTPS server block, redirects http -> https; renewal is handled by certbot's timer
    # shellcheck disable=SC2086
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos $ACCOUNT --redirect --keep-until-expiring
    certbot renew --dry-run --quiet && echo "certificate auto-renewal: OK" || echo "WARNING: renewal dry-run failed, check: certbot renew --dry-run"
fi

echo "== cron: update every 2 hours (at minute 7, to avoid the top-of-the-hour rush)"
cat > /etc/cron.d/ffcam-huts <<EOF
7 */2 * * * $USER_NAME $APP/deploy/run_update.sh >> /var/log/ffcam-huts/update.log 2>&1
EOF
chmod 644 /etc/cron.d/ffcam-huts

echo "== log rotation"
cat > /etc/logrotate.d/ffcam-huts <<EOF
/var/log/ffcam-huts/update.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF

echo "== first update (about 40 s)"
su -s /bin/sh "$USER_NAME" -c "$APP/deploy/run_update.sh"

IP=$(hostname -I | awk '{print $1}')
if [ -n "$DOMAIN" ]; then URL="https://$DOMAIN/"; else URL="http://$IP/"; fi
echo "Done. Open $URL  — logs: /var/log/ffcam-huts/update.log"
