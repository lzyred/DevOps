# Nginx Gateway Bootstrap

A modular Debian 12 bootstrap toolkit for using Nginx as a lightweight gateway.

This directory is intentionally split by gateway responsibility instead of treating Nginx as only a web server:

- **Core**: install official Nginx and initialize standard config directories.
- **TLS**: issue Let's Encrypt certificates through Cloudflare DNS-01.
- **HTTP/L7**: create HTTPS static sites or HTTP reverse proxy sites.
- **Stream/L4**: create TCP, UDP, and TLS passthrough proxies through Nginx `stream`.
- **Cloudflare Real IP**: configure Nginx to restore the original visitor IP when traffic is behind Cloudflare.

> Current status: this is a maintained bootstrap script set, but it should still be validated on a clean Debian 12 test host before production use. Do not treat it as a fully tested ingress platform.

---

## 1. Repository layout

```text
nginx-gateway/
├── gateway.sh
├── lib/
│   └── common.sh
├── modules/
│   ├── cert_cloudflare.sh
│   ├── cf_real_ip.sh
│   ├── core_nginx.sh
│   ├── http_site.sh
│   └── stream_proxy.sh
└── examples/
    ├── http-reverse-proxy.example
    ├── stream-tcp.example
    └── stream-tls-passthrough.example
```

GitHub Actions workflow is stored at the repository root:

```text
.github/workflows/nginx-gateway-ci.yml
```

---

## 2. Requirements

| Item | Requirement |
|---|---|
| OS | Debian 12 bookworm |
| Privilege | root / sudo |
| Service manager | systemd-managed `nginx` service |
| DNS provider | Cloudflare, only required for certificate automation |
| Certificate method | Let's Encrypt DNS-01 through Cloudflare API |
| Nginx package | nginx.org official mainline package |
| HTTP configs | `/etc/nginx/http.d/*.conf` |
| L4 configs | `/etc/nginx/stream.d/*.conf` |

Always run `core` before other modules. `http-site`, `stream-*`, and `cf-real-ip` assume Nginx is already installed and the include directories have already been wired into `nginx.conf`.

---

## 3. Quick start

```bash
git clone https://github.com/lzyred/DevOps.git
cd DevOps/nginx-gateway
chmod +x gateway.sh

sudo ./gateway.sh core
sudo ./gateway.sh test
```

`core` installs Nginx, creates the config directories, and wires these includes into Nginx:

```text
/etc/nginx/http.d/*.conf
/etc/nginx/stream.d/*.conf
```

Recommended execution order:

```text
1. sudo ./gateway.sh core
2. sudo ./gateway.sh cf-real-ip        # only when traffic is behind Cloudflare
3. sudo ./gateway.sh cert-cf ...
4. sudo ./gateway.sh http-site ...     # for L7 HTTP/HTTPS traffic
5. sudo ./gateway.sh stream-tcp ...    # for L4 TCP traffic, if needed
6. sudo ./gateway.sh test
```

---

## 4. Cloudflare API Token guide

This project uses Cloudflare DNS API only for Let's Encrypt DNS-01 validation. It does **not** require a Cloudflare Global API Key.

DNS-01 validation creates and removes `_acme-challenge` TXT records in the target Cloudflare zone. An A record pointing to this server is not required for DNS-01 issuance, but the domain must already exist in the Cloudflare zone that the token can edit.

### 4.1 Create the token

Go to:

```text
Cloudflare Dashboard
→ My Profile
→ API Tokens
→ Create Token
```

Recommended template:

```text
Edit zone DNS
```

Recommended token name:

```text
letsencrypt-certbot-example.com
```

### 4.2 Required permissions

Minimum required permission for Certbot DNS-01:

```text
Zone / DNS / Edit
```

Recommended resource scope:

```text
Zone Resources:
  Include → Specific zone → example.com
```

Do **not** grant these for this use case:

```text
Global API Key
All zones
Account-wide permissions
Zone / Zone / Read
```

`Zone / Zone / Read` is not required for this Certbot Cloudflare DNS-01 workflow. The required capability is the ability to create and remove `_acme-challenge` TXT records in the target DNS zone.

### 4.3 Optional token restrictions

For better security, you can additionally configure:

```text
Client IP Address Filtering: your server public IP
TTL / expiration: according to your rotation policy
```

Avoid short TTL values if the token is expected to renew certificates automatically for a long time.

### 4.4 Save the token on the server

The script can prompt for the token automatically, but the final credential file should be:

```text
/etc/letsencrypt/cloudflare/example.com.ini
```

Expected file content:

