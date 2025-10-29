#!/bin/bash
# =====================================================
# Hysteria 对接 XBoard 管理脚本（彻底卸载 + 重装修复）
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

# ========== URL 编码 ==========
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

# ========== 修复临时目录 ==========
fix_docker_tmp() {
  local root_dir
  root_dir=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
  echo "🛠️ 修复 Docker 临时目录: ${root_dir}/tmp"
  systemctl stop docker 2>/dev/null || true
  mkdir -p "${root_dir}/tmp"
  chmod 1777 "${root_dir}/tmp"
  rm -rf "${root_dir}/tmp/"* 2>/dev/null || true
  export DOCKER_TMPDIR="${root_dir}/tmp"
  systemctl restart containerd 2>/dev/null || true
  systemctl start docker 2>/dev/null || true
}

# ========== Docker 安装（自动修复） ==========
install_docker() {
  echo "🧩 检查 Docker 环境..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
  fi

  # 尝试修复 masked 服务
  systemctl unmask docker docker.socket containerd >/dev/null 2>&1 || true
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable docker.socket >/dev/null 2>&1 || true
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker.socket >/dev/null 2>&1 || true
  systemctl start containerd >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true

  # 如果还是不行，则重新安装
  if ! docker ps >/dev/null 2>&1; then
    echo "⚙️ Docker 启动异常，尝试彻底修复..."
    uninstall_docker_core
    curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
    systemctl enable docker --now >/dev/null 2>&1
  fi

  # 最后再检查
  if docker ps >/dev/null 2>&1; then
    echo "✅ Docker 已正常运行"
  else
    echo "❌ Docker 启动失败，请执行: journalctl -xeu docker"
    exit 1
  fi
}

# ========== 卸载核心（含挂载修复） ==========
uninstall_docker_core() {
  echo "🧹 停止所有 Docker 服务..."
  systemctl stop docker docker.socket containerd 2>/dev/null || true
  pkill -9 docker containerd dockerd 2>/dev/null || true

  echo "🧹 卸载 Docker 包..."
  apt purge -y docker docker.io docker-ce docker-ce-cli docker-compose docker-compose-plugin containerd runc >/dev/null 2>&1 || true
  apt autoremove -y >/dev/null 2>&1 || true
  apt clean >/dev/null 2>&1 || true

  echo "🧹 卸载挂载..."
  mount | grep "/run/docker" | awk '{print $3}' | while read -r m; do
    umount -lf "$m" 2>/dev/null || true
  done

  echo "🧹 删除目录..."
  rm -rf /etc/docker /var/lib/docker /var/lib/containerd ~/.docker
  rm -rf /run/docker* /run/containerd*
  rm -rf /lib/systemd/system/docker* /etc/systemd/system/docker* /usr/lib/systemd/system/docker*
  rm -f /usr/bin/docker /usr/local/bin/docker /usr/sbin/containerd /usr/bin/containerd-shim*

  echo "🧹 重载 systemd..."
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl reset-failed
}

# ========== 一键彻底卸载 ==========
uninstall_docker_all() {
  echo "⚠️ 确认要彻底卸载 Docker？(y/n)"
  read -r c
  [[ ! $c =~ ^[Yy]$ ]] && pause && return

  uninstall_docker_core
  echo "✅ Docker 已彻底卸载，无残留"
  pause
}

# ========== 安装并启动 ==========
install_hysteria() {
  install_docker
  mkdir -p "$CONFIG_DIR"

  read -rp "🌐 面板地址(如 https://mist.mistea.link): " API_HOST
  read -rp "🔑 通讯密钥(apiKey): " RAW_API_KEY
  read -rp "🆔 节点 ID(nodeID): " NODE_ID
  read -rp "🏷️ 节点域名(证书 CN): " DOMAIN
  read -rp "📧 ACME 注册邮箱(默认: ${DEFAULT_EMAIL}): " EMAIL
  EMAIL=${EMAIL:-$DEFAULT_EMAIL}
  API_KEY=$(urlencode "$RAW_API_KEY")

  echo "📜 生成自签证书..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CONFIG_DIR/tls.key" -out "$CONFIG_DIR/tls.crt" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1 || true
  echo "✅ 自签证书生成成功"

  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  echo "🐳 拉取镜像..."
  docker pull "$IMAGE" >/dev/null 2>&1 || fix_docker_tmp && docker pull "$IMAGE" >/dev/null 2>&1

  echo "🚀 启动 Hysteria..."
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
    --name "${CONTAINER}" "${IMAGE}" >/dev/null 2>&1 || true

  echo "✅ 部署完成"
  echo "--------------------------------------"
  echo "🌐 面板地址: ${API_HOST}"
  echo "🔑 通讯密钥(已编码): ${API_KEY}"
  echo "🆔 节点 ID: ${NODE_ID}"
  echo "🏷️ 节点域名: ${DOMAIN}"
  echo "📧 ACME 邮箱: ${EMAIL}"
  echo "🐳 容器名称: ${CONTAINER}"
  echo "📜 配置目录: ${CONFIG_DIR}"
  echo "--------------------------------------"
  pause
}

remove_container() {
  echo "⚠️ 确认删除容器与配置？(y/n)"
  read -r c
  [[ ! $c =~ ^[Yy]$ ]] && pause && return
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$CONFIG_DIR"
  echo "✅ 已删除容器与配置"
  pause
}

update_image() {
  docker pull "$IMAGE" >/dev/null 2>&1 || fix_docker_tmp && docker pull "$IMAGE" >/dev/null 2>&1
  docker restart "$CONTAINER" || true
  echo "✅ 镜像已更新并重启"
  pause
}

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
