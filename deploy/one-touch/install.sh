#!/usr/bin/env bash
# ParanoID one-touch server installer (RFC-0027 identity-v3, private Devnet test scope).
#
# Run as root on a fresh Ubuntu 24.04+/Debian 13+ host whose public IPv4 is assigned to
# a local interface. Installs PostgreSQL (private Unix socket only), the ParanoID server,
# a coturn voice relay and a ufw firewall, all as dedicated system users.
#
#   install.sh --binary ./paranoid-server [--ip 203.0.113.10]
#
# Idempotent and non-destructive: a second run upgrades the binary and restarts services,
# but NEVER re-initializes the database, regenerates the TLS key (the app pins it) or the
# TURN secret. It never deletes data. Prints the public connection descriptor last.
set -euo pipefail
umask 077

BINARY="" IP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
[ -n "$BINARY" ] && [ -f "$BINARY" ] || { echo "--binary <paranoid-server> required" >&2; exit 2; }
if [ -z "$IP" ]; then
  IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "cannot determine public IPv4; pass --ip" >&2; exit 2; }
ip -4 -o addr show | grep -q " $IP/" || { echo "$IP is not assigned to a local interface (NAT is unsupported)" >&2; exit 2; }
case "$IP" in 10.*|127.*|169.254.*|172.1[6-9].*|172.2?.*|172.3[01].*|192.168.*|100.6[4-9].*|100.[7-9]?.*|100.1[01]?.*|100.12[0-7].*)
  echo "$IP is not a public address" >&2; exit 2 ;; esac

PORT=38444
BASE=/var/lib/paranoid
RUN="$BASE/paranoid-run"      # name must start with "paranoid-" (server guard)
SOCK="$RUN/socket"
ETC=/etc/paranoid
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'); SSH_PORT=${SSH_PORT:-22}
log(){ printf '[paranoid] %s\n' "$*" >&2; }

log "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql coturn ufw openssl >/dev/null
# Distribution clusters/daemons are not used; ParanoID runs its own private instances.
systemctl disable --now postgresql.service coturn.service >/dev/null 2>&1 || true
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)

log "users and directories"
id paranoid >/dev/null 2>&1 || useradd --system --home-dir "$BASE" --shell /usr/sbin/nologin paranoid
id paranoid-turn >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin paranoid-turn
install -d -m 0700 -o paranoid -g paranoid "$BASE" "$RUN" "$SOCK"
install -d -m 0750 -o root -g paranoid "$ETC"
install -d -m 0755 /opt/paranoid/bin

log "server binary"
install -m 0755 -o root -g root "$BINARY" /opt/paranoid/bin/paranoid-server.new
mv -f /opt/paranoid/bin/paranoid-server.new /opt/paranoid/bin/paranoid-server

log "TLS identity (kept across runs; the app pins its public key)"
if [ ! -f "$ETC/tls/server.key" ]; then
  install -d -m 0750 -o root -g paranoid "$ETC/tls"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 825 \
    -subj "/CN=ParanoID server" -addext "subjectAltName=IP:$IP" -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=serverAuth" \
    -keyout "$ETC/tls/server.key" -out "$ETC/tls/server.crt" >/dev/null 2>&1
  chown root:paranoid "$ETC/tls/server.key" "$ETC/tls/server.crt"; chmod 0640 "$ETC/tls/server.key" "$ETC/tls/server.crt"
