#!/bin/bash
# =====================================================
# Hysteria 对接 XBoard 管理脚本
# =====================================================

set -euo pipefail
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/server.yaml"
LOG_FILE="/var/log/hysteria.log"
IMAGE="ghcr.io/cedar2025/hysteria:latest"
CONTAINER="hysteria"

pause(){ echo ""; read -rp "按回车返回菜单..." _; menu; }

header(){
  clear
  echo "=============================="
  echo " Hysteria 对接 XBoard 管理脚本 v1"
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

urlencode(){
  local data="$1" out="" c
  for ((i=0; i<${#data}; i++)); do
    c=${data:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  echo "$out"
}

yaml_quote(){
  local s="${1//\'/\'\'}"
  printf "'%s'" "$s"
}

rand_port(){
  local p
  while :; do
    p=$((200 + RANDOM % 800))
    [[ "$p" -ne 443 ]] && { echo "$p"; return; }
  done
}

install_docker(){
  echo "🧩 检查 Docker 环境..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 未检测到 Docker，正在安装..."
    apt update -y >/dev/null 2>&1
    apt install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
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

docker_pull_safe(){
  local image="$1"
  docker pull "$image" >/dev/null 2>&1 || {
    echo "⚠️ 拉取失败，尝试清理临时目录后重试..."
    rm -rf /var/lib/docker/tmp/* 2>/dev/null || true
    docker pull "$image"
  }
}

gen_self_signed(){
  mkdir -p "$CONFIG_DIR"
  local domain="$1"
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CONFIG_DIR/tls.key" -out "$CONFIG_DIR/tls.crt" \
    -subj "/CN=${domain}" >/dev/null 2>&1
  echo "✅ 自签证书生成成功：$CONFIG_DIR/tls.crt"
}

write_server_yaml(){
  local api_host="$1"
  local api_key_enc="$2"
  local node_id="$3"
  local domain="$4"
  local listen_port="$5"

  local api_key_yaml
  api_key_yaml=$(yaml_quote "$api_key_enc")

  cat > "$CONFIG_FILE" <<EOF
v2board:
  apiHost: ${api_host}
  apiKey: ${api_key_yaml}
  nodeID: ${node_id}

tls:
  type: tls
  cert: /etc/hysteria/tls.crt
  key: /etc/hysteria/tls.key

auth:
  type: v2board

listen: :${listen_port}

log:
  level: info
  file: /var/log/hysteria.log

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  congestionControl: bbr
  maxIdleTimeout: 30s

trafficStats:
  listen: 127.0.0.1:7653

acl:
  inline:
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(127.0.0.0/8)
    - reject(fc00::/7)
EOF
  echo "✅ 已写入优化配置：$CONFIG_FILE"
}

setup_log_rotation(){
  cat > /etc/cron.daily/hysteria_log_clean <<EOF
#!/bin/bash
LOG_FILE="/var/log/hysteria.log"
MAX_LINES=100
if [ -f "\$LOG_FILE" ]; then
  LINES=\$(wc -l < "\$LOG_FILE")
  if [ "\$LINES" -gt "\$MAX_LINES" ]; then
    tail -n \$MAX_LINES "\$LOG_FILE" > "\${LOG_FILE}.tmp" && mv "\${LOG_FILE}.tmp" "\$LOG_FILE"
  fi
fi
EOF
  chmod +x /etc/cron.daily/hysteria_log_clean
  echo "🧹 已设置每日自动清理日志任务 (保留 100 行)"
}

install_hysteria(){
  install_docker
  mkdir -p "$CONFIG_DIR"

  echo ""
  read -rp "🌐 面板地址(XBoard): " API_HOST
  read -rp "🔑 通讯密钥(apiKey): " RAW_API_KEY
  read -rp "🆔 节点 ID(nodeID): " NODE_ID
  read -rp "🏷️ 节点域名(证书 CN): " DOMAIN
  read -rp "🎯 自定义端口 (留空则自动从面板获取): " CUSTOM_PORT

  API_KEY_ENC="$(urlencode "$RAW_API_KEY")"

  # === 尝试自动获取端口 ===
  echo "🔍 正在尝试从面板获取节点端口..."
  PANEL_PORT=$(curl -fsSL "${API_HOST}/api/v1/server/UniConfig?node_id=${NODE_ID}" \
    -H "Authorization: Bearer ${RAW_API_KEY}" | grep -oP '"port":\K\d+' || true)

  if [[ -n "$PANEL_PORT" ]]; then
    PORT="$PANEL_PORT"
    echo "🎯 成功获取面板端口: ${PORT}"
  elif [[ -n "$CUSTOM_PORT" ]]; then
    PORT="$CUSTOM_PORT"
    echo "🎯 使用自定义端口: ${PORT}"
  else
    PORT="$(rand_port)"
    echo "⚠️ 面板未返回端口，已自动分配随机端口: ${PORT}"
  fi

  # === 生成证书与配置 ===
  gen_self_signed "$DOMAIN"
  write_server_yaml "$API_HOST" "$API_KEY_ENC" "$NODE_ID" "$DOMAIN" "$PORT"
  setup_log_clean

  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker_pull_safe "$IMAGE"

  echo "🐳 启动 Hysteria 容器..."
  docker run -itd --restart=always --network=host \
    --ulimit nofile=1048576:1048576 \
    --sysctl net.core.rmem_max=2500000 \
    --sysctl net.core.wmem_max=2500000 \
    -v "${CONFIG_DIR}:/etc/hysteria" \
    --name "${CONTAINER}" \
    "${IMAGE}"

  echo ""
  echo "✅ 部署完成"
  echo "--------------------------------------"
  echo "🌐 面板地址: ${API_HOST}"
  echo "🔑 通讯密钥(已URL编码): ${API_KEY_ENC}"
  echo "🆔 节点 ID: ${NODE_ID}"
  echo "🏷️ 节点域名: ${DOMAIN}"
  echo "⚓ 监听端口: ${PORT}"
  echo "📜 证书路径: ${CONFIG_DIR}/tls.crt"
  echo "🐳 容器名称: ${CONTAINER}"
  echo "🧹 日志文件: ${LOG_FILE} (每小时清理)"
  echo "--------------------------------------"
  pause
}


remove_container(){
  echo "⚠️ 确认删除容器与配置？(y/n)"
  read -r c
  if [[ $c =~ ^[Yy]$ ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
    rm -rf "$CONFIG_DIR" "$LOG_FILE" /etc/cron.daily/hysteria_log_clean 2>/dev/null || true
    echo "✅ 已删除容器与配置"
  fi
  pause
}

update_image(){
  docker_pull_safe "$IMAGE"
  docker restart "$CONTAINER" || true
  echo "✅ 镜像已更新并重启"
  pause
}

uninstall_docker_all(){
  echo ""
  echo "⚠️ 卸载 Docker 与所有组件"
  echo "--------------------------------------"
  read -rp "确认继续？(y/n): " c
  [[ ! $c =~ ^[Yy]$ ]] && pause && return

  echo "🧹 停止并删除容器..."
  sudo docker stop $(sudo docker ps -aq) 2>/dev/null || true
  sudo docker rm -f $(sudo docker ps -aq) 2>/dev/null || true
  sudo docker rmi -f $(sudo docker images -q) 2>/dev/null || true
  sudo docker volume rm $(sudo docker volume ls -q) 2>/dev/null || true
  sudo docker network prune -f >/dev/null 2>&1 || true

  echo "🧹 清理 Docker 包与数据..."
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1 || true
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker ~/.docker /etc/cron.daily/hysteria_log_clean "$LOG_FILE"
  echo ""
  echo "✅ Docker 已彻底卸载！"
  sleep 3
  exit 0
}

menu(){
  header
  read -rp "请选择操作: " opt
  case "$opt" in
    1) install_hysteria ;;
    2) docker restart "$CONTAINER" || echo "⚠️ 未找到容器"; pause ;;
    3) docker stop "$CONTAINER" || echo "⚠️ 未找到容器"; pause ;;
    4) remove_container ;;
    5) tail -n 50 "$LOG_FILE" 2>/dev/null || docker logs -f "$CONTAINER"; pause ;;
    6) update_image ;;
    7) uninstall_docker_all ;;
    8) exit 0 ;;
    *) echo "❌ 无效选项"; sleep 1; menu ;;
  esac
}

menu
