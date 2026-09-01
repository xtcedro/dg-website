#!/usr/bin/env bash
#
# deploy.sh — put this checkout into service on the machine it is run on.
#
# The install flow documented in README.md, in the same order, made idempotent
# and made to stop at the first thing that goes wrong. Running it twice changes
# nothing the second time; running it against a broken tree changes nothing at
# all, because the test suite runs before anything is installed.
#
#   sudo deploy/deploy.sh
#
# The application runs from this checkout — there is no second copy under /srv
# to drift out of step with git, and updating is `git pull && sudo
# deploy/deploy.sh --skip-certbot`. It does not run *as* the user who owns the
# checkout: a system account with no shell gets group read and nothing else, so
# the running code is not writable by the process running it.
#
# Nothing here is specific to one host beyond the variables below, and each of
# those can be overridden from the environment:
#
#   SITE_NAME=staging.example.dev sudo -E deploy/deploy.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The checkout is the deployment, and two users share it. OWNER is whoever
# invoked sudo: they own the files and can `git pull` without root. SERVICE is
# a system account with no shell and no home that gets group read and nothing
# else, so a bug in the request path cannot rewrite the code it runs.
APP_DIR="${APP_DIR:-$REPO_ROOT}"
OWNER_USER="${OWNER_USER:-${SUDO_USER:-root}}"
OWNER_GROUP="${OWNER_GROUP:-$(id -gn "$OWNER_USER" 2>/dev/null || echo "$OWNER_USER")}"
SERVICE_USER="${SERVICE_USER:-dgweb}"
SERVICE_GROUP="${SERVICE_GROUP:-$SERVICE_USER}"
SERVICE_NAME="${SERVICE_NAME:-denogenesis}"
SITE_NAME="${SITE_NAME:-denogenesis.com}"

# The one directory the service writes: the Deno KV database and its -wal/-shm
# files. Relative to the checkout; the systemd unit's KV_PATH points inside it.
DATA_DIR="${DATA_DIR:-data}"

# Secrets and per-host overrides, read by the unit's EnvironmentFile.
ENV_DIR="${ENV_DIR:-/etc/$SERVICE_NAME}"
ENV_FILE="${ENV_FILE:-$ENV_DIR/$SERVICE_NAME.env}"

# Certificates. CERT_DOMAINS is a space-separated list; the first is the
# lineage name, which is what the vhost names in its ssl_certificate paths, so
# it has to stay in step with SITE_NAME.
CERT_DOMAINS="${CERT_DOMAINS:-$SITE_NAME www.$SITE_NAME}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-pedro.dfedro@gmail.com}"
WEBROOT="${WEBROOT:-/var/www/certbot}"

SKIP_VERIFY=0
SKIP_NGINX=0
SKIP_CERTBOT=0
SKIP_FAIL2BAN=0
CERTBOT_STAGING=0
FORCE_RENEWAL=0

UNIT_SRC="$REPO_ROOT/deploy/systemd/$SERVICE_NAME.service"
ENV_SRC="$REPO_ROOT/deploy/systemd/$SERVICE_NAME.env.example"
NGINX_SRC="$REPO_ROOT/deploy/nginx/$SITE_NAME.conf"
SNIPPET_SRC="$REPO_ROOT/deploy/nginx/snippets/deny-probes.conf"
DEFAULT_DROP_SRC="$REPO_ROOT/deploy/nginx/00-default-drop"
F2B_FILTER_SRC="$REPO_ROOT/deploy/fail2ban/filter.d/nginx-probes.conf"
F2B_JAIL_SRC="$REPO_ROOT/deploy/fail2ban/jail.local"

# --- output ----------------------------------------------------------------
# stderr, so that stdout stays empty and the script can be piped without noise.

step() { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
fail() {
  printf '\n\033[1;31mdeploy failed:\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<EOF
usage: sudo deploy/deploy.sh [options]

  --skip-verify   Do not run the test suite first. Only for a redeploy of a
                  tree that was already verified.
  --skip-nginx    Install and restart the service, leave the reverse proxy
                  alone. Use when Nginx lives on another host. Implies
                  --skip-certbot.
  --skip-certbot  Do not touch certificates. The Nginx configuration will
                  still fail to load without them.
  --skip-fail2ban Do not install the jail or the probe filter.
  --staging       Issue from Let's Encrypt's staging CA. Untrusted by
                  browsers, but not rate limited — use it to rehearse.
  --force-renewal Renew even though the current certificate is still valid.
                  Rate limited by the CA; do not put this in a loop.
  -h, --help      This text.

Environment: APP_DIR, OWNER_USER, OWNER_GROUP, SERVICE_USER, SERVICE_GROUP,
SERVICE_NAME, SITE_NAME, DATA_DIR, ENV_FILE, CERT_DOMAINS, CERTBOT_EMAIL,
WEBROOT.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-verify) SKIP_VERIFY=1 ;;
    --skip-nginx) SKIP_NGINX=1 ;;
    --skip-certbot) SKIP_CERTBOT=1 ;;
    --skip-fail2ban) SKIP_FAIL2BAN=1 ;;
    --staging) CERTBOT_STAGING=1 ;;
    --force-renewal) FORCE_RENEWAL=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# Certificates exist to be presented by the proxy. If the proxy is somebody
