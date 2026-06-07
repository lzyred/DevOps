# Host Firewall and Installation Management for Non-Cloud Linux Hosts

> Default language: English  
> Chinese version: [README.zh-CN.md](./README.zh-CN.md)

## 1. Scope

This directory defines a practical host firewall and installation-management baseline for non-cloud Linux hosts, including:

- Rocky Linux 9.x / RHEL-like hosts using `firewalld`.
- Ubuntu Server and Debian hosts using `ufw`.
- Bare-metal, self-hosted, lab, edge, or VPS-like systems where there is no cloud security group as the first network boundary.
- Hosts running common services such as SSH, Nginx, Docker-published applications, VPN, reverse proxies, and Xray-like TCP services.

This guide is intentionally host-focused. It does not replace upstream perimeter firewalls, Cloudflare/WAF, router ACLs, Kubernetes NetworkPolicy, or application-layer authentication.

## 2. Operating principles

The baseline is built around these rules:

1. **Deny inbound by default.** Only explicitly required services are allowed.
2. **Keep the firewall manager consistent with the OS family.** Use `firewalld` on Rocky Linux 9.x and `ufw` on Ubuntu/Debian unless there is a strong reason to use raw `nftables`.
3. **Do not disable IPv6 management casually.** If the host has IPv6 connectivity, the firewall must manage IPv6 as well. Setting UFW `IPV6=no` without disabling IPv6 at the OS/network level can create a blind spot.
4. **Do not rely only on the host firewall to hide local backends.** Internal applications behind Nginx should bind to `127.0.0.1`, not `0.0.0.0`.
5. **Docker-published ports require special attention.** A container published as `-p 8080:8080` or `ports: ["8080:8080"]` is exposed on all host interfaces. Prefer `127.0.0.1:8080:8080` for reverse-proxy-only backends.
6. **SSH must be protected first.** Prefer source-IP restriction. If the administrator IP is dynamic, use rate limiting and strong SSH hardening.
7. **Runtime changes must be reversible.** Always keep one active SSH session open, test a second session before deleting old SSH allow rules, and keep a rollback path.

Reference documentation:

- UFW: <https://manpages.ubuntu.com/manpages/noble/man8/ufw.8.html>
- firewalld: <https://firewalld.org/documentation/>
- Docker packet filtering and published ports: <https://docs.docker.com/engine/network/packet-filtering-firewalls/>

## 3. Decision matrix

| Host type | Recommended manager | Reason |
|---|---|---|
| Rocky Linux 9.x | `firewalld` | Native RHEL-like operational model, zone-based management, good service abstraction. |
| Ubuntu Server | `ufw` | Simple, readable, and operationally friendly for host-level rules. |
| Debian Server | `ufw` or `nftables` | Use UFW for simple host firewalls. Use nftables directly for advanced routing/NAT/firewall policy. |
| Docker-heavy host | `ufw`/`firewalld` plus Docker binding control | Firewall rules alone are not enough. Published container ports must be bound intentionally. |
| Router/VPN/NAT gateway | `nftables` or carefully designed `firewalld` | Routed traffic needs explicit forwarding/NAT policy; do not copy simple host-only rules. |

## 4. Pre-change discovery checklist

Run this before changing any firewall rule.

```bash
# Current user and SSH source
echo "$SSH_CONNECTION"
who
ss -tnp | grep ':22' || true

# Listening TCP/UDP services
sudo ss -lntup
sudo ss -lnup

# Existing firewall state
sudo ufw status numbered 2>/dev/null || true
sudo ufw status verbose 2>/dev/null || true
sudo firewall-cmd --state 2>/dev/null || true
sudo firewall-cmd --get-active-zones 2>/dev/null || true
sudo firewall-cmd --list-all 2>/dev/null || true

# Docker published ports
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}' 2>/dev/null || true
sudo ss -lntup | grep docker-proxy || true

# IPv6 status
ip -6 addr show scope global || true
```

Important interpretation:

- `0.0.0.0:PORT` means the service listens on all IPv4 interfaces.
- `[::]:PORT` means the service listens on all IPv6 interfaces.
- `127.0.0.1:PORT` means local-only IPv4.
- `[::1]:PORT` means local-only IPv6.
- Docker `0.0.0.0:8080->8080/tcp` means the container port is public unless blocked elsewhere.

## 5. Ubuntu/Debian UFW baseline

### 5.1 Backup first

```bash
sudo ufw status numbered
sudo cp -a /etc/ufw /etc/ufw.bak.$(date +%F-%H%M%S)
```

Keep the existing SSH session open until the final validation passes.

### 5.2 Safe default policy

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

