#!/bin/bash
# =====================================================
# 🌀 Hysteria 对接 XBoard 管理脚本（内置自签证书 + 完整卸载Docker）
# 作者: nuro | 版本: 2025-10-30
# =====================================================

set -e
CONFIG_DIR="/etc/hysteria"
IMAGE="ghcr.io/cedar2025/hysteria:latest"
CONTAINER="hysteria"

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

# -------------------------------
# URL 编码函数
# -------------------------------
urlencode() {
  local data="$1" output="" c
  for ((i=0; i<${#data}; i++)); do
    c=${data:$i:1}
    case $c in
      [a-zA-Z0-9.~_-]) output+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; output+="$hex" ;;
    esac
  done
  echo "$output"
}

# -------------------------------
# 安装 Docker
# -------------------------------
install_docker() {
  echo "🧩 检查 Docker 环境..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | bash
  else
    echo "✅ 已检测到 Docker"
  fi

  # 修复 masked 状态
  systemctl unmask docker docker.socket containerd >/dev/null 2>&1 || true
  systemctl enable docker.socket >/dev/null 2>&1 || true
  systemctl start docker.socket >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true

  if ! docker ps >/dev/null 2>&1; then
    echo "⚙️ 修复 Docker 服务状态..."
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl restart docker.socket || true
    systemctl restart docker || true
  fi

  docker ps >/dev/null 2>&1 && echo "✅ Docker 已正常运行"
}

# -------------------------------
# 安装 Hysteria
# -------------------------------
install_hysteria() {
  install_docker
  mkdir -p "$CONFIG_DIR"

  echo ""
  read -rp "🌐 面板地址(如 https://mist.mistea.link): " API_HOST
  read -rp "🔑 通讯密钥(apiKey): " RAW_API_KEY
  read -rp "🆔 节点 ID(nodeID): " NODE_ID
  read -rp "🏷️ 节点域名(证书 CN): " DOMAIN
  read -rp "📧 ACME 注册邮箱(可随意填写): " EMAIL

  API_KEY=$(urlencode "$RAW_API_KEY")

  echo "📜 生成自签证书..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CONFIG_DIR/tls.key" -out "$CONFIG_DIR/tls.crt" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  echo "✅ 自签证书生成成功"

  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker pull "$IMAGE" || true

  echo "🐳 启动 Hysteria 容器..."
  docker run -itd --restart=always --network=host \
    -v "${CONFIG_DIR}:/etc/hysteria" \
    -e apiHost="${API_HOST}" \
    -e apiKey="${API_KEY}" \
    -e nodeID="${NODE_ID}" \
    -e domain="${DOMAIN}" \
    -e acmeEmail="${EMAIL}" \
    -e tlsCert="/etc/hysteria/tls.crt" \
    -e tlsKey="/etc/hysteria/tls.key" \
    --name "${CONTAINER}" \
    "${IMAGE}"

  echo ""
  echo "✅ 部署完成"
  echo "--------------------------------------"
  echo "🌐 面板地址: ${API_HOST}"
  echo "🔑 通讯密钥(已编码): ${API_KEY}"
  echo "🆔 节点 ID: ${NODE_ID}"
  echo "🏷️ 节点域名: ${DOMAIN}"
  echo "📜 证书路径: ${CONFIG_DIR}/tls.crt"
  echo "🐳 容器名称: ${CONTAINER}"
  echo "--------------------------------------"
  pause
}

# -------------------------------
# 删除容器与配置
# -------------------------------
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

# -------------------------------
# 更新镜像
# -------------------------------
update_image() {
  docker pull "$IMAGE"
  docker restart "$CONTAINER" || true
  echo "✅ 镜像已更新并重启"
  pause
}

# -------------------------------
# 完整卸载 Docker
# -------------------------------
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

  echo "🧹 删除容器、镜像、卷、网络..."
  if command -v docker >/dev/null 2>&1; then
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker rmi -f $(docker images -aq) 2>/dev/null || true
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    docker network rm $(docker network ls -q | grep -vE 'bridge|host|none') 2>/dev/null || true
    docker system prune -af --volumes 2>/dev/null || true
  fi

  echo "🧹 清理所有文件..."
  rm -rf /etc/docker /var/lib/docker /var/lib/containerd ~/.docker /etc/hysteria
  rm -rf /lib/systemd/system/docker* /etc/systemd/system/docker* /usr/lib/systemd/system/docker*
  rm -rf /run/docker* /run/containerd*

  echo "🧹 卸载软件包..."
  apt purge -y docker docker.io docker-engine docker-compose docker-compose-plugin containerd runc >/dev/null 2>&1 || true
  apt autoremove -y >/dev/null 2>&1 || true

  systemctl daemon-reexec
  systemctl daemon-reload
  echo "✅ Docker 已彻底卸载"

  # 验证残留
  if command -v docker >/dev/null 2>&1; then
    echo "⚠️ 检测到 docker 可执行文件，强制删除..."
    rm -f "$(command -v docker)"
  fi
  echo "🎯 检查残留服务..."
  systemctl list-unit-files | grep docker || echo "✅ 无 Docker 相关服务"
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