# else's problem on this host, so are they.
[ "$SKIP_NGINX" -eq 0 ] || SKIP_CERTBOT=1

# The lineage is named after the first domain: that is how certbot names the
# directory, and it is the path the vhost reads its key material from.
CERT_NAME="${CERT_DOMAINS%% *}"
CERT_DIR="/etc/letsencrypt/live/$CERT_NAME"

# --- preflight -----------------------------------------------------------------
# Everything that could stop the deployment is checked before the first change,
# so a missing tool is a message rather than a half-installed service.

step "Preflight"

[ "$(id -u)" -eq 0 ] || fail "run with sudo: installing units and reloading nginx needs root"

for f in "$UNIT_SRC" "$ENV_SRC" "$REPO_ROOT/main.ts" "$REPO_ROOT/deno.json"; do
  [ -f "$f" ] || fail "missing $f — run this from a checkout of the repository"
done
if [ "$SKIP_NGINX" -eq 0 ]; then
  for f in "$NGINX_SRC" "$SNIPPET_SRC" "$DEFAULT_DROP_SRC"; do
    [ -f "$f" ] || fail "missing $f (SITE_NAME=$SITE_NAME names deploy/nginx/$SITE_NAME.conf)"
  done
fi
if [ "$SKIP_FAIL2BAN" -eq 0 ]; then
  for f in "$F2B_FILTER_SRC" "$F2B_JAIL_SRC"; do
    [ -f "$f" ] || fail "missing $f (pass --skip-fail2ban to leave fail2ban alone)"
  done
fi

for cmd in systemctl install sed; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is not installed"
done

id -u "$OWNER_USER" >/dev/null 2>&1 || fail "no such user: $OWNER_USER"
[ "$OWNER_USER" != root ] ||
  fail "refusing to deploy a root-owned checkout — invoke through sudo from a login user, or set OWNER_USER"

# The unit names an absolute interpreter path. A ~/.deno/bin install is
# invisible to systemd and to root.
DENO="${DENO:-/usr/bin/deno}"
[ -x "$DENO" ] ||
  fail "no deno at $DENO — install it there (sudo install -m 0755 ~/.deno/bin/deno /usr/bin/deno)"

# -x above is answered for root, who can execute almost anything. The service
# account is neither root nor in root's group, so what actually matters is the
# other-execute bit — and `deno upgrade` has been known to rewrite the binary
# without it, which surfaces much later as an unreadable "Permission denied".
deno_mode="$(stat -c '%a' "$DENO")"
case "${deno_mode: -1}" in
  1 | 3 | 5 | 7) ;;
  *) fail "$DENO is mode $deno_mode: $SERVICE_USER cannot execute it (sudo chmod 0755 $DENO)" ;;
esac

# A symlink into a home directory is worse than it looks. The unit runs with
# ProtectHome=tmpfs, so /home inside the service's namespace is empty: an
# interpreter that resolves under /home does not exist at all as far as
# systemd is concerned, and the unit fails to start with no useful message.
# It must be a real file outside /home.
deno_real="$(readlink -f "$DENO")"
case "$deno_real" in
  /home/*)
    fail "$DENO resolves to $deno_real, under /home — the unit's ProtectHome=tmpfs hides it.
       Install a real copy instead: sudo install -m 0755 $deno_real $DENO"
    ;;
esac
info "deno:    $deno_real ($("$DENO" --version | head -n 1))"

# The unit file is the single source of truth for the port. Reading it back
# here means the health check below cannot drift away from what was installed.
APP_PORT="$(sed -n 's/^Environment=PORT=\([0-9]\+\).*/\1/p' "$UNIT_SRC" | tail -n 1)"
[ -n "$APP_PORT" ] || fail "no Environment=PORT= line in $UNIT_SRC"
info "source:  $APP_DIR (owned by $OWNER_USER:$SERVICE_GROUP)"
info "runs as: $SERVICE_USER:$SERVICE_GROUP on 127.0.0.1:$APP_PORT"