```ini
dns_cloudflare_api_token = <YOUR_CLOUDFLARE_API_TOKEN>
```

Required permission:

```bash
sudo chmod 600 /etc/letsencrypt/cloudflare/example.com.ini
```

Do not delete this credential file after certificate issuance. Certbot renewal uses the same credential file path stored in the renewal configuration.

The script intentionally does **not** support `--cf-token` as a command-line argument, because command-line secrets can leak through shell history and process inspection.

### 4.5 Verify token validity

You can verify whether the token itself is active:

```bash
curl "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  --header "Authorization: Bearer <YOUR_CLOUDFLARE_API_TOKEN>"
```

Expected result should include:

```json
{
  "success": true,
  "result": {
    "status": "active"
  }
}
```

An active token only proves that the token exists and is valid. It does **not** prove that the token has permission to edit the target zone. The real permission test is whether Certbot can create the `_acme-challenge` TXT record during issuance or renewal.

---

## 5. Issue Let's Encrypt certificate through Cloudflare

Wildcard certificate:

```bash
sudo ./gateway.sh cert-cf \
  --domain example.com \
  --email admin@example.com \
  --wildcard
```

Non-wildcard certificate:

```bash
sudo ./gateway.sh cert-cf \
  --domain example.com \
  --email admin@example.com
```

With environment variable:

```bash
CF_API_TOKEN="<YOUR_CLOUDFLARE_API_TOKEN>" sudo -E ./gateway.sh cert-cf \
  --domain example.com \
  --email admin@example.com \
  --wildcard
```

Certificate output:

```text
/etc/letsencrypt/live/example.com/fullchain.pem
/etc/letsencrypt/live/example.com/privkey.pem
```

Wildcard coverage:

```text
*.example.com covers app.example.com
*.example.com does not cover a.b.example.com
```

Test renewal:

```bash
sudo certbot renew --dry-run
```

---

## 6. Cloudflare SSL/TLS mode

For Cloudflare-proxied HTTPS sites, use:

```text
Cloudflare Dashboard
→ SSL/TLS
→ Overview
→ Full (strict)
```

Avoid:

```text
Flexible
```

Reason: `Flexible` encrypts browser-to-Cloudflare only. `Full (strict)` validates the source server certificate and keeps the Cloudflare-to-origin connection encrypted.

---

## 7. Configure Cloudflare Real IP

When Cloudflare proxy is enabled, Nginx normally sees Cloudflare edge IPs. To log the original visitor IP:

```bash
sudo ./gateway.sh cf-real-ip
```

This creates:

```text
/etc/nginx/http.d/00-cloudflare-real-ip.conf
/usr/local/sbin/update-cloudflare-real-ip
/etc/systemd/system/update-cloudflare-real-ip.service
/etc/systemd/system/update-cloudflare-real-ip.timer
```

The timer refreshes Cloudflare IP ranges daily.

Validate:

```bash
nginx -T | grep -E "set_real_ip_from|CF-Connecting-IP|real_ip_recursive"
```

---

## 8. Create HTTP reverse proxy site

```bash
sudo ./gateway.sh http-site \
  --domain app.example.com \
  --cert-name example.com \
  --upstream http://127.0.0.1:8080
```

Effect:

```text
client → Nginx HTTPS 443 → backend http://127.0.0.1:8080
```

The generated config is stored at:

```text
/etc/nginx/http.d/app.example.com.conf
```

---

## 9. Create static HTTPS site

```bash
sudo ./gateway.sh http-site \
  --domain www.example.com \
  --cert-name example.com \
  --web-root /var/www/www.example.com/html
```

Effect:

```text
client → Nginx HTTPS 443 → static files
```

---

## 10. Create TCP L4 proxy

```bash
sudo ./gateway.sh stream-tcp \
  --name mysql-prod \
  --listen 33060 \
  --backend 10.10.10.20:3306
```

Effect:

```text
client → Nginx:33060 → 10.10.10.20:3306
```

Suitable examples:

```text
MySQL
PostgreSQL
Redis
SSH
MQTT
custom TCP services
```

Security note: do not expose database ports to the public Internet without source IP allowlist, VPN, mTLS, firewall policy, or another explicit access-control layer.

---

## 11. Create UDP L4 proxy

```bash
sudo ./gateway.sh stream-udp \
  --name dns-proxy \
  --listen 5353 \
  --backend 10.10.10.53:53
```

Effect:

```text
client → Nginx:5353/udp → 10.10.10.53:53/udp
```

---

## 12. Create TLS passthrough SNI router

