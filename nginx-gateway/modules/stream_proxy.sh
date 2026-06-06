#!/usr/bin/env bash

nginx_stream_tcp_create() {
  require_root

  local name=""
  local listen_port=""
  local backend=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        name="${2:-}"
        shift 2
        ;;
      --listen)
        listen_port="${2:-}"
        shift 2
        ;;
      --backend)
        backend="${2:-}"
        shift 2
        ;;
      *)
        die "Unknown stream-tcp option: $1"
        ;;
    esac
  done

  [[ -n "${name}" ]] || die "--name is required"
  [[ -n "${listen_port}" ]] || die "--listen is required"
  [[ -n "${backend}" ]] || die "--backend is required"

  validate_port "${listen_port}"
  validate_host_port "${backend}"

  local safe_name
  safe_name="$(sanitize_nginx_name "${name}")"

  mkdir -p /etc/nginx/stream.d

  local conf="/etc/nginx/stream.d/${safe_name}.tcp.conf"

  log "Creating TCP stream proxy: 0.0.0.0:${listen_port} -> ${backend}"

  nginx_stream_render_tcp "${safe_name}" "${listen_port}" "${backend}" | safe_apply_nginx_conf "${conf}"
}

nginx_stream_udp_create() {
  require_root

  local name=""
  local listen_port=""
  local backend=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        name="${2:-}"
        shift 2
        ;;
      --listen)
        listen_port="${2:-}"
        shift 2
        ;;
      --backend)
        backend="${2:-}"
        shift 2
        ;;
      *)
        die "Unknown stream-udp option: $1"
        ;;
    esac
  done

  [[ -n "${name}" ]] || die "--name is required"
  [[ -n "${listen_port}" ]] || die "--listen is required"
  [[ -n "${backend}" ]] || die "--backend is required"

  validate_port "${listen_port}"
  validate_host_port "${backend}"

  local safe_name
  safe_name="$(sanitize_nginx_name "${name}")"

  mkdir -p /etc/nginx/stream.d

  local conf="/etc/nginx/stream.d/${safe_name}.udp.conf"

  log "Creating UDP stream proxy: 0.0.0.0:${listen_port}/udp -> ${backend}"

  nginx_stream_render_udp "${safe_name}" "${listen_port}" "${backend}" | safe_apply_nginx_conf "${conf}"
}

nginx_stream_tls_passthrough_create() {
  require_root

  local name=""
  local listen_port=""
  local default_backend=""
  local map_items=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        name="${2:-}"
        shift 2
        ;;
      --listen)
        listen_port="${2:-}"
        shift 2
        ;;
      --default-backend)
        default_backend="${2:-}"
        shift 2
        ;;
      --map)
        map_items="${2:-}"
        shift 2
        ;;
      *)
        die "Unknown stream-tls-pass option: $1"
        ;;
    esac
  done

  [[ -n "${name}" ]] || die "--name is required"
  [[ -n "${listen_port}" ]] || die "--listen is required"
  [[ -n "${default_backend}" ]] || die "--default-backend is required"
  [[ -n "${map_items}" ]] || die "--map is required"

  validate_port "${listen_port}"
  validate_host_port "${default_backend}"

  local safe_name
  safe_name="$(sanitize_nginx_name "${name}")"

  mkdir -p /etc/nginx/stream.d

  local conf="/etc/nginx/stream.d/${safe_name}.tls-passthrough.conf"

  log "Creating TLS passthrough SNI router on port ${listen_port}"

  nginx_stream_render_tls_passthrough "${safe_name}" "${listen_port}" "${default_backend}" "${map_items}" | safe_apply_nginx_conf "${conf}"
}

nginx_stream_render_tcp() {
  local safe_name="$1"
  local listen_port="$2"
  local backend="$3"

  cat <<EOF
upstream ${safe_name}_tcp_backend {
    server ${backend};
}

server {
    listen ${listen_port};

    proxy_connect_timeout 5s;
    proxy_timeout 1h;

    proxy_pass ${safe_name}_tcp_backend;
}
EOF
}

nginx_stream_render_udp() {
  local safe_name="$1"
  local listen_port="$2"
  local backend="$3"

  cat <<EOF
upstream ${safe_name}_udp_backend {
    server ${backend};
}

server {
    listen ${listen_port} udp;

    proxy_timeout 30s;
    proxy_responses 1;

    proxy_pass ${safe_name}_udp_backend;
}
EOF
}

nginx_stream_render_tls_passthrough() {
  local safe_name="$1"
  local listen_port="$2"
  local default_backend="$3"
  local map_items="$4"

  echo "map \$ssl_preread_server_name \$${safe_name}_backend {"
  echo "    default ${default_backend};"

  IFS=',' read -ra pairs <<< "${map_items}"
  for pair in "${pairs[@]}"; do
    local sni="${pair%%=*}"
    local target="${pair#*=}"

    [[ -n "${sni}" ]] || die "Invalid map item: ${pair}"
    [[ -n "${target}" ]] || die "Invalid map item: ${pair}"
    validate_sni "${sni}"
    validate_host_port "${target}"

    echo "    ${sni} ${target};"
  done

  cat <<EOF
}

server {
    listen ${listen_port};

    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;

    proxy_pass \$${safe_name}_backend;
}
EOF
}
