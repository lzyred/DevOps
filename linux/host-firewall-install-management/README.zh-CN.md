# 非云 Linux 主机防火墙与主机安装管理

> 默认文档语言：英文  
> English version: [README.md](./README.md)

## 1. 适用范围

本目录用于定义非云 Linux 主机的主机防火墙和安装管理基线，覆盖：

- Rocky Linux 9.x / RHEL-like 主机，默认使用 `firewalld`。
- Ubuntu Server / Debian 主机，默认使用 `ufw`。
- 裸金属、自托管、实验室、边缘节点、VPS 类主机，尤其是没有云安全组作为第一层边界的环境。
- 常见服务场景，例如 SSH、Nginx、Docker 发布端口、VPN、反向代理、Xray 类 TCP 服务。

本指南只解决主机层防火墙和暴露面管理问题，不替代上游防火墙、Cloudflare/WAF、路由器 ACL、Kubernetes NetworkPolicy 或应用层认证。

## 2. 核心原则

本基线遵循以下原则：

1. **默认拒绝入站。** 只开放明确需要的服务端口。
2. **防火墙管理工具应符合系统家族习惯。** Rocky Linux 9.x 优先使用 `firewalld`；Ubuntu/Debian 优先使用 `ufw`；高级路由/NAT 场景再考虑直接使用 `nftables`。
3. **不要随意关闭 IPv6 管理。** 如果主机有 IPv6 连接能力，防火墙也必须管理 IPv6。只在 UFW 中设置 `IPV6=no`，但系统层面仍然启用 IPv6，可能造成 IPv6 暴露盲区。
4. **不要只依赖主机防火墙隐藏本地后端服务。** Nginx 后面的内部应用应该绑定 `127.0.0.1`，而不是 `0.0.0.0`。
5. **Docker 发布端口必须单独检查。** `-p 8080:8080` 或 `ports: ["8080:8080"]` 会把容器端口发布到所有主机网卡。只给 Nginx 反代使用的后端应使用 `127.0.0.1:8080:8080`。
6. **SSH 是最高优先级。** 最好限制来源 IP；如果管理员公网 IP 动态变化，至少使用 rate limit，并配合 SSH 自身加固。
7. **所有运行时变更必须可回滚。** 删除旧 SSH 放行规则前，必须保留一个已连接 SSH 会话，并用第二个新会话验证登录成功。

参考文档：

- UFW: <https://manpages.ubuntu.com/manpages/noble/man8/ufw.8.html>
- firewalld: <https://firewalld.org/documentation/>
- Docker packet filtering and published ports: <https://docs.docker.com/engine/network/packet-filtering-firewalls/>

## 3. 选型矩阵

| 主机类型 | 推荐工具 | 原因 |
|---|---|---|
| Rocky Linux 9.x | `firewalld` | RHEL-like 默认运维模型，zone 管理清晰，服务抽象较好。 |
| Ubuntu Server | `ufw` | 简单、可读性好，适合主机级规则管理。 |
| Debian Server | `ufw` 或 `nftables` | 简单主机防火墙用 UFW；复杂路由/NAT/firewall policy 用 nftables。 |
| Docker 较多的主机 | `ufw`/`firewalld` + Docker 绑定控制 | 只靠防火墙不够，容器端口发布地址必须显式控制。 |
| 路由/VPN/NAT 网关 | `nftables` 或严谨设计的 `firewalld` | 转发流量需要明确 forwarding/NAT 策略，不能照搬普通主机规则。 |

## 4. 变更前检查清单

任何防火墙变更前，先执行：

```bash
# 当前用户和 SSH 来源
echo "$SSH_CONNECTION"
who
ss -tnp | grep ':22' || true

# 当前 TCP/UDP 监听
sudo ss -lntup
sudo ss -lnup

# 当前防火墙状态
sudo ufw status numbered 2>/dev/null || true
sudo ufw status verbose 2>/dev/null || true
sudo firewall-cmd --state 2>/dev/null || true
sudo firewall-cmd --get-active-zones 2>/dev/null || true
sudo firewall-cmd --list-all 2>/dev/null || true

# Docker 发布端口
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}' 2>/dev/null || true
sudo ss -lntup | grep docker-proxy || true

# IPv6 状态
ip -6 addr show scope global || true
```

解释：

- `0.0.0.0:PORT` 表示服务监听所有 IPv4 网卡。
- `[::]:PORT` 表示服务监听所有 IPv6 网卡。
- `127.0.0.1:PORT` 表示仅本机 IPv4 可访问。
- `[::1]:PORT` 表示仅本机 IPv6 可访问。
- Docker 中 `0.0.0.0:8080->8080/tcp` 表示容器端口已经公网发布，除非上游有其他阻断。