fi
PIN=$(openssl x509 -in "$ETC/tls/server.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
REALM="https://$IP:$PORT"

log "TURN secret (kept across runs)"
if [ ! -f "$ETC/turn.secret" ]; then
  openssl rand -hex 32 | tr -d '\n' > "$ETC/turn.secret"
fi
chown paranoid:paranoid "$ETC/turn.secret"; chmod 0400 "$ETC/turn.secret"

log "PostgreSQL (private socket, no TCP)"
if [ ! -f "$BASE/pgdata/PG_VERSION" ]; then
  runuser -u paranoid -- "$PGBIN/initdb" -D "$BASE/pgdata" --auth-local=peer --auth-host=reject --no-locale -E UTF8 >/dev/null
fi
cat > /etc/systemd/system/paranoid-postgres.service <<EOF
[Unit]
Description=ParanoID private PostgreSQL
After=network.target
[Service]
Type=simple
User=paranoid
ExecStart=$PGBIN/postgres -D $BASE/pgdata -k $SOCK -c listen_addresses= -c unix_socket_permissions=0700 -c max_connections=40 -c log_statement=none -c log_min_error_statement=panic
KillMode=mixed
KillSignal=SIGINT
TimeoutStopSec=60
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$BASE
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now paranoid-postgres.service >/dev/null
for _ in $(seq 1 100); do runuser -u paranoid -- "$PGBIN/pg_isready" -h "$SOCK" -q && break; sleep 0.1; done
runuser -u paranoid -- "$PGBIN/pg_isready" -h "$SOCK" -q || { log "PostgreSQL did not start"; exit 1; }
DB_URL="postgresql://paranoid@localhost/paranoid?host=$SOCK"
if ! runuser -u paranoid -- "$PGBIN/psql" -h "$SOCK" -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='paranoid'" | grep -q 1; then
  runuser -u paranoid -- "$PGBIN/createdb" -h "$SOCK" paranoid
fi

cat > "$ETC/identity.env" <<EOF
PARANOID_MODE=identity-v3
PARANOID_DATABASE_URL=$DB_URL
PARANOID_KEY_REALM=$REALM
PARANOID_KEY_PIN=$PIN
PARANOID_BIND=$IP:$PORT
PARANOID_REVIEWED_IDENTITY_V3_IP=$IP
PARANOID_TLS_CERT=$ETC/tls/server.crt
PARANOID_TLS_KEY=$ETC/tls/server.key
PARANOID_TURN_SECRET_FILE=$ETC/turn.secret
PARANOID_TURN_RELAY_IP=$IP
EOF
chown root:paranoid "$ETC/identity.env"; chmod 0640 "$ETC/identity.env"

INITIALIZED=$(runuser -u paranoid -- "$PGBIN/psql" -h "$SOCK" -d paranoid -Atqc "SELECT to_regclass('public.id_meta') IS NOT NULL")
if [ "$INITIALIZED" != t ]; then
  log "database schema (first run only, empty database)"
  runuser -u paranoid -- env "PARANOID_DATABASE_URL=$DB_URL" "PARANOID_KEY_REALM=$REALM" "PARANOID_KEY_PIN=$PIN" \
    /opt/paranoid/bin/paranoid-server identity-v3-init
fi

log "voice relay (coturn)"
install -d -m 0750 -o root -g paranoid-turn "$ETC/turn"
{
  cat <<EOF
listening-ip=$IP
relay-ip=$IP
listening-port=34781
min-port=40000
max-port=40015
realm=paranoid-voice-v1
fingerprint
use-auth-secret
static-auth-secret=$(cat "$ETC/turn.secret")
user-quota=4
total-quota=16
max-bps=128000
bps-capacity=512000
max-allocate-lifetime=60
stale-nonce=60
relay-threads=1
cli=0
no-tls
no-dtls
no-stun
no-tcp-relay
no-multicast-peers
no-software-attribute
no-stdout-log
simple-log
log-file=/dev/null
syslog=0
pidfile=/run/paranoid-turn/turnserver.pid
EOF
  for range in 0.0.0.0-0.255.255.255 10.0.0.0-10.255.255.255 100.64.0.0-100.127.255.255 127.0.0.0-127.255.255.255 \
      169.254.0.0-169.254.255.255 172.16.0.0-172.31.255.255 192.0.0.0-192.0.0.255 192.0.2.0-192.0.2.255 \
      192.168.0.0-192.168.255.255 198.18.0.0-198.19.255.255 198.51.100.0-198.51.100.255 203.0.113.0-203.0.113.255 \
      224.0.0.0-255.255.255.255; do echo "denied-peer-ip=$range"; done
  echo "allowed-peer-ip=$IP"
} > "$ETC/turn/turnserver.conf"
chown root:paranoid-turn "$ETC/turn/turnserver.conf"; chmod 0640 "$ETC/turn/turnserver.conf"
cat > /etc/systemd/system/paranoid-turn.service <<EOF
[Unit]
Description=ParanoID voice relay (coturn)
After=network-online.target
Wants=network-online.target
[Service]
User=paranoid-turn
Group=paranoid-turn
RuntimeDirectory=paranoid-turn
ExecStart=/usr/bin/turnserver -c $ETC/turn/turnserver.conf
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
[Install]
WantedBy=multi-user.target
EOF

log "ParanoID server service"
cat > /etc/systemd/system/paranoid-server.service <<EOF
[Unit]
Description=ParanoID server (identity-v3, private Devnet test)
After=paranoid-postgres.service network-online.target
Requires=paranoid-postgres.service
Wants=network-online.target
[Service]
User=paranoid
Group=paranoid
EnvironmentFile=$ETC/identity.env
ExecStart=/opt/paranoid/bin/paranoid-server
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$RUN
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable paranoid-turn.service paranoid-server.service >/dev/null
systemctl restart paranoid-turn.service paranoid-server.service

log "firewall: SSH $SSH_PORT, server $PORT, relay 34781 + 40000-40015/udp"
ufw allow "$SSH_PORT/tcp" comment 'ssh' >/dev/null
ufw allow "$PORT/tcp" comment 'paranoid server' >/dev/null
ufw allow 34781 comment 'paranoid voice relay' >/dev/null
ufw allow 40000:40015/udp comment 'paranoid voice relay media' >/dev/null
ufw --force enable >/dev/null

log "health check"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 3 --cacert "$ETC/tls/server.crt" "$REALM/health" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 5 --cacert "$ETC/tls/server.crt" "$REALM/health" >/dev/null || { log "server did not become healthy"; systemctl --no-pager status paranoid-server.service | tail -5 >&2; exit 1; }
systemctl is-active --quiet paranoid-turn.service || { log "voice relay not running"; exit 1; }
log "installed"
printf '{"server_url":"%s","tls_spki_sha256":"%s"}\n' "$REALM" "$PIN"
