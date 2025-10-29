#!/bin/bash
# =====================================================
# Hysteria 对接 XBoard 管理脚本（内置 ACME + 自签证书 + 强力卸载 + 临时目录修复）
# 版本: 2025-10-30
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
  echo "7 卸载 Docker 全部"
  echo "8 退出"
  echo "=============================="
}

# URL 编码防止特殊字符导致请求错误
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

# 修复 Docker 临时目录（解决 GetImageBlob 报错）
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

# 安装并确保 Docker 可用（静默安装）
install_docker() {
  echo "🧩 检查 Docker 环境..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 未检测到 Docker，正在静默安装..."
    curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
  else
    echo "✅ 已检测到 Docker"
  fi

  systemctl unmask docker docker.socket containerd >/dev/null 2>&1 || true
  systemctl enable docker.socket >/dev/null 2>&1 || true
  systemctl start docker.socket >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true

  if ! docker ps >/dev/null 2>&1; then
    echo "⚙️ 修复 Docker 服务状态..."
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl restart docker.socket 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true
  fi

  if ! docker ps >/dev/null 2>&1; then
    fix_docker_tmp
  fi

  if docker ps >/dev/null 2>&1; then
    echo "✅ Docker 已正常运行"
  else
    echo "❌ Docker 启动失败，请手动检查日志：journalctl -u docker -e"
    exit 1
  fi
}

# 拉镜像（失败则自动修 tmp 并重试）
docker_pull_safe() {
  local image="$1"
  if ! docker pull "$image" >/dev/null 2>&1; then
    echo "⚠️ 拉取镜像失败，尝试修复 Docker 临时目录后重试..."
    fix_docker_tmp
    docker pull "$image"
  fi
}

# 主安装逻辑
install_hysteria() {
  install_docker
  mkdir -p "$CONFIG_DIR"

  echo ""
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
    "${IMAGE}" >/dev/null 2>&1

  echo ""
  echo "✅ 部署完成"
  echo "--------------------------------------"
  echo "🌐 面板地址: ${API_HOST}"
  echo "🔑 通讯密钥(已编码): ${API_KEY}"
  echo "🆔 节点 ID: ${NODE_ID}"
  echo "🏷️ 节点域名: ${DOMAIN}"
  echo "📧 ACME 邮箱: ${EMAIL}"
  echo "📜 证书路径: ${CONFIG_DIR}/tls.crt"
  echo "🐳 容器名称: ${CONTAINER}"
  echo "--------------------------------------"
  pause
}

remove_container() {
  echo "⚠️ 确认删除 Hysteria 容器与配置？"
  read -rp "输入 y 继续: " c
  if [[ $c =~ ^[Yy]$ ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
    rm -rf "$CONFIG_DIR"
    echo "✅ 已删除容器与配置"
  fi
  pause
}

update_image() {
  docker_pull_safe "$IMAGE"
  docker restart "$CONTAINER" || true
  echo "✅ 镜像已更新并重启"
  pause
}

uninstall_docker_all() {
  echo "⚠️ 卸载 Docker 及全部组件"
  read -rp "确认继续？(y/n): " c
  [[ ! $c =~ ^[Yy]$ ]] && pause && return

  echo "🧹 停止所有 Docker 服务..."
  systemctl unmask docker docker.socket containerd >/dev/null 2>&1 || true
  systemctl stop docker docker.socket containerd 2>/dev/null || true
  systemctl disable docker docker.socket containerd 2>/dev/null || true
  pkill -f dockerd 2>/dev/null || true
  pkill -f containerd 2>/dev/null || true

  echo "🧹 删除容器/镜像/卷/网络..."
  if command -v docker >/dev/null 2>&1; then
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker rmi -f $(docker images -aq) 2>/dev/null || true
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    docker network rm $(docker network ls -q | grep -vE '(^ID$|bridge|host|none)') 2>/dev/null || true
    docker system prune -af --volumes 2>/dev/null || true
  fi

  echo "🧹 清理文件与目录..."
  rm -rf /etc/hysteria /etc/docker /var/lib/docker /var/lib/containerd ~/.docker
  rm -rf /run/docker* /run/containerd*
  rm -rf /lib/systemd/system/docker* /etc/systemd/system/docker* /usr/lib/systemd/system/docker*

  echo "🧹 卸载相关包..."
  apt purge -y docker docker.io docker-engine docker-compose docker-compose-plugin containerd runc >/dev/null 2>&1 || true
  apt autoremove -y >/dev/null 2>&1 || true
  systemctl daemon-reexec
  systemctl daemon-reload

  if command -v docker >/dev/null 2>&1; then
    echo "🧹 移除 docker 可执行文件..."
    rm -f "$(command -v docker)" 2>/dev/null || true
  fi

  echo "✅ Docker 已彻底卸载，无残留"
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
