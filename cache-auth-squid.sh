#!/bin/bash
set -euo pipefail

USER_NAME="usr"
USER_PASS="pass"
PORT="8080"
CONTAINER_NAME="squid-proxy"
BASE_DIR="/root/squid-auth-proxy"

# 1. Create necessary directories
mkdir -p "$BASE_DIR/data/auth" "$BASE_DIR/certs"

# 2. Generate SSL Certificate for Bumping if it doesn't exist
if [ ! -f "$BASE_DIR/certs/private.pem" ]; then
    echo "Generating Squid Root CA Certificate..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -keyout "$BASE_DIR/certs/private.pem" \
        -out "$BASE_DIR/certs/private.pem" \
        -subj "/C=IN/ST=Telangana/L=Hyderabad/O=SquidProxy/CN=SquidCA"
fi
chmod 644 "$BASE_DIR/certs/private.pem"

# 3. Build a custom Alpine Docker image with OpenSSL and an auto-truncating log-streaming Entrypoint
echo "Building custom Squid image with OpenSSL support..."
cat > "$BASE_DIR/Dockerfile" <<'EOF'
FROM alpine:latest
RUN apk add --no-cache squid openssl
RUN /usr/lib/squid/security_file_certgen -c -s /var/lib/ssl_db -M 4MB && chown -R squid:squid /var/lib/ssl_db

RUN echo '#!/bin/sh' > /entrypoint.sh && \
    echo 'mkdir -p /var/log/squid' >> /entrypoint.sh && \
    echo 'touch /var/log/squid/access.log /var/log/squid/cache.log' >> /entrypoint.sh && \
    echo 'chown -R squid:squid /var/log/squid' >> /entrypoint.sh && \
    echo 'tail -F /var/log/squid/access.log > /dev/stdout &' >> /entrypoint.sh && \
    echo 'tail -F /var/log/squid/cache.log > /dev/stderr &' >> /entrypoint.sh && \
    echo '(while true; do sleep 86400; truncate -s 0 /var/log/squid/access.log /var/log/squid/cache.log; done) &' >> /entrypoint.sh && \
    echo 'exec squid -N -d 1' >> /entrypoint.sh && \
    chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
EOF

docker build --network host -t my-alpine-squid-ssl "$BASE_DIR"
IMAGE="my-alpine-squid-ssl"

# 4. Handle IP extraction
IFACE=$(ip -o link show | awk -F': ' '$2 ~ /^(ens|eth)/ {print $2; exit}')
IPS=$(ip -4 addr show dev "$IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)

HASH=$(openssl passwd -apr1 "$USER_PASS")
echo "${USER_NAME}:${HASH}" > "$BASE_DIR/data/auth/passwd"
chmod 644 "$BASE_DIR/data/auth/passwd"

# 5. Build the Squid Configuration file
cat > "$BASE_DIR/squid.conf" <<EOF
visible_hostname proxy

EOF

i=1
for IP in $IPS; do
  echo "http_port ${IP}:${PORT} ssl-bump generate-host-certificates=on dynamic_cert_mem_cache_size=4MB cert=/etc/squid-cert/private.pem key=/etc/squid-cert/private.pem name=port_ip${i}" >> "$BASE_DIR/squid.conf"
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
http_access allow all

# -----------------------------------------------------------------------------
# SSL BUMP LOGIC (Peek & Splice / Bump)
# -----------------------------------------------------------------------------
acl target_ssl_domain ssl::server_name .tirupatibalaji.ap.gov.in
acl step1 at_step SslBump1
acl step2 at_step SslBump2

ssl_bump peek step1 all
ssl_bump bump step2 target_ssl_domain
ssl_bump splice all

sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/lib/ssl_db -M 4MB
sslcrtd_children 20 startup=1 idle=1

# -----------------------------------------------------------------------------
# MEMORY CACHING & HEADER STRIPPING
# -----------------------------------------------------------------------------
cache_mem 256 MB
maximum_object_size_in_memory 20 MB

acl target_cache_domain dstdomain .tirupatibalaji.ap.gov.in

acl static_files urlpath_regex -i \.(png|jpg|jpeg|gif|ico|css|js|json|woff|woff2|ttf|svg)(\?.*)?$
acl cacheable_apis urlpath_regex -i /common/banks

reply_header_access Set-Cookie deny static_files
reply_header_access Vary deny static_files
reply_header_access Set-Cookie deny cacheable_apis
reply_header_access Vary deny cacheable_apis

cache allow target_cache_domain static_files
cache allow target_cache_domain cacheable_apis
cache deny all

access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log
logfile_rotate 0
pid_filename /tmp/squid.pid

client_persistent_connections on
server_persistent_connections on

refresh_pattern -i \.(png|jpg|jpeg|gif|ico|css|js|json|woff|woff2|ttf|svg)(\?.*)?$ 10080 100% 10080 override-expire override-lastmod ignore-reload ignore-no-cache ignore-no-store ignore-private ignore-auth ignore-must-revalidate
refresh_pattern -i /common/banks 10080 100% 10080 override-expire override-lastmod ignore-reload ignore-no-cache ignore-no-store ignore-private ignore-auth ignore-must-revalidate

refresh_pattern . 0 20% 4320
EOF

# 6. Cleanup & Restart
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "Starting Squid Proxy..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart always  \
  --network host \
  --log-opt max-size=50m \
  --log-opt max-file=3 \
  -v "$BASE_DIR/squid.conf:/etc/squid/squid.conf:ro" \
  -v "$BASE_DIR/data/auth/passwd:/etc/squid/passwd:ro" \
  -v "$BASE_DIR/certs:/etc/squid-cert:ro" \
  "$IMAGE"

sleep 3
echo "========================================="
echo "Container running! Live logs will output below:"
echo "========================================="
docker logs -f "$CONTAINER_NAME"