if [ "$SKIP_NGINX" -eq 0 ] && ! command -v nginx >/dev/null 2>&1; then
  fail "nginx is not installed (pass --skip-nginx if it lives elsewhere)"
fi

if [ "$SKIP_CERTBOT" -eq 0 ]; then
  command -v certbot >/dev/null 2>&1 ||
    fail "certbot is not installed: sudo apt-get install -y certbot (or --skip-certbot)"

  # The vhost names its key material by absolute path. If that path and the
  # lineage this script is about to issue disagree, Nginx would load a
  # certificate nobody renews — so refuse now rather than discover it in
  # ninety days when the old one expires.
  conf_dir="$(sed -n 's|^[[:space:]]*ssl_certificate[[:space:]]\+\(/etc/letsencrypt/live/[^/]\+\)/.*|\1|p' \
    "$NGINX_SRC" | head -n 1)"
  if [ -n "$conf_dir" ] && [ "$conf_dir" != "$CERT_DIR" ]; then
    fail "$SITE_NAME reads $conf_dir but this deploy issues $CERT_DIR — set CERT_DOMAINS or SITE_NAME"
  fi

  case "$CERTBOT_EMAIL" in
    *@*.*) ;;
    *) fail "CERTBOT_EMAIL is not an address: '$CERTBOT_EMAIL' (expiry notices go there)" ;;
  esac
  info "certs:   $CERT_DOMAINS -> $CERT_DIR"
fi

if [ "$SKIP_FAIL2BAN" -eq 0 ] && ! command -v fail2ban-client >/dev/null 2>&1; then
  fail "fail2ban is not installed: sudo apt-get install -y fail2ban (or --skip-fail2ban)"
fi

# --- verify ------------------------------------------------------------------
# Formatting, lint, type check and the full suite, against the tree about to be
# put into service. As the owning user: root has no reason to own a cache.

step "Verify"

if [ "$SKIP_VERIFY" -eq 1 ]; then
  info "skipped (--skip-verify)"
else
  # As the owner, not the service account: the service account has no home to
  # cache into, and running the suite needs write access to the cache.
  # -H, not --preserve-env=HOME: sudo has already set HOME to /root, and a
  # deno running as the login user with that HOME cannot write its cache.
  sudo -u "$OWNER_USER" -H -- \
    sh -c "cd '$APP_DIR' && '$DENO' task verify" >&2 ||
    fail "the test suite did not pass — nothing was deployed"
  info "all checks passed"
fi

# --- account -----------------------------------------------------------------
# No shell, no home directory, no password: there is nothing to log into and
# nothing to leave behind. This account exists to read one directory.

step "Account"

if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  info "user $SERVICE_USER already exists"
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  info "created system user $SERVICE_USER"
fi

# --- ownership -------------------------------------------------------------------
# The half of the sandbox that systemd cannot do. The owner keeps write access
# so `git pull` needs no root; the service account reaches the tree only
# through the group, read-only, and so cannot rewrite the code that will run at
# the next restart. data/ is the single inversion: the service writes the KV
# database, and the owner reads it through sudo.

step "Ownership"

chown -R "$OWNER_USER:$SERVICE_GROUP" "$APP_DIR"
# X, not x: the execute bit reaches directories and already-executable files
# (deploy/deploy.sh stays runnable), never a source file that has no business
# being executable.
chmod -R g+rX,g-w,o-rwx "$APP_DIR"

# data/ inverts it: the service owns the KV database and writes it, and the
# owner's group can read it back. setgid so anything either of them creates
# keeps the group. The recursive chmod above walked straight through data/ and
# took group-write off the database node sitting inside it; fixing the
# directory alone is not enough, because the file the service opens is what
# matters — a service that can read but not write its KV answers 500 to every
# signup and every count. So the whole subtree is re-asserted.
install -d -o "$SERVICE_USER" -g "$OWNER_GROUP" -m 2770 "$APP_DIR/$DATA_DIR"
chown -R "$SERVICE_USER:$OWNER_GROUP" "$APP_DIR/$DATA_DIR"
chmod -R u+rwX,g+rwX,o-rwx "$APP_DIR/$DATA_DIR"