Do not blindly apply `default deny routed` if the host is a Docker, VPN, router, or NAT gateway. Review routed traffic first.

### 5.3 SSH rule models

#### Model A: static administrator IP, preferred

Replace `ADMIN_PUBLIC_IP` with the real trusted source IP.

```bash
sudo ufw allow from ADMIN_PUBLIC_IP to any port 22 proto tcp comment 'Allow SSH from admin IP'
```

Only after testing a new SSH session should broad SSH rules be deleted.

```bash
sudo ufw status numbered
# Delete old broad OpenSSH rules by number, from highest number to lowest number.
sudo ufw delete <RULE_NUMBER>
```

Expected result:

```text
22/tcp ALLOW IN ADMIN_PUBLIC_IP # Allow SSH from admin IP
```

#### Model B: dynamic administrator IP

If the administrator source IP changes often, avoid locking yourself out. Use rate limiting and SSH daemon hardening.

```bash
sudo ufw limit OpenSSH comment 'Rate limit SSH'
```

Also harden `/etc/ssh/sshd_config` separately:

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

Reload SSH safely:

```bash
sudo sshd -t
sudo systemctl reload ssh
```

### 5.4 Web service baseline

For normal Nginx HTTP/HTTPS service:

```bash
sudo ufw allow 80/tcp comment 'Allow Nginx HTTP'
sudo ufw allow 443/tcp comment 'Allow Nginx HTTPS'
```

If the service is only behind Cloudflare or another reverse proxy, source-IP restriction can be added later, but it increases rule count and maintenance overhead. For small hosts, a practical first step is:

- Keep 80/443 open if public web access is required.
- Configure Nginx default server to reject unknown hosts.
- Bind private backend services to `127.0.0.1`.

### 5.5 Application TCP service baseline

For a required public TCP service, such as a Reality/Xray-like TCP listener:

```bash
sudo ufw allow 50548/tcp comment 'Allow required public TCP service'
```

Do not allow UDP unless the process actually listens on UDP and the application requires it.

```bash
sudo ss -lnup | grep ':50548' || true
sudo ufw delete allow 50548/udp
```

### 5.6 IPv6 handling

Keep `/etc/default/ufw` as:

```ini
IPV6=yes
```

If the host has global IPv6 addresses, manage IPv6 rules explicitly. Do not use `IPV6=no` as a shortcut unless IPv6 is disabled at the OS/network level and this is an intentional host standard.

### 5.7 Apply and verify

```bash
sudo ufw reload
sudo ufw status verbose
sudo ufw status numbered
sudo ss -lntup
```

Open a new terminal and verify SSH login before closing the old session.

## 6. Rocky Linux 9.x firewalld baseline

### 6.1 Install and enable

```bash
sudo dnf install -y firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --state
```

### 6.2 Inspect active zones

```bash
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all
```

For a normal internet-facing host, use the `public` zone unless a site-specific zone model already exists.

```bash
sudo firewall-cmd --set-default-zone=public
```

### 6.3 SSH source restriction model

Add the trusted SSH source first:

```bash
sudo firewall-cmd --permanent --zone=public \
  --add-rich-rule='rule family="ipv4" source address="ADMIN_PUBLIC_IP/32" service name="ssh" accept'

sudo firewall-cmd --reload
```

Test a second SSH login. After confirmation, remove broad SSH service exposure if present:

```bash
sudo firewall-cmd --permanent --zone=public --remove-service=ssh
sudo firewall-cmd --reload
```

If the admin IP is dynamic, keep SSH open but compensate with key-only SSH, disabled root login, fail2ban/sshguard, and monitoring.

### 6.4 Web service baseline

```bash
sudo firewall-cmd --permanent --zone=public --add-service=http
sudo firewall-cmd --permanent --zone=public --add-service=https
sudo firewall-cmd --reload
```

### 6.5 Required public TCP service

```bash
sudo firewall-cmd --permanent --zone=public --add-port=50548/tcp
sudo firewall-cmd --reload
```

Do not add UDP unless required and verified:

```bash
sudo ss -lnup | grep ':50548' || true
```

### 6.6 Verify

```bash
sudo firewall-cmd --list-all --zone=public
sudo ss -lntup
```

## 7. Docker and local backend exposure

For a reverse-proxy-only backend, this is unsafe:

```yaml
ports:
  - "8080:8080"
```

It exposes the backend on all host interfaces.

Use this instead:

```yaml
ports:
  - "127.0.0.1:8080:8080"
```

