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

reload_nginx() {
  nginx -t
  systemctl reload nginx
}

backup_file() {
  local file="$1"

  if [[ -f "${file}" ]]; then
    cp -a "${file}" "${file}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

sanitize_nginx_name() {
  local raw="$1"
  local safe

  safe="$(echo "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/_/g; s/^_+//; s/_+$//')"

  [[ -n "${safe}" ]] || die "Invalid name after sanitization: ${raw}"

  if [[ ! "${safe}" =~ ^[a-zA-Z_] ]]; then
    safe="svc_${safe}"
  fi

  echo "${safe}"
}

validate_host_port() {
  local value="$1"
  [[ "${value}" =~ ^[^:[:space:]]+:[0-9]+$ ]] || die "Invalid backend format: ${value}. Expected host:port."
}

validate_port() {
  local port="$1"

  [[ "${port}" =~ ^[0-9]+$ ]] || die "Invalid port: ${port}"
  (( port >= 1 && port <= 65535 )) || die "Port out of range: ${port}"
}
