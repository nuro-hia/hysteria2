#!/bin/bash
# =====================================================
# Hysteria 对接 XBoard 管理脚本（含彻底卸载版）
# 版本：2025-10-30
# =====================================================

set -euo pipefail
CONFIG_DIR="/etc/hysteria"
IMAGE="ghcr.io/cedar2025/hysteria:latest"
CONTAINER="hysteria"
DEFAULT_EMAIL="his666@outlook.com"

pause() { echo ""; read -rp "按回车返回菜单..." _; menu; }

header() {
  clear
  echo "=============================="
  echo " Hysteria 对接 XBoard 管理脚本"
  echo "=============================="
  echo "1 安装并启动 Hysteria"
  echo "2 重启容器"
  echo "3 停止容器"
  echo "4 删除容器与配置"
  echo "5 查看运行日志"
  echo "6 更新镜像"
  echo "7 卸载并彻底清理 Docker"
  echo "8 退出"
  echo "=============================="
}

# ---------- URL 编码 ----------
urlencode() {
  local data="$1" output="" c
  for ((i=0; i<${#data}; i++)); do
    c=${data:$i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) output+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; output+="$hex" ;;
    esac
  done
  echo "$output"
}

# ---------- 安装 Docker ----------
install_docker() {
  echo "🧩 检查 Docker 环境..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 未检测到 Docker，正在安装..."
    apt update -y >/dev/null 2>&1
    apt install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt update -y >/dev/null 2>&1
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
    systemctl enable docker --now >/dev/null 2>&1
  fi

  if docker ps >/dev/null 2>&1; then
    echo "✅ Docker 已正常运行"
  else
    echo "❌ Docker 启动失败，请执行：journalctl -u docker -e"
    exit 1
  fi
}

# ---------- 拉镜像 ----------
docker_pull_safe() {
  local image="$1"
  docker pull "$image" >/dev/null 2>&1 || {
    echo "⚠️ 拉取失败，尝试清理临时目录..."
    rm -rf /var/lib/docker/tmp/* 2>/dev/null || true
    docker pull "$image"
  }
}

# ---------- 安装 Hysteria ----------
install_hysteria() {
  install_docker
  mkdir -p "$CONFIG_DIR"

  echo ""
  read -rp "🌐 面板地址(Xboard 官网): " API_HOST
  read -rp "🔑 通讯密钥(apiKey): " RAW_API_KEY
  read -rp "🆔 节点 ID(nodeID): " NODE_ID
  read -rp "🏷️ 节点域名(证书 CN): " DOMAIN
  read -rp "📧 ACME 邮箱(默认: ${DEFAULT_EMAIL}): " EMAIL
  EMAIL=${EMAIL:-$DEFAULT_EMAIL}
  API_KEY=$(urlencode "$RAW_API_KEY")

  echo "📜 生成自签证书..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CONFIG_DIR/tls.key" -out "$CONFIG_DIR/tls.crt" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  echo "✅ 自签证书生成成功"

  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker_pull_safe "$IMAGE"

  echo "🐳 启动 Hysteria 容器..."
  docker run -itd --restart=always --network=host \
    -v "${CONFIG_DIR}:/etc/hysteria" \
    -e apiHost="${API_HOST}" \
    -e apiKey="${API_KEY}" \
    -e nodeID="${NODE_ID}" \
    -e domain="${DOMAIN}" \
    -e acmeDomains="${DOMAIN}" \
    -e acmeEmail="${EMAIL}" \
    -e tlsCert="/etc/hysteria/tls.crt" \
    -e tlsKey="/etc/hysteria/tls.key" \
    --name "${CONTAINER}" \
    "${IMAGE}"

  echo ""
  echo "✅ 部署完成"
  echo "--------------------------------------"
  echo "🌐 面板地址: ${API_HOST}"
  echo "🔑 通讯密钥: ${API_KEY}"
  echo "🆔 节点 ID: ${NODE_ID}"
  echo "🏷️ 节点域名: ${DOMAIN}"
  echo "📧 ACME 邮箱: ${EMAIL}"
  echo "📜 证书路径: ${CONFIG_DIR}/tls.crt"
  echo "🐳 容器名称: ${CONTAINER}"
  echo "--------------------------------------"
  pause
}

# ---------- 删除容器 ----------
remove_container() {
  echo "⚠️ 确认删除容器与配置？(y/n)"
  read -r c
  if [[ $c =~ ^[Yy]$ ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
    rm -rf "$CONFIG_DIR"
    echo "✅ 已删除容器与配置"
  fi
  pause
}

# ---------- 更新镜像 ----------
update_image() {
  docker_pull_safe "$IMAGE"
  docker restart "$CONTAINER" || true
  echo "✅ 镜像已更新并重启"
  pause
}

# ---------- 卸载 Docker ----------
uninstall_docker_all() {
  echo "⚠️ 卸载 Docker 与所有组件"
  read -rp "确认继续？(y/n): " c
  [[ ! $c =~ ^[Yy]$ ]] && pause && return

  sudo docker stop $(sudo docker ps -aq) 2>/dev/null || true
  sudo docker rm -f $(sudo docker ps -aq) 2>/dev/null || true
  sudo docker rmi -f $(sudo docker images -q) 2>/dev/null || true
  sudo docker volume rm $(sudo docker volume ls -q) 2>/dev/null || true
  sudo docker network prune -f 2>/dev/null || true

  if command -v apt-get &>/dev/null; then
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
    sudo apt-get autoremove -y --purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
  elif command -v yum &>/dev/null; then
    sudo systemctl stop docker 2>/dev/null
    sudo yum remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
  elif command -v dnf &>/dev/null; then
    sudo systemctl stop docker 2>/dev/null
    sudo dnf remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
  fi

  sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker ~/.docker
  sudo rm -f /usr/local/bin/docker-compose
  sudo pip uninstall -y docker-compose 2>/dev/null || true

  if ! command -v docker &>/dev/null && ! command -v docker-compose &>/dev/null; then
    echo "✅ Docker 与 docker-compose 已完全卸载！"
  else
    echo "⚠️ 仍检测到部分组件，请手动检查："
    which docker || true
    which docker-compose || true
  fi
  pause
}

# ---------- 菜单 ----------
menu() {
  header
  read -rp "请选择操作: " opt
  case "$opt" in
    1) install_hysteria ;;
    2) docker restart "$CONTAINER" || echo "⚠️ 未找到容器"; pause ;;
    3) docker stop "$CONTAINER" || echo "⚠️ 未找到容器"; pause ;;
    4) remove_container ;;
    5) docker logs -f "$CONTAINER" || echo "⚠️ 未找到容器"; pause ;;
    6) update_image ;;
    7) uninstall_docker_all ;;
    8) exit 0 ;;
    *) echo "❌ 无效选项"; sleep 1; menu ;;
  esac
}

menu
