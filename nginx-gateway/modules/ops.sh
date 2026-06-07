#!/usr/bin/env bash

_ngw_pass() {
  echo "[PASS] $*"
}

_ngw_warn() {
  echo "[WARN] $*"
}

_ngw_fail() {
  echo "[FAIL] $*"
}

_ngw_section() {
  echo
  echo "== $* =="
}

nginx_ops_status() {
  _ngw_section "Nginx service"
  if command -v nginx >/dev/null 2>&1; then
    nginx -v 2>&1 || true
    nginx -t || true
  else
    _ngw_warn "nginx command not found"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl status nginx --no-pager || true
  else
    _ngw_warn "systemctl command not found"
  fi

  _ngw_section "Listening ports"
  if command -v ss >/dev/null 2>&1; then
    ss -lntup | grep -E ':(80|443)\b|nginx' || true
  else
    _ngw_warn "ss command not found"
  fi

  _ngw_section "HTTP configs"
  nginx_ops_list_http || true

  _ngw_section "Stream configs"
  nginx_ops_list_stream || true

  _ngw_section "Certificates"
  if command -v certbot >/dev/null 2>&1; then
    certbot certificates || true
  else
    _ngw_warn "certbot command not found"
  fi

  _ngw_section "Timers"
  nginx_ops_timers || true
}

nginx_ops_doctor() {
  local failed=0

  _ngw_section "Nginx"
  if command -v nginx >/dev/null 2>&1; then
    _ngw_pass "nginx command exists"
  else
    _ngw_fail "nginx command not found"
    failed=1
  fi

  if nginx -t >/dev/null 2>&1; then
    _ngw_pass "nginx -t passed"
  else
    _ngw_fail "nginx -t failed"
    failed=1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx; then
      _ngw_pass "nginx service is active"
    else
      _ngw_fail "nginx service is not active"
      failed=1
    fi
  else
    _ngw_warn "systemctl command not found"
  fi

  _ngw_section "Config includes"
  if nginx -T 2>/dev/null | grep -Fq 'include /etc/nginx/http.d/*.conf;'; then
    _ngw_pass "http.d include exists"
  else
    _ngw_warn "http.d include not found in nginx -T output"
  fi

  if nginx -T 2>/dev/null | grep -Fq 'include /etc/nginx/stream.d/*.conf;'; then
    _ngw_pass "stream.d include exists"
  else
    _ngw_warn "stream.d include not found in nginx -T output"
  fi

  _ngw_section "Certificates"
  if command -v certbot >/dev/null 2>&1; then
    _ngw_pass "certbot command exists"
    certbot certificates >/dev/null 2>&1 || _ngw_warn "certbot certificates returned non-zero"
  else
    _ngw_warn "certbot command not found; cert-cf may not have been run"
  fi

  if [[ -d /etc/letsencrypt/cloudflare ]]; then
    _ngw_pass "Cloudflare credential directory exists"
    find /etc/letsencrypt/cloudflare -maxdepth 1 -type f -name '*.ini' -print -exec stat -c '  mode=%a owner=%U group=%G' {} \; 2>/dev/null || true
  else
    _ngw_warn "Cloudflare credential directory not found"
  fi

  _ngw_section "Cloudflare Real IP"
  if [[ -f /etc/nginx/http.d/00-cloudflare-real-ip.conf ]]; then
    _ngw_pass "Cloudflare Real IP config exists"
  else
    _ngw_warn "Cloudflare Real IP config not found"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled --quiet update-cloudflare-real-ip.timer 2>/dev/null; then
      _ngw_pass "update-cloudflare-real-ip.timer is enabled"
    else
      _ngw_warn "update-cloudflare-real-ip.timer is not enabled"
    fi
  fi

  return "${failed}"
}

nginx_ops_list() {
  _ngw_section "HTTP sites"
  nginx_ops_list_http

  _ngw_section "Stream proxies"
  nginx_ops_list_stream
}