Nginx should proxy to loopback:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
}
```

Expected listener:

```text
127.0.0.1:8080
```

Not:

```text
0.0.0.0:8080
```

Temporary firewall blocks for Docker-published ports can be useful during an emergency, but the durable fix is to bind the published port correctly.

## 8. Nginx direct-IP and unknown-host protection

For public 80/443 hosts, add a default server to reject unknown hostnames.

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate     /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    return 444;
}
```

Then configure real virtual hosts separately:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
```

## 9. Recommended target states

### 9.1 Ubuntu/Debian UFW example

For a host with:

- SSH restricted to one administrator IP.
- Public Nginx on 80/443.
- Public TCP service on 50548.
- No UDP service on 50548.
- Backend app bound to `127.0.0.1:8080`.

Expected UFW state:

```text
22/tcp      ALLOW IN  ADMIN_PUBLIC_IP
80/tcp      ALLOW IN  Anywhere
443/tcp     ALLOW IN  Anywhere
50548/tcp   ALLOW IN  Anywhere
80/tcp (v6) ALLOW IN  Anywhere (v6)
443/tcp(v6) ALLOW IN  Anywhere (v6)
```

There should be no broad `OpenSSH ALLOW Anywhere`, no broad `OpenSSH LIMIT Anywhere` if source-IP restriction is the target, and no unused UDP allow rule.

### 9.2 Rocky Linux firewalld example

```bash
sudo firewall-cmd --list-all --zone=public
```

Expected conceptual state:

```text
services: http https
ports: 50548/tcp
rich rules:
  rule family="ipv4" source address="ADMIN_PUBLIC_IP/32" service name="ssh" accept
```

## 10. Validation checklist

After applying changes:

```bash
# Firewall state
sudo ufw status verbose 2>/dev/null || true
sudo firewall-cmd --list-all 2>/dev/null || true

# Listener exposure
sudo ss -lntup
sudo ss -lnup

# Backend must not be public
sudo ss -lntup | grep ':8080' || true

# Web local check
curl -I http://127.0.0.1 2>/dev/null || true
curl -kI https://127.0.0.1 2>/dev/null || true

# SSH config check
sudo sshd -t
```

External validation should be done from another network:

```bash
nmap -Pn -p 22,80,443,50548,8080 SERVER_PUBLIC_IP
```

Expected:

- `22` open only from trusted admin source, or rate-limited if dynamic IP model is used.
- `80/443` open if web service is public.
- `50548/tcp` open only if required.
- `50548/udp` closed unless explicitly required.
- `8080` closed externally when it is a private backend.

## 11. Rollback

### UFW rollback

If a rule change blocks required traffic but the session is still open:

```bash
sudo ufw status numbered
sudo ufw allow OpenSSH
sudo ufw reload
```

To restore from backup:

```bash
sudo ufw disable
sudo rm -rf /etc/ufw
sudo cp -a /etc/ufw.bak.YYYY-MM-DD-HHMMSS /etc/ufw
sudo ufw enable
sudo ufw status verbose
```

### firewalld rollback

List current permanent configuration:

```bash
sudo firewall-cmd --permanent --list-all --zone=public
```

Re-add broad SSH temporarily if locked-down SSH fails during a controlled session:

```bash
sudo firewall-cmd --permanent --zone=public --add-service=ssh
sudo firewall-cmd --reload
```

## 12. Change record template

Use this template for firewall changes.

```markdown
# Host Firewall Change Record

## Host
- Hostname:
- OS version:
- Public IP:
- IPv6 enabled: yes/no
- Firewall manager: ufw/firewalld/nftables

## Existing exposure
```text
paste ss -lntup output here
paste firewall status here
```

## Target exposure
| Port | Protocol | Source | Reason | Owner |
|---|---|---|---|---|
| 22 | tcp | ADMIN_PUBLIC_IP | SSH admin | Infra |
| 80 | tcp | any | HTTP redirect / web | Web |
| 443 | tcp | any | HTTPS | Web |

## Risk assessment
- SSH lockout risk:
- Docker-published port risk:
- IPv6 blind spot risk:
- Rollback method:

## Commands
```bash
commands here
```

## Validation
```bash
validation output here
```

## Rollback
```bash
rollback commands here
```
```

## 13. Minimum production standard

A host firewall configuration is acceptable only when all of the following are true:

- There is a documented reason for every public listening port.
- SSH is either source-restricted or rate-limited with key-only authentication.
- IPv6 exposure is checked and intentionally managed.
- Docker-published ports are reviewed and private backends bind to loopback.
- UFW/firewalld status matches actual `ss -lntup` listener exposure.
- A rollback path exists before deleting old SSH rules.
- External scanning confirms no unexpected exposed ports.