## 5. Ubuntu/Debian UFW 基线

### 5.1 先备份

```bash
sudo ufw status numbered
sudo cp -a /etc/ufw /etc/ufw.bak.$(date +%F-%H%M%S)
```

在最终验证完成前，不要关闭当前 SSH 会话。

### 5.2 安全默认策略

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

如果主机是 Docker、VPN、路由器或 NAT 网关，不要无脑执行 `default deny routed`，应先确认转发流量需求。

### 5.3 SSH 规则模型

#### 模型 A：固定管理员公网 IP，推荐

将 `ADMIN_PUBLIC_IP` 替换成真实可信来源 IP。

```bash
sudo ufw allow from ADMIN_PUBLIC_IP to any port 22 proto tcp comment 'Allow SSH from admin IP'
```

只有在第二个新 SSH 会话验证成功后，才删除旧的宽松 SSH 规则。

```bash
sudo ufw status numbered
# 按编号删除旧的 OpenSSH 宽松规则，建议从大编号到小编号删除。
sudo ufw delete <RULE_NUMBER>
```

目标状态：

```text
22/tcp ALLOW IN ADMIN_PUBLIC_IP # Allow SSH from admin IP
```

#### 模型 B：管理员公网 IP 动态变化

如果管理员来源 IP 经常变化，不要贸然只允许固定 IP，避免锁死自己。可以先使用限速：

```bash
sudo ufw limit OpenSSH comment 'Rate limit SSH'
```

同时加固 `/etc/ssh/sshd_config`：

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

安全重载 SSH：

```bash
sudo sshd -t
sudo systemctl reload ssh
```

### 5.4 Web 服务基线

普通 Nginx HTTP/HTTPS 服务：

```bash
sudo ufw allow 80/tcp comment 'Allow Nginx HTTP'
sudo ufw allow 443/tcp comment 'Allow Nginx HTTPS'
```

如果服务只走 Cloudflare 或其他反向代理，可以进一步限制来源 IP。但这会增加规则数量和维护成本。对于小型主机，更现实的第一阶段做法是：

- 公共 Web 服务需要访问时，保留 80/443 开放。
- 在 Nginx 默认站点中拒绝未知 Host。
- 内部后端服务只绑定 `127.0.0.1`。

### 5.5 应用 TCP 服务基线

如果确实需要一个公网 TCP 服务，例如 Reality/Xray 类监听：

```bash
sudo ufw allow 50548/tcp comment 'Allow required public TCP service'
```

除非进程确实监听 UDP 且应用明确需要 UDP，否则不要开放 UDP。

```bash
sudo ss -lnup | grep ':50548' || true
sudo ufw delete allow 50548/udp
```

### 5.6 IPv6 处理

`/etc/default/ufw` 建议保持：

```ini
IPV6=yes
```

如果主机存在全局 IPv6 地址，就应显式管理 IPv6 规则。不要把 `IPV6=no` 当作安全捷径，除非你已经在 OS/网络层面明确关闭 IPv6，并且这是主机标准的一部分。

### 5.7 应用与验证

```bash
sudo ufw reload
sudo ufw status verbose
sudo ufw status numbered
sudo ss -lntup
```

再开一个新终端测试 SSH 登录成功后，才能关闭旧会话。

## 6. Rocky Linux 9.x firewalld 基线

### 6.1 安装并启用

```bash
sudo dnf install -y firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --state
```

### 6.2 检查 active zones

```bash
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all
```

普通公网主机建议使用 `public` zone，除非环境已有明确的 zone 模型。

```bash
sudo firewall-cmd --set-default-zone=public
```

### 6.3 SSH 来源限制模型

先添加可信 SSH 来源：

```bash
sudo firewall-cmd --permanent --zone=public \
  --add-rich-rule='rule family="ipv4" source address="ADMIN_PUBLIC_IP/32" service name="ssh" accept'

sudo firewall-cmd --reload
```

测试第二个 SSH 登录成功后，再删除宽松 SSH 服务开放：

```bash
sudo firewall-cmd --permanent --zone=public --remove-service=ssh
sudo firewall-cmd --reload
```

如果管理员 IP 动态变化，可以保留 SSH 开放，但必须通过密钥登录、禁用 root 登录、fail2ban/sshguard 和监控来补偿风险。

### 6.4 Web 服务基线

```bash
sudo firewall-cmd --permanent --zone=public --add-service=http
sudo firewall-cmd --permanent --zone=public --add-service=https
sudo firewall-cmd --reload
```

### 6.5 必要公网 TCP 服务

```bash
sudo firewall-cmd --permanent --zone=public --add-port=50548/tcp
sudo firewall-cmd --reload
```

除非确认需要并且有 UDP 监听，否则不要添加 UDP：

