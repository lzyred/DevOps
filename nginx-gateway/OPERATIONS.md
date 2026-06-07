# Nginx Gateway Operations Guide

This document covers day-2 operations for `nginx-gateway`: service status, config inventory, logs, certificates, timers, health checks, and safe removal.

The goal is to make the gateway maintainable after the initial installation, not just install Nginx once.

---

## 1. Basic status

Show service status, key configs, listening ports, certificates, and timers:

```bash
sudo ./gateway.sh status
```

What it checks:

```text
Nginx service status
nginx -t result
listening ports
HTTP configs under /etc/nginx/http.d/
Stream configs under /etc/nginx/stream.d/
Certbot certificates
Certbot and Cloudflare Real IP timers
```

Use this when you want a quick operational snapshot.

---

## 2. Health check

Run a stricter health check:

```bash
sudo ./gateway.sh doctor
```

What it checks:

```text
nginx command exists
nginx -t passes
nginx service is active
http.d include exists
stream.d include exists
certbot command exists, if certificate module was used
Cloudflare credential directory exists, if certificate module was used
Cloudflare Real IP config and timer status
```

`doctor` returns non-zero if critical checks fail.

---

## 3. List managed configs

List all HTTP and stream configs:

```bash
sudo ./gateway.sh list
```

HTTP configs are expected under:

```text
/etc/nginx/http.d/*.conf
```

Stream configs are expected under:

```text
/etc/nginx/stream.d/*.conf
```

---

## 4. Show one config

Show an HTTP site config by domain:

```bash
sudo ./gateway.sh show --domain app.example.com
```

Show stream configs by logical name:

```bash
sudo ./gateway.sh show --name mysql-prod
```

Show any config file by path:

```bash
sudo ./gateway.sh show --path /etc/nginx/http.d/app.example.com.conf
```

---

## 5. Logs

Show HTTP access log:

```bash
sudo ./gateway.sh logs --domain app.example.com --type access --lines 100
```

Follow HTTP error log:

```bash
sudo ./gateway.sh logs --domain app.example.com --type error --follow
```

Show stream access log:

```bash
sudo ./gateway.sh logs --stream --type access --lines 100
```

Show stream error log:

```bash
sudo ./gateway.sh logs --stream --type error --follow
```

Show nginx journal:

```bash
sudo ./gateway.sh logs --journal --lines 200
```

Follow nginx journal:

```bash
sudo ./gateway.sh logs --journal --follow
```

---

## 6. Certificate status

Show Certbot certificates, renewal configs, and Cloudflare credential file permissions:

```bash
sudo ./gateway.sh cert-status
```

Expected credential file example:

```text
/etc/letsencrypt/cloudflare/example.com.ini
```

Expected file mode:

```text
600
```

The Cloudflare credential file must not be deleted after issuance because renewal uses the same credential file path stored in Certbot renewal configuration.

---

## 7. Renewal check

Run Certbot renewal dry run:

```bash
sudo ./gateway.sh renew-check
```

This executes:

```bash
certbot renew --dry-run
```

Use this after certificate issuance, Cloudflare token rotation, or Certbot/plugin upgrades.

---

## 8. Timers

Show Certbot and Cloudflare Real IP timers:

```bash
sudo ./gateway.sh timers
```

Expected timers may include:

```text
certbot.timer
snap.certbot.renew.timer
update-cloudflare-real-ip.timer
```

The exact Certbot timer name depends on the package source and system state.

---

## 9. Safe removal

Remove one HTTP site config safely:

```bash
sudo ./gateway.sh remove-http-site --domain app.example.com
```

Remove one stream TCP config safely:

```bash
sudo ./gateway.sh remove-stream --name mysql-prod --type tcp
```

Remove all stream configs matching the logical name:

```bash
sudo ./gateway.sh remove-stream --name mysql-prod
```

Removal behavior:

```text
1. Back up the config file with .bak.YYYYMMDDHHMMSS.PID suffix.
2. Remove the active config.
3. Run nginx -t.
4. Reload nginx.
5. If test or reload fails, restore the backup.
```

---

## 10. Manual fallback commands

When debugging manually, these commands are still useful:

```bash
systemctl status nginx --no-pager
journalctl -u nginx -n 200 --no-pager
nginx -t
nginx -T | less
ss -lntup | grep nginx
certbot certificates
certbot renew --dry-run
systemctl list-timers --all | grep -E 'certbot|snap.certbot|update-cloudflare-real-ip'
```

---

## 11. Operational limitations

Current ops commands are intentionally lightweight. They do not provide:

```text
centralized metrics
active upstream health checks
automatic firewall management
Cloudflare API token rotation
multi-backend load balancing inventory
full Debian 12 integration testing
```

For production environments, pair this gateway with external monitoring and backup strategy.
