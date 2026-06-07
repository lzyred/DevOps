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

# Hide the Nginx version from default error pages and the Server response header.
# Note: stock Nginx still returns "Server: nginx". Removing the header completely
# requires third-party modules or a custom build, which this toolkit does not use.
server_tokens off;

# Basic timeout hardening against slow clients.
client_header_timeout 15s;
client_body_timeout 30s;
send_timeout 30s;
keepalive_timeout 65s;
reset_timedout_connection on;

# Default upload/body size. Individual server blocks can override it.
client_max_body_size 50m;

# WebSocket-friendly connection upgrade mapping.
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

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
