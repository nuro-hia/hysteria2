#!/bin/bash
set -e

echo "🚀 一键安装 Hysteria 并对接 Xboard"
echo "--------------------------------------"

read -rp "🧭 请输入 Xboard 面板地址 (例如 https://xboard.example.com): " API_HOST
read -rp "🔑 请输入通讯密钥 (apiKey): " API_KEY
read -rp "🆔 请输入节点 ID (nodeID): " NODE_ID
read -rp "🌐 请输入节点域名 (证书绑定域名): " DOMAIN
read -rp "📡 请输入监听端口 (默认36024): " PORT
PORT=${PORT:-36024}

echo ""
echo "📂 创建目录 /etc/hysteria ..."
mkdir -p /etc/hysteria
cd /etc/hysteria

echo "🔧 写入 server.yaml ..."
cat > /etc/hysteria/server.yaml <<EOF
v2board:
  apiHost: ${API_HOST}
  apiKey: ${API_KEY}
  nodeID: ${NODE_ID}

tls:
  type: tls
  cert: /etc/hysteria/fullchain.pem
  key: /etc/hysteria/privkey.pem

auth:
  type: v2board

trafficStats:
  listen: 127.0.0.1:7653

acl:
  inline:
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(127.0.0.0/8)
    - reject(fc00::/7)

listen: :${PORT}
EOF

echo "🔧 写入 docker-compose.yml ..."
cat > /etc/hysteria/docker-compose.yml <<EOF
version: '3'
services:
  hysteria:
    image: ghcr.io/cedar2025/hysteria:latest
    container_name: hysteria
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - /etc/hysteria:/etc/hysteria
    command: server -c /etc/hysteria/server.yaml
EOF

echo ""
echo "🔒 检查证书..."
if [[ ! -f "/etc/hysteria/fullchain.pem" || ! -f "/etc/hysteria/privkey.pem" ]]; then
    echo "❗ 未检测到证书，准备申请中（需域名已解析到本机）"
    curl https://get.acme.sh | sh
    ~/.acme.sh/acme.sh --issue -d ${DOMAIN} --standalone
    ~/.acme.sh/acme.sh --install-cert -d ${DOMAIN} \
        --key-file /etc/hysteria/privkey.pem \
        --fullchain-file /etc/hysteria/fullchain.pem
fi

echo "🐳 启动 Docker 容器 ..."
docker compose up -d

echo ""
echo "✅ 部署完成！"
echo "--------------------------------------"
echo "📄 配置文件: /etc/hysteria/server.yaml"
echo "⚙️ 监听端口: ${PORT} (UDP)"
echo "🌐 面板: ${API_HOST}"
echo "🆔 节点ID: ${NODE_ID}"
echo "--------------------------------------"
echo "日志查看: docker logs -f hysteria"