nginx_ops_list_http() {
  local files=()
  local file

  shopt -s nullglob
  files=(/etc/nginx/http.d/*.conf)
  shopt -u nullglob

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "No HTTP configs found under /etc/nginx/http.d"
    return 0
  fi

  for file in "${files[@]}"; do
    echo "- $(basename "${file}")"
    echo "  path: ${file}"
    grep -E '^\s*(server_name|listen|proxy_pass|root|ssl_certificate)\b' "${file}" | sed 's/^/  /' || true
  done
}

nginx_ops_list_stream() {
  local files=()
  local file

  shopt -s nullglob
  files=(/etc/nginx/stream.d/*.conf)
  shopt -u nullglob

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "No stream configs found under /etc/nginx/stream.d"
    return 0
  fi

  for file in "${files[@]}"; do
    echo "- $(basename "${file}")"
    echo "  path: ${file}"
    grep -E '^\s*(listen|proxy_pass|server|ssl_preread|map)\b' "${file}" | sed 's/^/  /' || true
  done
}

nginx_ops_show() {
  local domain=""
  local name=""
  local path=""
  local safe_name=""
  local files=()
  local file

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        domain="${2:-}"
        shift 2
        ;;
      --name)
        name="${2:-}"
        shift 2
        ;;
      --path)
        path="${2:-}"
        shift 2
        ;;
      *)
        die "Unknown show option: $1"
        ;;
    esac
  done

  if [[ -n "${path}" ]]; then
    validate_abs_path "${path}"
    [[ -f "${path}" ]] || die "Config file not found: ${path}"
    cat "${path}"
    return 0
  fi

  if [[ -n "${domain}" ]]; then
    validate_domain "${domain}"
    path="/etc/nginx/http.d/${domain}.conf"
    [[ -f "${path}" ]] || die "HTTP config not found: ${path}"
    cat "${path}"
    return 0
  fi

  if [[ -n "${name}" ]]; then
    safe_name="$(sanitize_nginx_name "${name}")"
    shopt -s nullglob
    files=(/etc/nginx/stream.d/"${safe_name}".*.conf)
    shopt -u nullglob

    [[ "${#files[@]}" -gt 0 ]] || die "Stream config not found for name: ${name}"

    for file in "${files[@]}"; do
      echo "# ${file}"
      cat "${file}"
      echo
    done
    return 0
  fi

  die "show requires --domain, --name, or --path"
}

nginx_ops_logs() {
  local domain=""
  local stream=false
  local journal=false
  local type="access"
  local lines="100"
  local follow=false
  local file=""
  local tail_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        domain="${2:-}"
        shift 2
        ;;
      --stream)
        stream=true
        shift
        ;;
      --journal)
        journal=true
        shift
        ;;
      --type)
        type="${2:-access}"
        shift 2
        ;;
      --lines)
        lines="${2:-100}"
        shift 2
        ;;
      --follow|-f)
        follow=true
        shift
        ;;
      *)
        die "Unknown logs option: $1"
        ;;
    esac
  done

  [[ "${type}" == "access" || "${type}" == "error" ]] || die "--type must be access or error"
  [[ "${lines}" =~ ^[0-9]+$ ]] || die "--lines must be a number"

  if [[ "${journal}" == true ]]; then
    if [[ "${follow}" == true ]]; then
      journalctl -u nginx -n "${lines}" -f
    else
      journalctl -u nginx -n "${lines}" --no-pager
    fi
    return 0
  fi

  if [[ "${stream}" == true ]]; then
    file="/var/log/nginx/stream.${type}.log"
  elif [[ -n "${domain}" ]]; then
    validate_domain "${domain}"
    file="/var/log/nginx/${domain}.${type}.log"
  else
    die "logs requires --domain, --stream, or --journal"
  fi

  [[ -f "${file}" ]] || die "Log file not found: ${file}"

  tail_args=(-n "${lines}")
  if [[ "${follow}" == true ]]; then
    tail_args+=(-f)
  fi

  tail "${tail_args[@]}" "${file}"
}

nginx_ops_cert_status() {
  _ngw_section "Certbot certificates"
  if command -v certbot >/dev/null 2>&1; then
    certbot certificates || true
  else
    _ngw_warn "certbot command not found"
  fi

  _ngw_section "Renewal configs"
  if [[ -d /etc/letsencrypt/renewal ]]; then
    find /etc/letsencrypt/renewal -maxdepth 1 -type f -name '*.conf' -print | sort
  else
    _ngw_warn "/etc/letsencrypt/renewal not found"
  fi

  _ngw_section "Cloudflare credential files"
  if [[ -d /etc/letsencrypt/cloudflare ]]; then
    find /etc/letsencrypt/cloudflare -maxdepth 1 -type f -name '*.ini' -exec stat -c '%a %U:%G %n' {} \; | sort
  else
    _ngw_warn "/etc/letsencrypt/cloudflare not found"
  fi
}

nginx_ops_renew_check() {
  require_root
  require_cmd certbot
  certbot renew --dry-run
}

nginx_ops_timers() {
  if ! command -v systemctl >/dev/null 2>&1; then
    _ngw_warn "systemctl command not found"
    return 0
  fi

  systemctl list-timers --all | grep -E 'certbot|snap.certbot|update-cloudflare-real-ip' || true
  echo
  systemctl status update-cloudflare-real-ip.timer --no-pager 2>/dev/null || true
}

nginx_ops_remove_http_site() {
  require_root

  local domain=""
  local path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        domain="${2:-}"
        shift 2
        ;;
      *)
        die "Unknown remove-http-site option: $1"
        ;;
    esac
  done

  [[ -n "${domain}" ]] || die "--domain is required"
  validate_domain "${domain}"
  path="/etc/nginx/http.d/${domain}.conf"

  nginx_ops_remove_config "${path}"
}

nginx_ops_remove_stream() {
  require_root

  local name=""
  local type=""
  local safe_name=""
  local files=()
  local path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        name="${2:-}"
        shift 2
        ;;
      --type)
        type="${2:-}"
        shift 2
        ;;
      *)
        die "Unknown remove-stream option: $1"
        ;;
    esac
  done

  [[ -n "${name}" ]] || die "--name is required"
  safe_name="$(sanitize_nginx_name "${name}")"

  case "${type}" in
    "")
      shopt -s nullglob
      files=(/etc/nginx/stream.d/"${safe_name}".*.conf)
      shopt -u nullglob
      ;;
    tcp)
      files=("/etc/nginx/stream.d/${safe_name}.tcp.conf")
      ;;
    udp)
      files=("/etc/nginx/stream.d/${safe_name}.udp.conf")
      ;;
    tls-pass)
      files=("/etc/nginx/stream.d/${safe_name}.tls-passthrough.conf")
      ;;
    *)
      die "--type must be tcp, udp, tls-pass, or omitted"
      ;;
  esac

  [[ "${#files[@]}" -gt 0 ]] || die "No stream config found for name: ${name}"

  for path in "${files[@]}"; do
    [[ -f "${path}" ]] || die "Config file not found: ${path}"
  done

  for path in "${files[@]}"; do
    nginx_ops_remove_config "${path}"
  done
}

nginx_ops_remove_config() {
  local path="$1"
  local backup=""

  validate_abs_path "${path}"
  [[ -f "${path}" ]] || die "Config file not found: ${path}"

  backup="${path}.bak.$(date +%Y%m%d%H%M%S).$$"
  cp -a "${path}" "${backup}"
  rm -f "${path}"

  if ! nginx_test; then
    warn "nginx -t failed after removing ${path}; restoring backup."
    install -m 0644 "${backup}" "${path}"
    nginx_test >/dev/null 2>&1 || true
    die "Remove rejected because resulting Nginx config is invalid: ${path}"
  fi

  if ! systemctl reload nginx; then
    warn "Nginx reload failed after removing ${path}; restoring backup."
    install -m 0644 "${backup}" "${path}"
    nginx_test >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || true
    die "Remove rejected because Nginx reload failed: ${path}"
  fi

  echo "Removed: ${path}"
  echo "Backup:  ${backup}"
}
