#!/bin/bash
set -euo pipefail

USER_NAME="usr"
USER_PASS="pass"
PORT="8080"
IMAGE="ubuntu/squid:latest"
CONTAINER_NAME="squid"
BASE_DIR="/root/squid-auth-proxy"

mkdir -p "$BASE_DIR/data/log" "$BASE_DIR/data/cache" "$BASE_DIR/data/auth"
chmod -R 777 "$BASE_DIR/data/log" "$BASE_DIR/data/cache"

IFACE=$(ip -o link show | awk -F': ' '$2 ~ /^ens/ {print $2; exit}')
IPS=$(ip -4 addr show dev "$IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)

HASH=$(openssl passwd -apr1 "$USER_PASS")
echo "${USER_NAME}:${HASH}" > "$BASE_DIR/data/auth/passwd"
chmod 644 "$BASE_DIR/data/auth/passwd"

cat > "$BASE_DIR/squid.conf" <<EOF
visible_hostname proxy

EOF

i=1
for IP in $IPS; do
  echo "http_port ${IP}:${PORT} name=port_ip${i}" >> "$BASE_DIR/squid.conf"
  i=$((i+1))
done

echo "" >> "$BASE_DIR/squid.conf"

i=1
for IP in $IPS; do
  echo "acl to_ip${i} myportname port_ip${i}" >> "$BASE_DIR/squid.conf"
  i=$((i+1))
done

echo "" >> "$BASE_DIR/squid.conf"

i=1
for IP in $IPS; do
  echo "tcp_outgoing_address ${IP} to_ip${i}" >> "$BASE_DIR/squid.conf"
  i=$((i+1))
done

cat >> "$BASE_DIR/squid.conf" <<'EOF'

auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm Squid Proxy
auth_param basic credentialsttl 8 hours
auth_param basic children 20 startup=5 idle=5
auth_param basic casesensitive on

acl authenticated proxy_auth REQUIRED

forwarded_for delete
via on
request_header_access X-Forwarded-For deny all
request_header_access Proxy-Connection deny all

acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 1025-65535
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow authenticated
http_access deny all

cache deny all
access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log
pid_filename /tmp/squid.pid

client_persistent_connections on
server_persistent_connections on

refresh_pattern . 0 20% 4320
EOF

docker rm -f "$CONTAINER_NAME" squid-auth-proxy >/dev/null 2>&1 || true
docker pull "$IMAGE"

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart always  \
  --network host \
  --user root \
  -v "$BASE_DIR/squid.conf:/etc/squid/squid.conf:ro" \
  -v "$BASE_DIR/data/auth/passwd:/etc/squid/passwd:ro" \
  -v "$BASE_DIR/data/log:/var/log/squid" \
  -v "$BASE_DIR/data/cache:/var/spool/squid" \
  "$IMAGE" \
  squid -N -f /etc/squid/squid.conf -d 1

sleep 3
docker logs --tail 100 "$CONTAINER_NAME"

FIRST_IP=$(echo "$IPS" | head -n1)
echo "Test:"
echo "curl -v -x http://${USER_NAME}:${USER_PASS}@${FIRST_IP}:${PORT} https://ifconfig.me"
