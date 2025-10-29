#!/bin/bash
# ============================================================
# Hysteria 对接 XBoard 一键部署脚本（ENJOY版）
# 作者: nuro
# 更新: 2025-10-30
# 特性: emoji输入提示 + 智能卸载逻辑
# ============================================================

set -e
CONFIG_DIR="/etc/hysteria"
COMPOSE_FILE="${CONFIG_DIR}/docker-compose.yml"
COMPOSE_CMD=""

# ------------------------------------------------------------
# 检查 Docker 与 Compose
# ------------------------------------------------------------
install_docker() {
  echo "🧩 检查 Docker 环境..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker --now
    echo "✅ Docker 安装完成"
  else
    echo "✅ 已检测到 Docker"
  fi

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    echo "📦 未检测到 Docker Compose，正在安装..."
    apt update -y && apt install -y docker-compose-plugin docker-compose
    if docker compose version >/dev/null 2>&1; then
      COMPOSE_CMD="docker compose"
    else
      COMPOSE_CMD="docker-compose"
    fi
  fi
  echo "✅ 使用 Compose 命令: ${COMPOSE_CMD}"
}

pause() {
  echo ""
  read -rp "💤 按回车返回菜单..." _
  menu
}

# ------------------------------------------------------------
# 菜单
# ------------------------------------------------------------
menu() {
  clear
  echo "=============================="
  echo " 🌐 Hysteria 对接 XBoard 管理脚本"
  echo "=============================="
  echo "1 🚀 安装并部署 Hysteria"
  echo "2 🔁 重启容器"
  echo "3 📴 停止容器"
  echo "4 🗑️ 删除容器与配置"
  echo "5 📄 查看运行日志"
  echo "6 🔄 更新镜像"
  echo "7 💣 卸载全部"
  echo "8 ❌ 退出"
  echo "=============================="
  read -rp "请选择操作: " choice
  case $choice in
    1) install_hysteria ;;
    2) ${COMPOSE_CMD} -f ${COMPOSE_FILE} restart || echo "⚠️ 未找到容器"; pause ;;
    3) ${COMPOSE_CMD} -f ${COMPOSE_FILE} down || echo "⚠️ 未找到容器"; pause ;;
    4) remove_hysteria ;;
    5) docker logs -f hysteria || echo "⚠️ 未找到容器"; pause ;;
    6) update_image ;;
    7) uninstall_all ;;
    8) exit 0 ;;
    *) echo "❌ 无效选项"; sleep 1; menu ;;
  esac
}

# ------------------------------------------------------------
# 安装与部署
# ------------------------------------------------------------
install_hysteria() {
  install_docker
  mkdir -p "$CONFIG_DIR"

  echo ""
  read -rp "🌐 面板地址: " API_HOST
  read -rp "🔑 通讯密钥: " API_KEY
  read -rp "🆔 节点 ID: " NODE_ID
  read -rp "🏷️  节点域名 (证书 CN): " DOMAIN
  read -rp "📡 监听端口 (默认36024): " PORT
  PORT=${PORT:-36024}

  # 写配置文件
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

  # 写 docker-compose.yml
  cat > ${COMPOSE_FILE} <<EOF
version: "3"
services:
  hysteria:
    image: ghcr.io/cedar2025/hysteria:latest
    container_name: hysteria
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - ${CONFIG_DIR}:/etc/hysteria
    command: hysteria server -c /etc/hysteria/server.yaml
EOF

  echo ""
  echo "📜 正在生成自签证书..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout ${CONFIG_DIR}/privkey.pem \
    -out ${CONFIG_DIR}/fullchain.pem \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  echo "✅ 证书生成成功"

  echo ""
  echo "🐳 启动容器..."
  ${COMPOSE_CMD} -f ${COMPOSE_FILE} up -d

  echo ""
  echo "✅ 部署完成"
  echo "--------------------------------------"
  echo "📄 配置文件: /etc/hysteria/server.yaml"
  echo "🔐 证书文件: ${CONFIG_DIR}/fullchain.pem"
  echo "📡 监听端口: ${PORT} (UDP)"
  echo "--------------------------------------"
  pause
}

# ------------------------------------------------------------
# 删除与更新
# ------------------------------------------------------------
remove_hysteria() {
  echo "⚠️ 确认要删除 Hysteria 容器与配置吗？"
  read -rp "输入 y 继续: " confirm
  if [[ $confirm =~ ^[Yy]$ ]]; then
    ${COMPOSE_CMD} -f ${COMPOSE_FILE} down --rmi all -v --remove-orphans || true
    docker rm -f hysteria >/dev/null 2>&1 || true
    docker rmi ghcr.io/cedar2025/hysteria:latest >/dev/null 2>&1 || true
    rm -rf ${CONFIG_DIR}
    echo "✅ 已删除容器与配置"
  fi
  pause
}

update_image() {
  docker pull ghcr.io/cedar2025/hysteria:latest
  ${COMPOSE_CMD} -f ${COMPOSE_FILE} up -d
  echo "✅ 镜像已更新"
  pause
}

# ------------------------------------------------------------
# 卸载逻辑：安全检查 + 条件删除 Docker
# ------------------------------------------------------------
uninstall_all() {
  echo "⚠️ 将卸载 Hysteria 容器与 Docker"
  read -rp "确认继续? y/n: " confirm
  if [[ $confirm =~ ^[Yy]$ ]]; then
    echo "🗑️ 正在清理 Hysteria..."
    docker rm -f hysteria >/dev/null 2>&1 || true
    docker rmi ghcr.io/cedar2025/hysteria:latest >/dev/null 2>&1 || true
    rm -rf ${CONFIG_DIR}

    local other_containers=$(docker ps -aq | grep -v "$(docker ps -aq --filter name=hysteria)" || true)
    if [[ -z "$other_containers" ]]; then
      echo "🧹 未检测到其他容器，开始卸载 Docker..."
      apt purge -y docker docker.io docker-compose docker-compose-plugin containerd runc >/dev/null 2>&1
      rm -rf /var/lib/docker /var/lib/containerd /etc/docker
      echo "✅ 已彻底卸载所有组件"
    else
      echo "⚙️ 检测到其他容器存在，已保留 Docker 环境"
    fi
  fi
  pause
}

menu
