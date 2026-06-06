#!/usr/bin/env bash

nginx_core_install() {
  require_root

  log "Checking OS..."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "Only Debian is supported. Current OS: ${ID:-unknown}"
  [[ "${VERSION_CODENAME:-}" == "bookworm" ]] || die "Only Debian 12 bookworm is supported. Current: ${VERSION_CODENAME:-unknown}"

  log "Installing base packages..."
  apt-get update
  apt-get install -y \
    curl \
    gnupg2 \
    ca-certificates \
    lsb-release \
    debian-archive-keyring \
    apt-transport-https \
    snapd \
    openssl

  log "Configuring nginx.org mainline repository..."
  install -d -m 0755 /usr/share/keyrings

  curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

  cat > /etc/apt/sources.list.d/nginx.list <<'EOF'
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/debian bookworm nginx
EOF

  cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF

  apt-get update
  apt-get install -y nginx

  systemctl enable --now nginx

  log "Preparing standard directories..."
  mkdir -p /etc/nginx/http.d
  mkdir -p /etc/nginx/stream.d
  mkdir -p /var/log/nginx

  nginx_core_ensure_http_include
  nginx_core_ensure_stream_include

  nginx -t
  nginx -v
}

nginx_core_ensure_http_include() {
  local conf="/etc/nginx/nginx.conf"

  if grep -Fq "include /etc/nginx/http.d/*.conf;" "${conf}"; then
    return
  fi

  backup_file "${conf}"

  if grep -Fq "include /etc/nginx/conf.d/*.conf;" "${conf}"; then
    sed -i '/include \/etc\/nginx\/conf.d\/\*.conf;/a\    include /etc/nginx/http.d/*.conf;' "${conf}" \
      || die "Failed to add http.d include to nginx.conf"
  else
    sed -i '/http {/a\    include /etc/nginx/http.d/*.conf;' "${conf}" \
      || die "Failed to add http.d include to nginx.conf"
  fi
}

nginx_core_ensure_stream_include() {
  local conf="/etc/nginx/nginx.conf"

  if grep -Fq "include /etc/nginx/stream.d/*.conf;" "${conf}"; then
    return
  fi

  backup_file "${conf}"

  cat >> "${conf}" <<'EOF'

# Managed by nginx-gateway.
# L4 TCP/UDP proxy configs should be placed under /etc/nginx/stream.d/.
stream {
    log_format stream_basic '$remote_addr [$time_local] '
                            '$protocol $status $bytes_sent $bytes_received '
                            '$session_time "$upstream_addr"';

    access_log /var/log/nginx/stream.access.log stream_basic;
    error_log  /var/log/nginx/stream.error.log warn;

    include /etc/nginx/stream.d/*.conf;
}
EOF
}