```bash
sudo ./gateway.sh stream-tls-pass \
  --name tls-router \
  --listen 443 \
  --default-backend 10.10.10.10:443 \
  --map git.example.com=10.10.10.21:443,registry.example.com=10.10.10.22:443
```

Effect:

```text
git.example.com       → Nginx:443 → 10.10.10.21:443
registry.example.com  → Nginx:443 → 10.10.10.22:443
unknown SNI           → Nginx:443 → 10.10.10.10:443
```

In TLS passthrough mode:

```text
Nginx does not decrypt TLS.
Nginx does not use local certificates.
Backend services must own their certificates.
Nginx only routes traffic based on SNI.
```

---

## 13. Important boundary: HTTP 443 and stream 443

The same IP and port cannot be owned by both HTTP and stream contexts at the same time:

```nginx
http {
    server { listen 443 ssl; }
}

stream {
    server { listen 443; }
}
```

Valid designs:

| Design | Description |
|---|---|
| Different public IPs | HTTP 443 and stream 443 are separated by IP. |
| Different ports | Web uses 443; L4 services use ports such as 33060 or 15432. |
| Stream owns 443 | Stream routes TLS passthrough by SNI to HTTPS backends. |

---

## 14. Cloudflare boundary

Cloudflare normal orange-cloud proxy is for HTTP/HTTPS traffic on Cloudflare-supported ports. It does not proxy arbitrary TCP/UDP services unless Cloudflare Spectrum is used.

For raw TCP/UDP services:

```text
Option 1: DNS only, client connects directly to this Nginx gateway.
Option 2: Cloudflare Spectrum, Cloudflare proxies TCP/UDP.
```

Do not expect Cloudflare orange-cloud proxy to work for MySQL, PostgreSQL, Redis, SSH, or arbitrary UDP services.

---

## 15. Validation checklist

Run after installation:

```bash
sudo ./gateway.sh test
sudo ./gateway.sh reload
nginx -T | grep -E "http.d|stream.d|ssl_preread|proxy_pass"
systemctl status nginx --no-pager
```

Run after certificate issuance:

```bash
sudo certbot certificates
sudo certbot renew --dry-run
```

Run after Cloudflare Real IP setup:

```bash
nginx -T | grep -E "set_real_ip_from|CF-Connecting-IP|real_ip_recursive"
```

Run after stream proxy creation:

```bash
ss -lntup | grep -E '33060|5353|443'
```

---

## 16. Test matrix

| Scenario | Required checks |
|---|---|
| core | nginx.org repo configured, `nginx -V`, `nginx -t` |
| cert-cf | token can create TXT record, certificate exists, `renew --dry-run` passes |
| http-site | port 80 redirects to 443, certificate loads, backend proxy works |
| cf-real-ip | `CF-Connecting-IP` is trusted only from Cloudflare ranges |
| stream-tcp | port listens, client can reach backend through Nginx |
| stream-udp | UDP port listens, backend receives request |
| tls-pass | SNI routes to expected backend, unknown SNI uses fallback backend |
| rollback | intentionally bad config is rejected and old config restored |

---

## 17. Known limitations

Current known limitations:

- The scripts have not been fully validated across all Debian 12 package states.
- The generated configs are intentionally simple and do not replace a full ingress controller or service mesh.
- HTTP module supports basic reverse proxy and static site use cases only.
- HTTP module uses a simple WebSocket-friendly `Connection: upgrade` header rather than a full `map $http_upgrade` profile.
- Stream module supports one backend per generated proxy config.
- Cloudflare Real IP updater depends on external Cloudflare IP list endpoints being reachable.
- Cloudflare API Token rotation is not automated.
- CI checks Bash syntax and ShellCheck only; it does not run a full Debian 12 integration test.

---

## 18. Recommended production process

Use this order:

```text
1. Test on a clean Debian 12 VM.
2. Run core install.
3. Validate nginx -t.
4. Create Cloudflare API Token with zone-scoped DNS edit permission only.
5. Issue certificate.
6. Enable Cloudflare Full (strict).
7. Create one HTTP site or one stream proxy.
8. Validate access logs and upstream connectivity.
9. Add firewall rules.
10. Only then repeat for additional services.
```

---

## 19. Reference links

- Cloudflare Create API Token: https://developers.cloudflare.com/fundamentals/api/get-started/create-token/
- Certbot DNS Cloudflare plugin: https://certbot-dns-cloudflare.readthedocs.io/en/stable/
- Nginx stream module: https://nginx.org/en/docs/stream/ngx_stream_core_module.html
- Nginx proxy stream module: https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html
