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

  {
    echo "upstream ${safe_name}_tcp_backend {"
    echo "    server ${backend};"
    echo "}"
    echo
    echo "server {"
    echo "    listen ${listen_port};"
    echo
    echo "    proxy_connect_timeout 5s;"
    echo "    proxy_timeout 1h;"
    echo
    echo "    proxy_pass ${safe_name}_tcp_backend;"
    echo "}"
  } > "${conf}"

  reload_nginx
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

  {
    echo "upstream ${safe_name}_udp_backend {"
    echo "    server ${backend};"
    echo "}"
    echo
    echo "server {"
    echo "    listen ${listen_port} udp;"
    echo
    echo "    proxy_timeout 30s;"
    echo "    proxy_responses 1;"
    echo
    echo "    proxy_pass ${safe_name}_udp_backend;"
    echo "}"
  } > "${conf}"

  reload_nginx
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

  {
    echo "map \$ssl_preread_server_name \$${safe_name}_backend {"
    echo "    default ${default_backend};"

    IFS=',' read -ra pairs <<< "${map_items}"
    for pair in "${pairs[@]}"; do
      local sni="${pair%%=*}"
      local target="${pair#*=}"

      [[ -n "${sni}" ]] || die "Invalid map item: ${pair}"
      [[ -n "${target}" ]] || die "Invalid map item: ${pair}"
      validate_host_port "${target}"

      echo "    ${sni} ${target};"
    done

    echo "}"
    echo
    echo "server {"
    echo "    listen ${listen_port};"
    echo
    echo "    ssl_preread on;"
    echo "    proxy_connect_timeout 5s;"
    echo "    proxy_timeout 1h;"
    echo
    echo "    proxy_pass \$${safe_name}_backend;"
    echo "}"
  } > "${conf}"

  reload_nginx
}
