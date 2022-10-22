#!/bin/bash

function blue(){
    echo -e "\033[34m\033[01m $1 \033[0m"
}
function green(){
    echo -e "\033[32m\033[01m $1 \033[0m"
}
function red(){
    echo -e "\033[31m\033[01m $1 \033[0m"
}
function yellow(){
    echo -e "\033[33m\033[01m $1 \033[0m"
}
function bred(){
    echo -e "\033[31m\033[01m\033[05m $1 \033[0m"
}
function byellow(){
    echo -e "\033[33m\033[01m\033[05m $1 \033[0m"
}

function isRoot() {
if [ "$EUID" -ne 0 ]; then
    return 1
fi
}

function initialCheck() {
if ! isRoot; then
    red "请用root用户运行脚本"
    exit 1
fi
}

Grpc_UUID1="$(cat /proc/sys/kernel/random/uuid)"
Grpc_UUID2="$(cat /proc/sys/kernel/random/uuid)"
Grpc_UUID3="$(cat /proc/sys/kernel/random/uuid)"

function V2ray_install() {
install_check

if [[ -e /etc/debian_version ]]; then
    apt-get update -y
    apt-get -y install binutils curl ufw unzip wget git
    ufw allow ssh
    ufw allow http
    ufw allow https
    ufw default deny incoming
    ufw default allow outgoing
    echo "y" | ufw enable
    ufw logging off
    ufw reload
else
    red "⚠️ 非debian系统无法运行"
    exit 0
fi
# Find out if the machine uses nogroup or nobody for the permissionless group
if grep -qs "^caddy:" /etc/passwd; then
    red "⚠️ caddy用户已存在"
else
    useradd -rms /sbin/nologin caddy
fi

cd `mktemp -d`
wget -O v2ray.zip https://github.com/v2fly/v2ray-core/releases/latest/download/v2ray-linux-64.zip
unzip -d v2ray v2ray.zip
mv v2ray/v2ray /usr/local/bin/v2ray
rm -rf v2ray/ v2ray.zip
if [[ ! -d /opt/v2ray ]]; then
    mkdir -p "/opt/v2ray"
fi

blue "生成v2ray trojan配置"

tee /opt/v2ray/trojan.json > /dev/null <<EOF
{
  "log": {"loglevel": "none"},
  "inbounds": [{
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"]
    },
    "listen": "127.0.0.1",
    "port": $V2ray_PORT,
    "protocol": "trojan",
    "tag": "trojan-grpc",
    "settings": {
      "clients": [{
        "password": "$Grpc_UUID1"
      },{
        "password": "$Grpc_UUID2"
      },{
        "password": "$Grpc_UUID3"
      }]
    },
    "streamSettings": {
      "network": "grpc",
      "security": "none",
      "grpcSettings": {
        "serviceName": "$GrpcServerName_PATH",
        "multiMode": true
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {},
    "tag": "direct"
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [{
      "type": "field",
      "inboundTag": ["trojan-grpc"],
      "outboundTag": "direct"
    },{
      "type": "field",
      "outboundTag": "blocked",
      "protocol": ["bittorrent"]
    }]
  },
  "dns": {
    "servers": [
      "https://dns.google/dns-query",
      "https://cloudflare-dns.com/dns-query"
    ]
  }
}
EOF

blue "配置V2ray开机启动脚本"

tee /etc/systemd/system/v2ray@.service > /dev/null <<EOF
[Unit]
Description=V2Ray Service
Documentation=https://www.v2fly.org/
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/v2ray run -config /opt/v2ray/%i.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

blue "安装caddy server"

latest_version="$(curl -s "https://api.github.com/repos/caddyserver/caddy/releases/latest" | grep 'tag_name' | cut -d '"' -f 4 | tr -d 'v')"
caddydownload="https://github.com/caddyserver/caddy/releases/latest/download/caddy_${latest_version}_linux_amd64.tar.gz"
cd `mktemp -d`
wget -nv "${caddydownload}" -O caddy.tar.gz
tar xf caddy.tar.gz && rm -rf caddy.tar.gz
mv caddy /usr/local/bin/caddy
if [[ ! -d /opt/caddy ]]; then
    mkdir -p "/opt/caddy"
fi

blue "配置Caddyfile"

tee /opt/caddy/Caddyfile > /dev/null <<EOF
{
  order reverse_proxy before map
  admin off
  log {
    output discard
  }
  servers :443 {
    protocols h1 h2
  }
  default_sni $Caddy_nameserver
}

:443, $Caddy_nameserver {
  encode {
    gzip 6
  }
  tls {
    protocols tls1.3
    curves x25519
    alpn h2
  }

  @GRPC {
    protocol grpc
    path /$GrpcServerName_PATH/*
  }
  reverse_proxy @GRPC 127.0.0.1:$V2ray_PORT {
    flush_interval -1
    header_up X-Real-IP {remote_host}
    transport http {
      versions h2c
    }
  }

  @host {
    host $Caddy_nameserver
  }
  route @host {
    header {
      Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
      X-Content-Type-Options nosniff
      X-Frame-Options SAMEORIGIN
      Referrer-Policy no-referrer-when-downgrade
    }
    file_server {
      root /opt/caddy/html
    }
  }
}
EOF

blue "配置Caddy开机启动脚本"

echo '[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /opt/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /opt/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target' > /etc/systemd/system/caddy.service

systemctl daemon-reload
if [[ ! -L /etc/systemd/system/multi-user.target.wants/caddy.service ]]; then
    systemctl enable --now caddy
else
    systemctl restart caddy
fi

if [[ ! -L /etc/systemd/system/multi-user.target.wants/v2ray@trojan.service ]]; then
    systemctl enable --now v2ray@trojan
else
    systemctl restart v2ray@trojan
fi

tee /opt/v2ray/done.txt <<EOF
安装完成:
------------------------------------------
请使用最新版本V2rayN客户端，新建trojan配置

您的域名是: $Caddy_nameserver

端口：443

配置设置了三个密码，请记住，任选其一
密码1：$Grpc_UUID1
密码2：$Grpc_UUID2
密码3：$Grpc_UUID3

传输协议：GRPC
gprc模式：multi
伪装域名：$Caddy_nameserver
路径：$GrpcServerName_PATH

传输层安装：tls
跳过证验证：false
alpn：h2
SNI：$Caddy_nameserver

如需默认伪装网站，请重新运行脚本


------------------------------------------
EOF
}

function install_check() {
initialCheck
until [[ $Caddy_nameserver =~ ^[a-zA-Z0-9.-]+$ ]]; do
    read -rp "请输入已解析到本VPS公网IP的域名: " -e Caddy_nameserver
done
until [[ $GrpcServerName_PATH =~ ^[a-zA-Z0-9.-]+$ ]]; do
    read -rp "请输入Grpc ServerName(相当于ws的/path路径，不带'/'杠): " -e GrpcServerName_PATH
done
until [[ $V2ray_PORT =~ ^[0-9]+$ ]] && [ "$V2ray_PORT" -ge 1025 ] && [ "$V2ray_PORT" -le 65535 ]; do
    read -rp "请输入v2ray内部端口，不小于1025 [1025-65535]: " -e V2ray_PORT
done
}

function settings_info() {
if [[ ! -e /opt/v2ray/done.txt ]]; then
    echo "配置未生成，请重新运行脚本"
else
    cat /opt/v2ray/done.txt
fi
}

function Web_install() {
rm -rf /opt/caddy/html
mkdir -p /opt/caddy/html
git clone https://github.com/HFIProgramming/mikutap.git /opt/caddy/html
chown -R caddy. /opt/caddy/html
}

Install_Menu() {
    clear
    green " ===================================="
    green "        caddy + v2ray脚本            "
    green " ===================================="
    echo
    blue " 1. 安装v2ray+caddy"
    echo
    blue " 2. 安装网站伪装"
    echo
    blue " 3. 查看配置"
    echo
    yellow " 4. 退出脚本"
    echo
    read -p "请输入数字:" numxxxx
    case "$numxxxx" in
    1)
        V2ray_install
        ;;
    2)
        Web_install
        ;;
    3)
        settings_info
        ;;
    4)
        exit 1
        ;;
    *)
        clear
        red "请输入正确数字"
        sleep 2s
        Install_Menu
        ;;
    esac
}

Install_Menu