# Checked by ownership rather than by `sudo -u "$SERVICE_USER" test -w`, which
# would look right and fail for the wrong reason: that account cannot traverse
# the owner's 0750 home to reach this path at all. Root can write regardless,
# so asking root proves nothing either — the owner of the file is the thing
# worth asserting.
if [ -e "$APP_DIR/$DATA_DIR/waitlist.db" ]; then
  kv_owner="$(stat -c %U "$APP_DIR/$DATA_DIR/waitlist.db")"
  [ "$kv_owner" = "$SERVICE_USER" ] ||
    fail "$DATA_DIR/waitlist.db is owned by $kv_owner, not $SERVICE_USER — the service would be able to read it and not write it, which fails every signup and every count"
fi

info "$APP_DIR is $OWNER_USER:$SERVICE_GROUP, group read-only"
info "$APP_DIR/$DATA_DIR is $SERVICE_USER:$OWNER_GROUP, writable by both"

# --- environment file ----------------------------------------------------------
# Installed only when absent. It is the one file on the server that is meant to
# diverge from git — overwriting it on every deploy would discard the host's
# own settings, which is the opposite of what an override file is for.

step "Environment"

install -d -m 0755 "$ENV_DIR"
if [ -e "$ENV_FILE" ]; then
  info "$ENV_FILE exists, left alone"
else
  install -o root -g "$SERVICE_GROUP" -m 0640 "$ENV_SRC" "$ENV_FILE"
  info "installed $ENV_FILE from the example — review it"
fi

# --- module cache ------------------------------------------------------------
# Resolved once here, under review, so the unit can run --cached-only and the
# service never contacts a registry — not at start, not after a restart at 3am.
# CacheDirectory= in the unit owns this path once systemd takes over.

step "Module cache"

DENO_CACHE="/var/cache/$SERVICE_NAME/deno"
install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "/var/cache/$SERVICE_NAME" "$DENO_CACHE"

# As root, then handed over. Not as the service account: reaching the checkout
# means traversing the owner's home directory, which is mode 0750 on any Ubuntu
# since 21.04 and which the service account has no business being able to enter.
# It does not need to at runtime either — ProtectHome=tmpfs and the bind mounts
# give the unit the checkout at that path without any of its parents.
DENO_DIR="$DENO_CACHE" "$DENO" cache "$APP_DIR/main.ts" >&2 ||
  fail "could not populate the module cache at $DENO_CACHE"
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$DENO_CACHE"
info "cached into $DENO_CACHE, owned by $SERVICE_USER"

# --- service ---------------------------------------------------------------------
# The unit in git carries placeholder paths for the machine it was written on.
# They are rewritten here rather than committed per host, so `git diff` on the
# server stays empty and the unit stays readable.

step "Service"

unit_tmp="$(mktemp)"
trap 'rm -f "$unit_tmp"' EXIT
sed -e "s|^\(ConditionPathExists=\).*|\1$APP_DIR/main.ts|" \
  -e "s|^\(WorkingDirectory=\).*|\1$APP_DIR|" \
  -e "s|^\(BindReadOnlyPaths=\).*|\1$APP_DIR|" \
  -e "s|^\(BindPaths=\).*|\1$APP_DIR/$DATA_DIR|" \
  -e "s|^\(User=\).*|\1$SERVICE_USER|" \
  -e "s|^\(Group=\).*|\1$SERVICE_GROUP|" \
  "$UNIT_SRC" >"$unit_tmp"

install -o root -g root -m 0644 "$unit_tmp" "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true

# restart, not reload: the unit is Type=exec and has no reload semantics.
systemctl restart "$SERVICE_NAME"
info "$SERVICE_NAME restarted (WorkingDirectory=$APP_DIR)"

# --- health ----------------------------------------------------------------------
# The deployment is not finished when systemd returns; it is finished when the
# application answers. Fifteen tries at a fifth of a second is generous for a
# process whose entire startup is opening a KV file and reading a directory.

step "Health"

probe() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "http://127.0.0.1:$APP_PORT/healthz"
  else
    "$DENO" eval --allow-net=127.0.0.1 \
      "const r = await fetch('http://127.0.0.1:$APP_PORT/healthz');
       if (!r.ok) Deno.exit(1);
       console.log(await r.text());"
  fi
}

healthy=0
for _ in $(seq 1 15); do
  if body="$(probe 2>/dev/null)"; then
    healthy=1
    break
  fi
  sleep 0.2
done

