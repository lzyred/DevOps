#!/usr/bin/env bash

nginx_cf_real_ip_install() {
  require_root

  local script_path="/usr/local/sbin/update-cloudflare-real-ip"

  log "Installing Cloudflare Real IP updater..."

  cat > "${script_path}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONF="/etc/nginx/http.d/00-cloudflare-real-ip.conf"
TMP="$(mktemp /tmp/cloudflare-real-ip.XXXXXX)"

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

install -m 0644 "${TMP}" "${CONF}"
rm -f "${TMP}"

nginx -t
systemctl reload nginx
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
