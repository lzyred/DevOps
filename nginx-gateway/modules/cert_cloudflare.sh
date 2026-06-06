#!/usr/bin/env bash

cert_cloudflare_issue() {
  require_root

  local domain=""
  local email=""
  local wildcard="false"
  local propagation_seconds="60"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        domain="${2:-}"
        shift 2
        ;;
      --email)
        email="${2:-}"
        shift 2
        ;;
      --wildcard)
        wildcard="true"
        shift
        ;;
      --propagation-seconds)
        propagation_seconds="${2:-60}"
        shift 2
        ;;
      *)
        die "Unknown cert-cf option: $1"
        ;;
    esac
  done

  [[ -n "${domain}" ]] || die "--domain is required"
  [[ -n "${email}" ]] || die "--email is required"

  validate_domain "${domain}"
  validate_email "${email}"
  validate_port "${propagation_seconds}"

  cert_cloudflare_install_dependencies
  cert_cloudflare_prepare_credentials "${domain}"
  cert_cloudflare_run_certbot "${domain}" "${email}" "${wildcard}" "${propagation_seconds}"
  cert_cloudflare_install_renewal_hook

  log "Certificate issued:"
  openssl x509 \
    -in "/etc/letsencrypt/live/${domain}/fullchain.pem" \
    -noout \
    -issuer \
    -subject \
    -dates
}

cert_cloudflare_install_dependencies() {
  log "Installing Certbot and Cloudflare plugin..."

  if ! command -v snap >/dev/null 2>&1; then
    apt-get update
    apt-get install -y snapd
  fi

  systemctl enable --now snapd.socket

  if ! snap list core >/dev/null 2>&1; then
    snap install core
  else
    snap refresh core || true
  fi

  if ! snap list certbot >/dev/null 2>&1; then
    snap install --classic certbot
  else
    snap refresh certbot || true
  fi

  ln -sf /snap/bin/certbot /usr/local/bin/certbot
  snap set certbot trust-plugin-with-root=ok

  if ! snap list certbot-dns-cloudflare >/dev/null 2>&1; then
    snap install certbot-dns-cloudflare
  else
    snap refresh certbot-dns-cloudflare || true
  fi
}

cert_cloudflare_prepare_credentials() {
  local domain="$1"
  local cred_file="/etc/letsencrypt/cloudflare/${domain}.ini"

  log "Preparing Cloudflare credential file..."
  install -d -m 0700 /etc/letsencrypt/cloudflare

  if [[ ! -f "${cred_file}" ]]; then
    local token="${CF_API_TOKEN:-}"

    if [[ -z "${token}" ]]; then
      read -r -s -p "Enter Cloudflare API Token: " token
      echo
    fi

    [[ -n "${token}" ]] || die "Cloudflare API Token is empty"

    umask 077
    printf 'dns_cloudflare_api_token = %s\n' "${token}" > "${cred_file}"
    chmod 600 "${cred_file}"
  else
    chmod 600 "${cred_file}"
    log "Using existing credential file: ${cred_file}"
  fi
}

cert_cloudflare_run_certbot() {
  local domain="$1"
  local email="$2"
  local wildcard="$3"
  local propagation_seconds="$4"
  local cred_file="/etc/letsencrypt/cloudflare/${domain}.ini"
  local domain_args=()

  if [[ "${wildcard}" == "true" ]]; then
    domain_args=(-d "${domain}" -d "*.${domain}")
  else
    domain_args=(-d "${domain}" -d "www.${domain}")
  fi

  log "Issuing certificate..."
  certbot certonly \
    --non-interactive \
    --agree-tos \
    --no-eff-email \
    --email "${email}" \
    --cert-name "${domain}" \
    --dns-cloudflare \
    --dns-cloudflare-credentials "${cred_file}" \
    --dns-cloudflare-propagation-seconds "${propagation_seconds}" \
    --keep-until-expiring \
    --expand \
    "${domain_args[@]}"
}

cert_cloudflare_install_renewal_hook() {
  log "Installing renewal hook..."
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy

  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
set -e
nginx -t
systemctl reload nginx
EOF

  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
}
