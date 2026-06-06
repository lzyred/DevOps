#!/usr/bin/env bash

nginx_http_site_create() {
  require_root

  local domain=""
  local cert_name=""
  local upstream=""
  local web_root=""
  local client_max_body_size="50m"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        domain="${2:-}"
        shift 2
        ;;
      --cert-name)
        cert_name="${2:-}"
        shift 2
        ;;
      --upstream)
        upstream="${2:-}"
        shift 2
        ;;
      --web-root)
        web_root="${2:-}"
        shift 2
        ;;
      --client-max-body-size)
        client_max_body_size="${2:-50m}"
        shift 2
        ;;
      *)
        die "Unknown http-site option: $1"
        ;;
    esac
  done

  [[ -n "${domain}" ]] || die "--domain is required"
  [[ -n "${cert_name}" ]] || cert_name="${domain}"

  validate_domain "${domain}"
  validate_domain "${cert_name}"
  reject_nginx_injection_chars "${client_max_body_size}" "client_max_body_size"

  if [[ -n "${upstream}" ]]; then
    validate_url "${upstream}"
  fi

  if [[ -z "${web_root}" ]]; then
    web_root="/var/www/${domain}/html"
  fi

  validate_abs_path "${web_root}"

  local conf="/etc/nginx/http.d/${domain}.conf"

  mkdir -p "${web_root}"

  if [[ ! -f "${web_root}/index.html" ]]; then
    printf '<h1>%s is running.</h1>\n' "${domain}" > "${web_root}/index.html"
  fi

  log "Creating HTTP site config: ${conf}"

  if [[ -n "${upstream}" ]]; then
    nginx_http_render_reverse_proxy "${domain}" "${cert_name}" "${upstream}" "${client_max_body_size}" | safe_apply_nginx_conf "${conf}"
  else
    nginx_http_render_static_site "${domain}" "${cert_name}" "${web_root}" "${client_max_body_size}" | safe_apply_nginx_conf "${conf}"
  fi
}

nginx_http_render_common_header() {
  local domain="$1"
  local cert_name="$2"
  local client_max_body_size="$3"

  cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${cert_name}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${cert_name}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    client_max_body_size ${client_max_body_size};
EOF
}

nginx_http_render_reverse_proxy() {
  local domain="$1"
  local cert_name="$2"
  local upstream="$3"
  local client_max_body_size="$4"

  nginx_http_render_common_header "${domain}" "${cert_name}" "${client_max_body_size}"

  cat <<EOF

    location / {
        proxy_pass ${upstream};
        proxy_http_version 1.1;

        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log warn;
}
EOF
}

nginx_http_render_static_site() {
  local domain="$1"
  local cert_name="$2"
  local web_root="$3"
  local client_max_body_size="$4"

  nginx_http_render_common_header "${domain}" "${cert_name}" "${client_max_body_size}"

  cat <<EOF

    root ${web_root};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log warn;
}
EOF
}
