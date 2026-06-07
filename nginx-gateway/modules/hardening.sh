#!/usr/bin/env bash

nginx_hardening_install() {
  require_root

  local conf="/etc/nginx/http.d/00-gateway-hardening.conf"

  log "Installing Nginx gateway HTTP hardening baseline..."

  nginx_hardening_render | safe_apply_nginx_conf "${conf}"
}

nginx_hardening_render() {
  cat <<'EOF'
# Managed by nginx-gateway.
# Baseline HTTP hardening and performance defaults.
# This file is loaded inside the nginx http context through /etc/nginx/http.d/*.conf.
# The defaults are intentionally friendly to WebSocket, SSE, long polling,
# streaming APIs, and other long-lived HTTP connections.

# Hide the Nginx version from default error pages and the Server response header.
# Note: stock Nginx still returns "Server: nginx". Removing the header completely
# requires third-party modules or a custom build, which this toolkit does not use.
server_tokens off;

# Basic timeout hardening.
# These values avoid overly aggressive disconnects for slow clients and long-lived traffic.
client_header_timeout 30s;
client_body_timeout 300s;
send_timeout 300s;
keepalive_timeout 75s;
reset_timedout_connection on;

# Default upload/body size. Individual server blocks can override it.
client_max_body_size 50m;

# WebSocket-friendly connection upgrade mapping.
# Reverse proxy locations should use:
#   proxy_set_header Upgrade $http_upgrade;
#   proxy_set_header Connection $connection_upgrade;
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

# Long-lived upstream defaults.
# proxy_read_timeout controls idle upstream reads and is the key setting for
# WebSocket/SSE/long polling connections that may stay open for a long time.
proxy_connect_timeout 10s;
proxy_send_timeout 3600s;
proxy_read_timeout 3600s;

# Streaming-friendly defaults.
# This improves WebSocket/SSE/log tail/AI streaming behavior at the cost of
# some buffering efficiency for normal HTTP responses.
proxy_buffering off;
proxy_request_buffering off;
proxy_cache off;

# Compression for text-like responses.
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types
    text/plain
    text/css
    text/xml
    application/xml
    application/json
    application/javascript
    application/rss+xml
    image/svg+xml;

# Conservative security headers. HSTS is intentionally not enabled globally.
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-XSS-Protection "0" always;

# Hide common upstream framework headers from proxied responses.
proxy_hide_header X-Powered-By;
proxy_hide_header Server;
EOF
}
