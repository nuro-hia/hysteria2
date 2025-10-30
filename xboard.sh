#!/bin/bash
# =====================================================
# Hysteria 对接 XBoard 管理脚本（自签证书 + 禁用 ACME）
# 适配 ghcr.io/cedar2025/hysteria:latest
# 版本：2025-10-30
# =====================================================

set -euo pipefail
CONFIG_DIR="/etc/hysteria"
IMAGE="ghcr.io/cedar2025/hysteria:latest"
CONTAINER="hysteria"
ENTRYPOINT_FIX="${CONFIG_DIR}/run.sh"

pause() { echo ""; read -rp "按回车返回菜单..." _; menu; }

header() {
  clear
  echo "=============================="
  echo " Hysteria 对接 XBoard 管理脚本1"
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
  docker ps >/dev/null 2>&1 && echo "✅ Docker 已正常运行" || { echo "❌ Docker 启动失败"; exit 1; }
}

# ---------- 生成修复版 entrypoint ----------
generate_entrypoint_fix() {
  mkdir -p "$CONFIG_DIR"
  cat >"$ENTRYPOINT_FIX" <<'EOF'
#!/bin/sh
CONFIG_FILE="/etc/hysteria/server.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Creating configuration file $CONFIG_FILE"
  mkdir -p /etc/hysteria
  cat <<CONF >"$CONFIG_FILE"
v2board:
  apiHost: ${apiHost}
  apiKey: ${apiKey}
  nodeID: ${nodeID}
tls:
  cert: ${tlsCert}
  key: ${tlsKey}
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
CONF
fi

exec hysteria server -c "$CONFIG_FILE"
EOF
  chmod +x "$ENTRYPOINT_FIX"
}

# ---------- 安装 Hysteria ----------
install_hysteria() {
  install_docker
  mkdir -p "$CONFIG_DIR"

  echo ""
  read -rp "🌐 面板地址(XBoard): " API_HOST
  read -rp "🔑 通讯密钥(apiKey): " RAW_API_KEY
  read -rp "🆔 节点 ID(nodeID): " NODE_ID
  read -rp "🏷️ 节点域名(CN): " DOMAIN
  read -rp "🔊 监听端口(默认: 443): " PORT
  PORT=${PORT:-443}
  API_KEY=$(urlencode "$RAW_API_KEY")

  echo ""
  echo "📜 生成自签证书..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CONFIG_DIR/tls.key" -out "$CONFIG_DIR/tls.crt" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  echo "✅ 自签证书生成成功：$CONFIG_DIR/tls.crt"

  generate_entrypoint_fix

  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker pull "$IMAGE" >/dev/null 2>&1 || true

  echo "🐳 启动 Hysteria 容器..."
  docker run -itd --restart=always --network=host \
    -v "${CONFIG_DIR}:/etc/hysteria" \
    -v "${ENTRYPOINT_FIX}:/entrypoint/run.sh" \
    -e apiHost="${API_HOST}" \
    -e apiKey="${API_KEY}" \
    -e nodeID="${NODE_ID}" \
    -e tlsCert="/etc/hysteria/tls.crt" \
    -e tlsKey="/etc/hysteria/tls.key" \
    -e disableVerify=true \
    -e listen=":${PORT}" \
    --name "${CONTAINER}" \
    "${IMAGE}"

  echo ""
  echo "✅ 部署完成（使用自签证书，无 ACME）"
  echo "--------------------------------------"
  echo "🌐 面板地址: ${API_HOST}"
  echo "🔑 通讯密钥(已编码): ${API_KEY}"
  echo "🆔 节点 ID: ${NODE_ID}"
  echo "🏷️ 域名: ${DOMAIN}"
  echo "📜 证书路径: ${CONFIG_DIR}/tls.crt"
  echo "📡 监听端口: ${PORT}"
  echo "🐳 容器名称: ${CONTAINER}"
  echo "--------------------------------------"
  pause
}

# ---------- 删除容器 ----------
remove_container() {
  echo "⚠️ 确认删除容器与配置？(y/n)"
  read -r c
  [[ $c =~ ^[Yy]$ ]] || { pause; return; }
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$CONFIG_DIR"
  echo "✅ 已删除容器与配置"
  pause
}

# ---------- 更新镜像 ----------
update_image() {
  docker pull "$IMAGE" >/dev/null 2>&1
  docker restart "$CONTAINER" || true
  echo "✅ 镜像已更新并重启"
  pause
}

# ---------- 卸载 Docker ----------
uninstall_docker_all() {
  echo ""
  echo "⚠️ 卸载 Docker 与所有组件"
  echo "--------------------------------------"
  read -rp "确认继续？(y/n): " c
  [[ ! $c =~ ^[Yy]$ ]] && pause && return

  echo "🧹 停止并删除容器..."
  docker stop $(docker ps -aq) 2>/dev/null || true
  docker rm -f $(docker ps -aq) 2>/dev/null || true

  echo "🧹 删除镜像与卷..."
  docker rmi -f $(docker images -q) 2>/dev/null || true
  docker volume rm $(docker volume ls -q) 2>/dev/null || true
  docker network prune -f >/dev/null 2>&1 || true

  echo "🧹 卸载 Docker 包..."
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true

  echo "🧹 清理残留文件..."
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker ~/.docker >/dev/null 2>&1
  rm -f /usr/local/bin/docker-compose >/dev/null 2>&1
  echo ""
  echo "✅ 已完全卸载！"
  echo "--------------------------------------"
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
