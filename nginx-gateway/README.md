# Nginx Gateway Bootstrap

A modular Debian 12 bootstrap toolkit for running Nginx as a small gateway.

It separates gateway concerns into independent modules:

- **Core**: install official Nginx and initialize standard config directories.
- **TLS**: issue Let's Encrypt certificates through Cloudflare DNS API.
- **HTTP/L7**: create static HTTPS sites or HTTP reverse proxy sites.
- **Stream/L4**: create TCP, UDP, and TLS passthrough proxies through Nginx `stream`.

The design goal is to avoid coupling Nginx installation with only one web-site scenario. HTTP reverse proxy and L4 stream proxy are different modules.

## Directory layout

```text
nginx-gateway/
├── gateway.sh
├── lib/
│   └── common.sh
├── modules/
│   ├── core_nginx.sh
│   ├── cert_cloudflare.sh
│   ├── http_site.sh
│   └── stream_proxy.sh
└── examples/
    ├── http-reverse-proxy.example
    ├── stream-tcp.example
    └── stream-tls-passthrough.example
```

## Requirements

- Debian 12 bookworm
- root privilege
- DNS hosted on Cloudflare if using the certificate module
- Cloudflare API Token with minimum permissions:
  - `Zone / DNS / Edit`
  - `Zone / Zone / Read`

## Install core Nginx gateway

```bash
cd nginx-gateway
chmod +x gateway.sh
sudo ./gateway.sh core
```

This installs the official Nginx mainline package and initializes:

```text
/etc/nginx/http.d/
/etc/nginx/stream.d/
```

HTTP virtual hosts are placed under `/etc/nginx/http.d/`.

L4 stream proxy configs are placed under `/etc/nginx/stream.d/`.

## Issue Let's Encrypt certificate through Cloudflare

Wildcard certificate:

```bash
sudo ./gateway.sh cert-cf \
  --domain example.com \
  --email admin@example.com \
  --wildcard
```

The script prompts for the Cloudflare API Token securely if `--cf-token` is not provided.

Using environment variable:

```bash
CF_API_TOKEN="xxx" sudo -E ./gateway.sh cert-cf \
  --domain example.com \
  --email admin@example.com \
  --wildcard
```

Certificate output:

```text
/etc/letsencrypt/live/example.com/fullchain.pem
/etc/letsencrypt/live/example.com/privkey.pem
```

## Create HTTP reverse proxy site

```bash
sudo ./gateway.sh http-site \
  --domain app.example.com \
  --cert-name example.com \
  --upstream http://127.0.0.1:8080
```

Effect:

```text
client -> Nginx HTTPS 443 -> backend http://127.0.0.1:8080
```

## Create static HTTPS site

```bash
sudo ./gateway.sh http-site \
  --domain www.example.com \
  --cert-name example.com \
  --web-root /var/www/www.example.com/html
```

## Create TCP L4 proxy

```bash
sudo ./gateway.sh stream-tcp \
  --name mysql-prod \
  --listen 33060 \
  --backend 10.10.10.20:3306
```

Effect:

```text
client -> Nginx:33060 -> 10.10.10.20:3306
```

Suitable for MySQL, PostgreSQL, Redis, SSH, MQTT, and custom TCP services.

## Create UDP L4 proxy

```bash
sudo ./gateway.sh stream-udp \
  --name dns-proxy \
  --listen 5353 \
  --backend 10.10.10.53:53
```

Effect:

```text
client -> Nginx:5353/udp -> 10.10.10.53:53/udp
```

## Create TLS passthrough SNI router

```bash
sudo ./gateway.sh stream-tls-pass \
  --name tls-router \
  --listen 443 \
  --default-backend 10.10.10.10:443 \
  --map git.example.com=10.10.10.21:443,registry.example.com=10.10.10.22:443
```

Effect:

```text
git.example.com       -> Nginx:443 -> 10.10.10.21:443
registry.example.com  -> Nginx:443 -> 10.10.10.22:443
unknown SNI           -> Nginx:443 -> 10.10.10.10:443
```

In TLS passthrough mode:

- Nginx does not decrypt TLS.
- Nginx does not use the certificate.
- Backend services own their certificates.
- Nginx only routes traffic based on SNI.

## Important boundary: HTTP 443 and stream 443

The same IP and port cannot be owned by both HTTP and stream contexts at the same time:

```nginx
http {
    server { listen 443 ssl; }
}

stream {
    server { listen 443; }
}
```

Use one of these designs:

| Design | Description |
|---|---|
| Different public IPs | HTTP 443 and stream 443 are separated by IP. |
| Different ports | Web uses 443; L4 services use ports such as 33060 or 15432. |
| Stream owns 443 | Stream routes TLS passthrough by SNI to HTTPS backends. |

## Cloudflare boundary

Cloudflare normal orange-cloud proxy is mainly for HTTP/HTTPS traffic on Cloudflare-supported ports. It does not proxy arbitrary TCP/UDP services unless using Cloudflare Spectrum.

For raw TCP/UDP services:

- use `DNS only`, then clients connect directly to this Nginx gateway, or
- use Cloudflare Spectrum if you need Cloudflare to proxy TCP/UDP.

## Validate

```bash
sudo ./gateway.sh test
sudo ./gateway.sh reload
sudo certbot renew --dry-run
nginx -T | grep -E "http.d|stream.d|ssl_preread|proxy_pass"
```

## Production notes

- Use Cloudflare `Full (strict)` for HTTPS sites.
- Avoid Cloudflare `Flexible` mode.
- Keep Cloudflare API Token scoped to the specific zone.
- Do not expose database ports publicly unless there is a clear security control such as source IP allowlist, VPN, mTLS, or firewall rules.
