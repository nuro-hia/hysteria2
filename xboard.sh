#!/bin/bash
# ============================================================
# Hysteria + Xboard 一键部署脚本（全自动完整版）
# 作者: nuro
# 仓库: https://github.com/nuro-hia/hysteria2
# ============================================================

set -e
CONFIG_DIR="/etc/hysteria"
COMPOSE_FILE="${CONFIG_DIR}/docker-compose.yml"
COMPOSE_CMD=""

install_all() {
  echo "📦 安装 Docker 与依赖..."
  apt update -y >/dev/null 2>&1
  apt install -y curl wget ca-certificates gnupg lsb-release openssl -y >/dev/null 2>&1

  if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 安装 Docker 引擎..."
    curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
    systemctl enable docker --now >/dev/null 2>&1
  fi

  echo "🔧 安装 Docker Compose（含插件）..."
  apt install -y docker-compose-plugin >/dev/null 2>&1 || true

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  else
    echo "📦 安装独立版 docker-compose..."
    curl -fsSL "https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-$(uname -s)-$(uname -m)" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    COMPOSE_CMD="docker-compose"
  fi

  echo "✅ Docker 与 Compose 安装完成 (${COMPOSE_CMD})"
}

menu() {
  clear
  echo "=============================="
  echo " Hysteria 对接 Xboard 管理脚本"
  echo "=============================="
  echo "1️⃣ 安装并部署 Hysteria"
  echo "2️⃣ 重启容器"
  echo "3️⃣ 停止容器"
  echo "4️⃣ 删除容器与配置"
  echo "5️⃣ 查看运行日志"
  echo "6️⃣ 更新镜像"
  echo "7️⃣ 退出"
  echo "=============================="
  read -rp "请选择操作: " choice
  case $choice in
    1) install_hysteria ;;
    2) ${COMPOSE_CMD} -f ${COMPOSE_FILE} restart || echo "⚠️ 未检测到容器"; sleep 1; menu ;;
    3) ${COMPOSE_CMD} -f ${COMPOSE_FILE} down || echo "⚠️ 未检测到容器"; sleep 1; menu ;;
    4) ${COMPOSE_CMD} -f ${COMPOSE_FILE} down --rmi all -v --remove-orphans || true; rm -rf ${CONFIG_DIR}; echo "✅ 已彻底删除。"; sleep 1; menu ;;
    5) docker logs -f hysteria || echo "⚠️ 未找到容器。"; menu ;;
    6) docker pull ghcr.io/cedar2025/hysteria:latest; ${COMPOSE_CMD} -f ${COMPOSE_FILE} up -d; echo "✅ 已更新镜像并重启。"; sleep 1; menu ;;
    7) exit 0 ;;
    *) echo "无效选项"; sleep 1; menu ;;
  esac
}

install_hysteria() {
  install_all
  mkdir -p "$CONFIG_DIR"

  echo "🚀 开始安装 Hysteria 对接 Xboard ..."
  read -rp "🧭 请输入 Xboard 面板地址 (如 https://xboard.example.com): " API_HOST
  read -rp "🔑 请输入通讯密钥 (apiKey): " API_KEY
  read -rp "🆔 请输入节点 ID (nodeID): " NODE_ID
  read -rp "🌐 请输入节点域名 (用于证书 CN): " DOMAIN
  read -rp "📡 请输入监听端口 (默认36024): " PORT
  PORT=${PORT:-36024}

  cat > ${CONFIG_DIR}/server.yaml <<EOF
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

  cat > ${COMPOSE_FILE} <<EOF
version: '3'
services:
  hysteria:
    image: ghcr.io/cedar2025/hysteria:latest
    container_name: hysteria
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - ${CONFIG_DIR}:/etc/hysteria
    command: server -c /etc/hysteria/server.yaml
EOF

  echo "📜 正在生成证书..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout ${CONFIG_DIR}/privkey.pem \
    -out ${CONFIG_DIR}/fullchain.pem \
    -subj "/C=CN/ST=Internet/L=Server/O=Hysteria/OU=AutoSign/CN=${DOMAIN}" >/dev/null 2>&1
  echo "✅ 证书已生成。"

  echo "🐳 启动容器..."
  ${COMPOSE_CMD} -f ${COMPOSE_FILE} up -d
  echo ""
  echo "✅ 部署完成！"
  echo "--------------------------------------"
  echo "📄 配置文件: /etc/hysteria/server.yaml"
  echo "🔑 私钥: ${CONFIG_DIR}/privkey.pem"
  echo "📜 公钥: ${CONFIG_DIR}/fullchain.pem"
  echo "⚙️ 监听端口: ${PORT} (UDP)"
  echo "🌐 面板地址: ${API_HOST}"
  echo "🆔 节点ID: ${NODE_ID}"
  echo "--------------------------------------"
  echo "📢 提示: 自签证书，客户端需关闭验证或导入信任。"
  sleep 2
  menu
}

menu
