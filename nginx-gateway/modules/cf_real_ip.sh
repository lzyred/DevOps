#!/usr/bin/env bash

nginx_cf_real_ip_install() {
  require_root

  local script_path="/usr/local/sbin/update-cloudflare-real-ip"

  log "Installing Cloudflare Real IP updater..."

  if ! command -v curl >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl
  fi

  cat > "${script_path}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONF="/etc/nginx/http.d/00-cloudflare-real-ip.conf"
TMP="$(mktemp /tmp/cloudflare-real-ip.XXXXXX)"
BACKUP=""
HAD_OLD=false

cleanup() {
  rm -f "${TMP}"
}

trap cleanup EXIT

mkdir -p /etc/nginx/http.d

{
  echo "# Managed by nginx-gateway."
  echo "# Cloudflare IP ranges are fetched from Cloudflare official endpoints."
  echo

  curl -fsSL https://www.cloudflare.com/ips-v4 \
    | sed -E 's#^#set_real_ip_from #' \
    | sed -E 's#$#;#'

  curl -fsSL https://www.cloudflare.com/ips-v6 \
    | sed -E 's#^#set_real_ip_from #' \
    | sed -E 's#$#;#'

  echo
  echo "real_ip_header CF-Connecting-IP;"
  echo "real_ip_recursive on;"
} > "${TMP}"

if [[ ! -s "${TMP}" ]]; then
  echo "[ERROR] Generated Cloudflare Real IP config is empty." >&2
  exit 1
fi

grep -q "set_real_ip_from" "${TMP}" || {
  echo "[ERROR] Generated config does not contain Cloudflare IP ranges." >&2
  exit 1
}

grep -q "real_ip_header CF-Connecting-IP;" "${TMP}" || {
  echo "[ERROR] Generated config does not contain real_ip_header." >&2
  exit 1
}

if [[ -f "${CONF}" ]]; then
  HAD_OLD=true
  BACKUP="${CONF}.bak.$(date +%Y%m%d%H%M%S).$$"
  cp -a "${CONF}" "${BACKUP}"
fi

install -m 0644 "${TMP}" "${CONF}"

if ! nginx -t; then
  echo "[ERROR] nginx -t failed after updating Cloudflare Real IP config; rolling back." >&2

  if [[ "${HAD_OLD}" == true ]]; then
    install -m 0644 "${BACKUP}" "${CONF}"
  else
    rm -f "${CONF}"
  fi

  nginx -t >/dev/null 2>&1 || true
  exit 1
fi

if ! systemctl reload nginx; then
  echo "[ERROR] Nginx reload failed after updating Cloudflare Real IP config; rolling back." >&2

  if [[ "${HAD_OLD}" == true ]]; then
    install -m 0644 "${BACKUP}" "${CONF}"
    nginx -t >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || true
  else
    rm -f "${CONF}"
    nginx -t >/dev/null 2>&1 || true
  fi

  exit 1
fi
EOF

  chmod +x "${script_path}"

  cat > /etc/systemd/system/update-cloudflare-real-ip.service <<'EOF'
[Unit]
Description=Update Cloudflare real IP ranges for Nginx
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-cloudflare-real-ip
EOF

  cat > /etc/systemd/system/update-cloudflare-real-ip.timer <<'EOF'
[Unit]
Description=Daily update Cloudflare real IP ranges for Nginx

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now update-cloudflare-real-ip.timer
  "${script_path}"
}
