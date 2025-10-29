#!/bin/bash
# ============================================================
# Hysteria + Xboard 一键部署与管理脚本
# 作者: nuro
# 仓库: https://github.com/nixore-run/manager-script
# ============================================================

set -e
CONFIG_DIR="/etc/hysteria"
COMPOSE_FILE="${CONFIG_DIR}/docker-compose.yml"

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
    2) restart_hysteria ;;
    3) stop_hysteria ;;
    4) remove_hysteria ;;
    5) view_logs ;;
    6) update_image ;;
    7) exit 0 ;;
    *) echo "无效选项"; sleep 1; menu ;;
  esac
}

install_hysteria() {
  echo "🚀 开始安装 Hysteria 对接 Xboard ..."
  read -rp "🧭 请输入 Xboard 面板地址 (如 https://xboard.example.com): " API_HOST
  read -rp "🔑 请输入通讯密钥 (apiKey): " API_KEY
  read -rp "🆔 请输入节点 ID (nodeID): " NODE_ID
  read -rp "🌐 请输入节点域名 (证书域名): " DOMAIN
  read -rp "📡 请输入监听端口 (默认36024): " PORT
  PORT=${PORT:-36024}

  mkdir -p "$CONFIG_DIR"

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

  echo "🔒 检查证书..."
  if [[ ! -f "${CONFIG_DIR}/fullchain.pem" || ! -f "${CONFIG_DIR}/privkey.pem" ]]; then
      echo "⚠️ 未检测到证书，准备申请中..."
      curl https://get.acme.sh | sh
      ~/.acme.sh/acme.sh --issue -d ${DOMAIN} --standalone
      ~/.acme.sh/acme.sh --install-cert -d ${DOMAIN} \
          --key-file ${CONFIG_DIR}/privkey.pem \
          --fullchain-file ${CONFIG_DIR}/fullchain.pem
  fi

  echo "🐳 启动容器..."
  docker compose -f ${COMPOSE_FILE} up -d
  echo "✅ 部署完成！"
  echo "--------------------------------------"
  echo "📄 配置文件: /etc/hysteria/server.yaml"
  echo "⚙️ 监听端口: ${PORT} (UDP)"
  echo "🌐 面板: ${API_HOST}"
  echo "🆔 节点ID: ${NODE_ID}"
  echo "--------------------------------------"
  echo "日志查看: docker logs -f hysteria"
  sleep 2
  menu
}

restart_hysteria() {
  echo "🔄 正在重启容器..."
  docker compose -f ${COMPOSE_FILE} restart
  echo "✅ 已重启。"
  sleep 1
  menu
}

stop_hysteria() {
  echo "🛑 停止容器..."
  docker compose -f ${COMPOSE_FILE} down
  echo "✅ 已停止。"
  sleep 1
  menu
}

remove_hysteria() {
  echo "⚠️ 该操作将删除容器和配置！"
  read -rp "确认删除？(y/N): " confirm
  if [[ $confirm =~ ^[Yy]$ ]]; then
    docker compose -f ${COMPOSE_FILE} down --rmi all -v --remove-orphans || true
    rm -rf ${CONFIG_DIR}
    echo "✅ 已彻底删除。"
  fi
  sleep 1
  menu
}

view_logs() {
  echo "📜 正在查看日志 (Ctrl+C 退出)..."
  docker logs -f hysteria || echo "未找到容器。"
  menu
}

update_image() {
  echo "⬆️ 拉取最新镜像并重启..."
  docker pull ghcr.io/cedar2025/hysteria:latest
  docker compose -f ${COMPOSE_FILE} up -d
  echo "✅ 镜像已更新并重启完成。"
  sleep 1
  menu
}

menu