if [ "$healthy" -eq 0 ]; then
  systemctl --no-pager --lines=20 status "$SERVICE_NAME" >&2 || true
  fail "no answer on 127.0.0.1:$APP_PORT/healthz — the service is not serving.
       If the journal shows a Deno.openKv permission error, the service cannot
       write $DATA_DIR: sudo chown -R $SERVICE_USER:$OWNER_GROUP $APP_DIR/$DATA_DIR"
fi
info "127.0.0.1:$APP_PORT/healthz -> $(printf '%s' "$body" | tr -d '\n')"

# A signup writes the KV database, so exercise that path once rather than
# trusting that a served /healthz means a writable store. It is idempotent per
# email, so re-running the deploy does not inflate the count.
if command -v curl >/dev/null 2>&1; then
  join="$(curl -fsS --max-time 3 -X POST \
    -H 'content-type: application/json' \
    --data '{"email":"deploy-probe@denogenesis.com"}' \
    "http://127.0.0.1:$APP_PORT/api/waitlist" 2>/dev/null || true)"
  case "$join" in
    *'"status":"added"'* | *'"status":"existing"'*)
      info "$SERVICE_USER can write its database (POST /api/waitlist -> $join)"
      ;;
    *)
      systemctl --no-pager --lines=20 status "$SERVICE_NAME" >&2 || true
      fail "POST /api/waitlist did not persist: '$join'
       the service likely cannot write $DATA_DIR: sudo chown -R $SERVICE_USER:$OWNER_GROUP $APP_DIR/$DATA_DIR"
      ;;
  esac
fi

# --- certificates --------------------------------------------------------------
# Before the reverse proxy, because the vhost names its key material by
# absolute path: `nginx -t` fails outright if the lineage is not on disk yet.
#
# The bootstrap is the chicken and egg of ACME. The certificate cannot be
# issued until the CA can reach http://$SITE_NAME/.well-known/acme-challenge/,
# and the real configuration cannot load until the certificate exists. So for a
# first issuance only, a plaintext server block that serves the challenge and
# nothing else goes up, and the real one replaces it a step later. A host that
# already has the lineage skips all of this: its live configuration already
# serves the challenge from the same webroot, and renewal needs no downtime.

# `nginx -t` first, always: a configuration that does not parse must never
# reach a running Nginx, and on a fresh host there is nothing to reload yet.
nginx_apply() {
  nginx -t >&2 || fail "nginx rejected the configuration; the running one was left alone"
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl enable --now nginx >/dev/null 2>&1 || systemctl start nginx
  fi
}

step "Certificates"

if [ "$SKIP_CERTBOT" -eq 1 ]; then
  info "skipped ($([ "$SKIP_NGINX" -eq 1 ] && echo --skip-nginx || echo --skip-certbot))"
else
  # The webroot is world-readable and holds nothing but challenge tokens, which
  # are public by design and deleted as soon as they are answered.
  install -d -m 0755 "$WEBROOT"

  certbot_args=(certonly --webroot -w "$WEBROOT" --cert-name "$CERT_NAME"
    --non-interactive --agree-tos -m "$CERTBOT_EMAIL")
  for domain in $CERT_DOMAINS; do certbot_args+=(-d "$domain"); done
  [ "$CERTBOT_STAGING" -eq 0 ] || certbot_args+=(--staging)
  if [ "$FORCE_RENEWAL" -eq 1 ]; then
    certbot_args+=(--force-renewal)
  else
    # Idempotence: a certificate with more than 30 days left is left alone.
    certbot_args+=(--keep-until-expiring)
  fi

  if [ ! -s "$CERT_DIR/fullchain.pem" ]; then
    info "no lineage at $CERT_DIR — bootstrapping over plaintext"

    # Only the challenge, and 503 for everything else. This is the port 80
    # block of the real vhost, minus everything that depends on a certificate.
    cat >"/etc/nginx/sites-available/$SITE_NAME" <<EOF
# Temporary: written by deploy/deploy.sh for the first ACME challenge only.
# Replaced by deploy/nginx/$SITE_NAME.conf as soon as the certificate exists.
server {
    listen 80;
    listen [::]:80;
    server_name ${CERT_DOMAINS};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 503;
    }
}
EOF
    ln -sfn "/etc/nginx/sites-available/$SITE_NAME" "/etc/nginx/sites-enabled/$SITE_NAME"
    nginx_apply
  else
    expiry="$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)"
    info "lineage exists${expiry:+, expires $expiry}"
  fi

  certbot "${certbot_args[@]}" >&2 ||
    fail "certbot could not issue for $CERT_DOMAINS — check that DNS points here and 80/tcp is open"

  [ -s "$CERT_DIR/fullchain.pem" ] ||
    fail "certbot reported success but $CERT_DIR/fullchain.pem is not there"
  info "certificate in place at $CERT_DIR"

  # Renewal runs unattended from certbot's own timer. Nginx keeps the old
  # certificate in memory until told otherwise, so the reload is the half of
  # renewal that is this deployment's responsibility.
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
# Written by deploy/deploy.sh. Certbot renews the file; Nginx has to be told
# to read it again, or it serves the expired one it already has in memory.
set -eu
nginx -t && systemctl reload nginx
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

  if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    info "renewal: certbot.timer, reload hook installed"
  else
    info "renewal: no certbot.timer on this host — schedule 'certbot renew' yourself"
  fi
