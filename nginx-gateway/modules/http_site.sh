#!/usr/bin/env bash

nginx_http_site_create() {
  require_root

  local domain=""
  local cert_name=""
  local upstream=""
  local web_root=""

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
      *)
        die "Unknown http-site option: $1"
        ;;
    esac
  done

  [[ -n "${domain}" ]] || die "--domain is required"
  [[ -n "${cert_name}" ]] || cert_name="${domain}"

  local conf="/etc/nginx/http.d/${domain}.conf"

  if [[ -z "${web_root}" ]]; then
    web_root="/var/www/${domain}/html"
  fi

  mkdir -p "${web_root}"

  if [[ ! -f "${web_root}/index.html" ]]; then
    printf '<h1>%s is running.</h1>\n' "${domain}" > "${web_root}/index.html"
  fi

  log "Creating HTTP site config: ${conf}"

  {
    echo 'server {'
    echo '    listen 80;'
    echo '    listen [::]:80;'
    echo "    server_name ${domain};"
    echo '    return 301 https://$host$request_uri;'
    echo '}'
    echo
    echo 'server {'
    echo '    listen 443 ssl;'
    echo '    listen [::]:443 ssl;'
    echo '    http2 on;'
    echo
    echo "    server_name ${domain};"
    echo
    echo "    ssl_certificate     /etc/letsencrypt/live/${cert_name}/fullchain.pem;"
    echo "    ssl_certificate_key /etc/letsencrypt/live/${cert_name}/privkey.pem;"
    echo '    ssl_protocols TLSv1.2 TLSv1.3;'
    echo

    if [[ -n "${upstream}" ]]; then
      echo '    location / {'
      echo "        proxy_pass ${upstream};"
      echo '        proxy_http_version 1.1;'
      echo '        proxy_set_header Host $host;'
      echo '        proxy_set_header X-Real-IP $remote_addr;'
      echo '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
      echo '        proxy_set_header X-Forwarded-Proto $scheme;'
      echo '    }'
    else
      echo "    root ${web_root};"
      echo '    index index.html index.htm;'
      echo
      echo '    location / {'
      echo '        try_files $uri $uri/ =404;'
      echo '    }'
    fi

    echo
    echo "    access_log /var/log/nginx/${domain}.access.log;"
    echo "    error_log  /var/log/nginx/${domain}.error.log warn;"
    echo '}'
  } > "${conf}"

  reload_nginx
}