```bash
sudo ss -lnup | grep ':50548' || true
```

### 6.6 验证

```bash
sudo firewall-cmd --list-all --zone=public
sudo ss -lntup
```

## 7. Docker 与本地后端暴露面

只给反向代理使用的后端服务，不应该这样发布：

```yaml
ports:
  - "8080:8080"
```

这会把后端发布到所有主机网卡。

应该改为：

```yaml
ports:
  - "127.0.0.1:8080:8080"
```

Nginx 反代也应该指向 loopback：

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
}
```

期望监听结果：

```text
127.0.0.1:8080
```

不应是：

```text
0.0.0.0:8080
```

紧急情况下可以临时用防火墙阻断 Docker 发布端口，但长期正确方案是从 Docker 端口绑定层面修复。

## 8. Nginx 直连 IP 与未知 Host 防护

公网开放 80/443 的主机，建议添加默认 server，拒绝未知域名访问。

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

真实业务域名独立配置：

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

## 9. 推荐目标状态

### 9.1 Ubuntu/Debian UFW 示例

假设主机满足：

- SSH 只允许一个管理员 IP。
- Nginx 80/443 对公网开放。
- TCP 50548 对公网开放。
- 50548 不需要 UDP。
- 后端应用绑定 `127.0.0.1:8080`。

期望 UFW 状态：

```text
22/tcp      ALLOW IN  ADMIN_PUBLIC_IP
80/tcp      ALLOW IN  Anywhere
443/tcp     ALLOW IN  Anywhere
50548/tcp   ALLOW IN  Anywhere
80/tcp (v6) ALLOW IN  Anywhere (v6)
443/tcp(v6) ALLOW IN  Anywhere (v6)
```

不应存在宽松的 `OpenSSH ALLOW Anywhere`；如果目标是固定 IP SSH，也不应同时存在 `OpenSSH LIMIT Anywhere`；不应存在未使用的 UDP 放行规则。

### 9.2 Rocky Linux firewalld 示例

```bash
sudo firewall-cmd --list-all --zone=public
```

概念目标状态：

```text
services: http https
ports: 50548/tcp
rich rules:
  rule family="ipv4" source address="ADMIN_PUBLIC_IP/32" service name="ssh" accept
```

## 10. 验证清单

变更后执行：

```bash
# 防火墙状态
sudo ufw status verbose 2>/dev/null || true
sudo firewall-cmd --list-all 2>/dev/null || true

# 服务监听暴露面
sudo ss -lntup
sudo ss -lnup

# 后端不应公网暴露
sudo ss -lntup | grep ':8080' || true

# 本地 Web 检查
curl -I http://127.0.0.1 2>/dev/null || true
curl -kI https://127.0.0.1 2>/dev/null || true

# SSH 配置检查
sudo sshd -t
```

外部验证应从另一张网络执行：

```bash
nmap -Pn -p 22,80,443,50548,8080 SERVER_PUBLIC_IP
```

期望结果：

- `22` 只从可信管理员来源开放；如果是动态 IP 模型，则至少 rate-limited。
- `80/443` 在公共 Web 服务需要时开放。
- `50548/tcp` 只在确实需要时开放。
- `50548/udp` 除非明确需要，否则应关闭。
- `8080` 作为私有后端时，不应从公网访问。

## 11. 回滚

### UFW 回滚

如果规则变更影响必要访问，但当前 SSH 会话仍在：

```bash
sudo ufw status numbered
sudo ufw allow OpenSSH
sudo ufw reload
```

从备份恢复：

```bash
sudo ufw disable
sudo rm -rf /etc/ufw
sudo cp -a /etc/ufw.bak.YYYY-MM-DD-HHMMSS /etc/ufw
sudo ufw enable
sudo ufw status verbose
```

### firewalld 回滚

查看当前永久配置：

```bash
sudo firewall-cmd --permanent --list-all --zone=public
```

如果 SSH 限制失败，在受控会话中临时恢复宽松 SSH：

```bash
sudo firewall-cmd --permanent --zone=public --add-service=ssh
sudo firewall-cmd --reload
```

## 12. 变更记录模板

防火墙变更建议使用以下模板：

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

## 13. 最低生产标准

主机防火墙配置只有满足以下条件，才算可接受：

- 每一个公网监听端口都有明确记录的业务理由。
- SSH 已限制来源，或在动态 IP 场景下至少限速并使用密钥认证。
- IPv6 暴露面已检查并被明确管理。
- Docker 发布端口已审查，私有后端绑定到 loopback。
- UFW/firewalld 状态与 `ss -lntup` 的实际监听结果一致。
- 删除旧 SSH 规则前有回滚路径。
- 外部扫描确认没有意外暴露端口。
