#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${BASE_DIR}/lib/common.sh"
# shellcheck source=modules/core_nginx.sh
source "${BASE_DIR}/modules/core_nginx.sh"
# shellcheck source=modules/cert_cloudflare.sh
source "${BASE_DIR}/modules/cert_cloudflare.sh"
# shellcheck source=modules/cf_real_ip.sh
source "${BASE_DIR}/modules/cf_real_ip.sh"
# shellcheck source=modules/http_site.sh
source "${BASE_DIR}/modules/http_site.sh"
# shellcheck source=modules/stream_proxy.sh
source "${BASE_DIR}/modules/stream_proxy.sh"

usage() {
  cat <<'EOF'
Usage:
  sudo ./gateway.sh <command> [options]

Commands:
  core                    Install and initialize Nginx gateway
  cert-cf                 Issue Let's Encrypt certificate through Cloudflare DNS
  cf-real-ip              Install or refresh Cloudflare Real IP config
  http-site               Create HTTP/HTTPS L7 site or reverse proxy
  stream-tcp              Create L4 TCP proxy
  stream-udp              Create L4 UDP proxy
  stream-tls-pass         Create TLS passthrough SNI router
  test                    Run nginx -t
  reload                  Run nginx -t and reload nginx

Examples:
  sudo ./gateway.sh core

  sudo ./gateway.sh cert-cf --domain example.com --email admin@example.com --wildcard

  sudo ./gateway.sh cf-real-ip

  sudo ./gateway.sh http-site \
    --domain app.example.com \
    --cert-name example.com \
    --upstream http://127.0.0.1:8080

  sudo ./gateway.sh stream-tcp \
    --name mysql-prod \
    --listen 33060 \
    --backend 10.10.10.20:3306

  sudo ./gateway.sh stream-tls-pass \
    --name tls-router \
    --listen 443 \
    --default-backend 10.10.10.10:443 \
    --map git.example.com=10.10.10.21:443,registry.example.com=10.10.10.22:443
EOF
}

cmd="${1:-help}"
shift || true

case "${cmd}" in
  core)
    nginx_core_install "$@"
    ;;
  cert-cf)
    cert_cloudflare_issue "$@"
    ;;
  cf-real-ip)
    nginx_cf_real_ip_install "$@"
    ;;
  http-site)
    nginx_http_site_create "$@"
    ;;
  stream-tcp)
    nginx_stream_tcp_create "$@"
    ;;
  stream-udp)
    nginx_stream_udp_create "$@"
    ;;
  stream-tls-pass)
    nginx_stream_tls_passthrough_create "$@"
    ;;
  test)
    nginx -t
    ;;
  reload)
    nginx -t
    systemctl reload nginx
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    die "Unknown command: ${cmd}"
    ;;
esac
