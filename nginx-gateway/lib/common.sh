#!/usr/bin/env bash

log() {
  echo -e "\n[INFO] $*"
}

warn() {
  echo -e "\n[WARN] $*" >&2
}

die() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

backup_file() {
  local file="$1"

  if [[ -f "${file}" ]]; then
    cp -a "${file}" "${file}.bak.$(date +%Y%m%d%H%M%S).$$"
  fi
}

nginx_test() {
  nginx -t
}

reload_nginx() {
  nginx_test
  systemctl reload nginx
}

safe_apply_nginx_conf() {
  local dest="$1"
  local dest_dir
  local tmp
  local backup=""
  local had_old=false

  [[ -n "${dest}" ]] || die "safe_apply_nginx_conf requires destination path"
  validate_abs_path "${dest}"

  dest_dir="$(dirname "${dest}")"
  mkdir -p "${dest_dir}"

  tmp="$(mktemp /tmp/nginx-gateway-conf.XXXXXX)"
  cat > "${tmp}"
  chmod 0644 "${tmp}"

  if [[ -f "${dest}" ]]; then
    had_old=true
    backup="${dest}.bak.$(date +%Y%m%d%H%M%S).$$"
    cp -a "${dest}" "${backup}"
  fi

  install -m 0644 "${tmp}" "${dest}"

  if ! nginx_test; then
    warn "nginx -t failed after writing ${dest}; rolling back to previous config."

    if [[ "${had_old}" == true ]]; then
      install -m 0644 "${backup}" "${dest}"
    else
      rm -f "${dest}"
    fi

    rm -f "${tmp}"
    nginx_test >/dev/null 2>&1 || true
    die "Rejected invalid Nginx config: ${dest}"
  fi

  if ! systemctl reload nginx; then
    warn "Nginx reload failed after writing ${dest}; rolling back to previous config."

    if [[ "${had_old}" == true ]]; then
      install -m 0644 "${backup}" "${dest}"
      nginx_test >/dev/null 2>&1 || true
      systemctl reload nginx >/dev/null 2>&1 || true
    else
      rm -f "${dest}"
      nginx_test >/dev/null 2>&1 || true
    fi

    rm -f "${tmp}"
    die "Rejected config because Nginx reload failed: ${dest}"
  fi

  rm -f "${tmp}"
}

sanitize_nginx_name() {
  local raw="$1"
  local safe

  safe="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/_/g; s/^_+//; s/_+$//')"

  [[ -n "${safe}" ]] || die "Invalid name after sanitization: ${raw}"

  if [[ ! "${safe}" =~ ^[a-zA-Z_] ]]; then
    safe="svc_${safe}"
  fi

  echo "${safe}"
}

reject_nginx_injection_chars() {
  local value="$1"
  local label="${2:-value}"

  case "${value}" in
    *$'\n'*|*$'\r'*|*';'*|*'{'*|*'}'*|*'`'*)
      die "Invalid ${label}: contains forbidden Nginx control characters"
      ;;
  esac
}

validate_domain() {
  local value="$1"
  reject_nginx_injection_chars "${value}" "domain"
  [[ "${value}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Invalid domain: ${value}"
}

validate_sni() {
  local value="$1"
  validate_domain "${value}"
}

validate_email() {
  local value="$1"
  reject_nginx_injection_chars "${value}" "email"
  [[ "${value}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Invalid email: ${value}"
}

validate_url() {
  local value="$1"
  reject_nginx_injection_chars "${value}" "URL"
  [[ "${value}" =~ ^https?://[^[:space:]]+$ ]] || die "Invalid URL: ${value}. Only http:// and https:// upstream URLs are supported."
}

validate_abs_path() {
  local value="$1"
  reject_nginx_injection_chars "${value}" "path"
  [[ "${value}" == /* ]] || die "Path must be absolute: ${value}"
  [[ ! "${value}" =~ [[:space:]] ]] || die "Path must not contain whitespace: ${value}"
}

validate_size() {
  local value="$1"
  reject_nginx_injection_chars "${value}" "size"
  [[ "${value}" =~ ^(0|[1-9][0-9]*[kKmMgG]?)$ ]] || die "Invalid size value: ${value}"
}

validate_port() {
  local port="$1"

  [[ "${port}" =~ ^[0-9]+$ ]] || die "Invalid port: ${port}"
  (( port >= 1 && port <= 65535 )) || die "Port out of range: ${port}"
}

validate_host_port() {
  local value="$1"
  local port=""

  reject_nginx_injection_chars "${value}" "host:port"

  if [[ "${value}" =~ ^\[[0-9A-Fa-f:.]+\]:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  elif [[ "${value}" =~ ^[A-Za-z0-9._-]+:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  else
    die "Invalid backend format: ${value}. Expected host:port or [ipv6]:port."
  fi

  validate_port "${port}"
}