fi

# --- reverse proxy -----------------------------------------------------------------
# The vhost, plus the two box-wide pieces it depends on: the probe snippet it
# includes, and the catch-all that closes the connection on requests addressed
# to no server_name at all. Both are shared with every other site on the host,
# and installing them is idempotent.

step "Reverse proxy"

if [ "$SKIP_NGINX" -eq 1 ]; then
  info "skipped (--skip-nginx)"
else
  install -d -m 0755 /etc/nginx/snippets
  install -o root -g root -m 0644 "$SNIPPET_SRC" /etc/nginx/snippets/deny-probes.conf
  install -o root -g root -m 0644 "$DEFAULT_DROP_SRC" /etc/nginx/sites-available/00-default-drop

  # The distro default site answers for any unmatched Host, which is exactly
  # what 00-default-drop is here to stop doing.
  rm -f /etc/nginx/sites-enabled/default
  ln -sfn /etc/nginx/sites-available/00-default-drop /etc/nginx/sites-enabled/00-default-drop

  install -o root -g root -m 0644 "$NGINX_SRC" "/etc/nginx/sites-available/$SITE_NAME"
  ln -sfn "/etc/nginx/sites-available/$SITE_NAME" "/etc/nginx/sites-enabled/$SITE_NAME"

  nginx_apply
  info "nginx serving $SITE_NAME, probes dropped, default site removed"
fi

# --- fail2ban -----------------------------------------------------------------------
# The filter is this repository's and is kept current. jail.local is the box's,
# shared with every other site, and carries edits that are deliberately not in
# git (the real sshd port) — so it is installed only when absent.

step "fail2ban"

if [ "$SKIP_FAIL2BAN" -eq 1 ]; then
  info "skipped (--skip-fail2ban)"
else
  install -o root -g root -m 0644 "$F2B_FILTER_SRC" /etc/fail2ban/filter.d/nginx-probes.conf

  if [ -e /etc/fail2ban/jail.local ]; then
    info "/etc/fail2ban/jail.local exists, left alone"
  else
    install -o root -g root -m 0644 "$F2B_JAIL_SRC" /etc/fail2ban/jail.local
    info "installed /etc/fail2ban/jail.local — set the real sshd port in it"
  fi

  # Restart, not reload: apt starts fail2ban before jail.local exists, and a
  # running daemon does not pick the file up any other way.
  systemctl restart fail2ban

  # systemctl returns before fail2ban has bound its socket, and a client that
  # cannot connect looks exactly like a jail that does not exist. Ask until it
  # answers something that is actually about the jail.
  jail_status=""
  for _ in $(seq 1 20); do
    jail_status="$(fail2ban-client status nginx-probes 2>&1 || true)"
    case "$jail_status" in
      *"File list:"* | *"Journal matches:"* | *"does not exist"*) break ;;
    esac
    sleep 0.4
  done

  # Two ways to be wrong, and they need different fixes: the jail can be
  # missing from a jail.local this script declined to overwrite, or it can be
  # present and reading the journal, where nginx access logs never appear.
  case "$jail_status" in
    *"File list:"*)
      info "jail nginx-probes is reading the access logs"
      ;;
    *"Journal matches:"*)
      info "warning: nginx-probes is reading the journal, where nginx logs never appear."
      info "         add 'backend = polling' to its stanza in /etc/fail2ban/jail.local"
      ;;
    *)
      info "warning: no working nginx-probes jail. fail2ban-client said:"
      printf '        %s\n' "$jail_status" >&2
      info "         this host's jail.local was left alone; add the stanza from $F2B_JAIL_SRC"
      ;;
  esac
fi

step "Deployed"
info "journalctl -u $SERVICE_NAME -f"
info "sudo systemctl status $SERVICE_NAME"
info "sudo fail2ban-client status nginx-probes"
