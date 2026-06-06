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
  local tmp

  if grep -Fq "include /etc/nginx/http.d/*.conf;" "${conf}"; then
    return
  fi

  tmp="$(mktemp /tmp/nginx-gateway-nginxconf.XXXXXX)"
  cp -a "${conf}" "${tmp}"

  if grep -Fq "include /etc/nginx/conf.d/*.conf;" "${tmp}"; then
    sed -i '/include \/etc\/nginx\/conf.d\/\*.conf;/a\    include /etc/nginx/http.d/*.conf;' "${tmp}"
  else
    sed -i '/http {/a\    include /etc/nginx/http.d/*.conf;' "${tmp}"
  fi

  safe_apply_nginx_conf "${conf}" < "${tmp}"
  rm -f "${tmp}"
}

nginx_core_ensure_stream_include() {
  local conf="/etc/nginx/nginx.conf"
  local tmp

  if grep -Fq "include /etc/nginx/stream.d/*.conf;" "${conf}"; then
    return
  fi

  nginx_core_ensure_stream_module_available

  tmp="$(mktemp /tmp/nginx-gateway-nginxconf.XXXXXX)"
  cp -a "${conf}" "${tmp}"

  cat >> "${tmp}" <<'EOF'

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

  safe_apply_nginx_conf "${conf}" < "${tmp}"
  rm -f "${tmp}"
}

nginx_core_ensure_stream_module_available() {
  if nginx -V 2>&1 | grep -Eq -- '--with-stream(=dynamic)?'; then
    nginx_core_ensure_dynamic_stream_loaded || true
    return
  fi

  if apt-cache show nginx-module-stream >/dev/null 2>&1; then
    log "Installing nginx-module-stream package..."
    apt-get install -y nginx-module-stream
    nginx_core_ensure_dynamic_stream_loaded || true
    return
  fi

  warn "Could not confirm Nginx stream module from nginx -V or package metadata."
  warn "The next nginx -t will be the source of truth; rollback will happen if stream is unsupported."
}

nginx_core_ensure_dynamic_stream_loaded() {
  local conf="/etc/nginx/nginx.conf"
  local module_path=""
  local tmp

  if nginx -V 2>&1 | grep -Eq -- '--with-stream( |$)'; then
    return 0
  fi

  module_path="$(find /usr/lib/nginx/modules /usr/lib64/nginx/modules -name 'ngx_stream_module.so' 2>/dev/null | head -n 1 || true)"
  [[ -n "${module_path}" ]] || return 1

  if grep -Fq "${module_path}" "${conf}" || grep -Fq "ngx_stream_module.so" "${conf}"; then
    return 0
  fi

  tmp="$(mktemp /tmp/nginx-gateway-nginxconf.XXXXXX)"
  {
    echo "load_module ${module_path};"
    cat "${conf}"
  } > "${tmp}"

  safe_apply_nginx_conf "${conf}" < "${tmp}"
  rm -f "${tmp}"
}
