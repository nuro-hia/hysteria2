#!/bin/bash
# =====================================================
# Hysteria 对接 XBoard 管理脚本（内置 ACME 自动签发版）
# 作者: nuro | 日期: 2025-10-30
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

fix_docker_tmp() {
  local root_dir
  root_dir=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
  systemctl stop docker || true
  mkdir -p "${root_dir}/tmp"
  chmod 1777 "${root_dir}/tmp"
  rm -rf "${root_dir}/tmp/"* || true
  export DOCKER_TMPDIR="${root_dir}/tmp"
  systemctl restart containerd || true
  systemctl start docker || true
}

install_docker() {
  echo "🧩 检查 Docker 环境..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
  else
    echo "✅ 已检测到 Docker"
  fi
  fix_docker_tmp
}

install_hysteria() {
  install_docker
  mkdir -p "$CONFIG_DIR"

  echo ""
  read -rp "🌐 面板地址(如 https://mist.mistea.link): " API_HOST
  read -rp "🔑 通讯密钥(apiKey): " API_KEY
  read -rp "🆔 节点 ID(nodeID): " NODE_ID
  read -rp "🏷️ 节点域名(证书 CN): " DOMAIN
  read -rp "📧 ACME 注册邮箱(可随意填写): " ACME_EMAIL

  echo ""
  echo "📜 使用 Hysteria 内置 ACME 自动申请证书..."
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker pull "$IMAGE" || true

  docker run -itd --restart=always --network=host \
    -v "${CONFIG_DIR}:/etc/hysteria" \
    -e apiHost="${API_HOST}" \
    -e apiKey="${API_KEY}" \
    -e nodeID="${NODE_ID}" \
    -e domain="${DOMAIN}" \
    -e acmeDomains="${DOMAIN}" \
    -e acmeEmail="${ACME_EMAIL}" \
    --name "${CONTAINER}" \
    "${IMAGE}"

  echo ""
  echo "✅ 部署完成"
  echo "--------------------------------------"
  echo "🌐 面板地址: ${API_HOST}"
  echo "🔑 通讯密钥: ${API_KEY}"
  echo "🆔 节点 ID: ${NODE_ID}"
  echo "🏷️ 节点域名: ${DOMAIN}"
  echo "📧 ACME 邮箱: ${ACME_EMAIL}"
  echo "🐳 容器名称: ${CONTAINER}"
  echo "--------------------------------------"
  echo ""
  echo "⚠️ 请确保端口 80 和 443 未被其他服务占用"
  echo "⚠️ 若证书申请失败，请关闭 nginx、caddy、bt 面板等占用 80/443 的进程"
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
  docker pull "$IMAGE"
  docker restart "$CONTAINER" || true
  echo "✅ 镜像已更新并重启"
  pause
}

uninstall_docker_all() {
  echo "⚠️ 卸载 Docker 及全部组件"
  read -rp "确认继续？(y/n): " c
  if [[ $c =~ ^[Yy]$ ]]; then
    echo "🧹 停止服务（含 socket）..."
    systemctl stop docker docker.socket containerd || true
    pkill -f dockerd || true
    pkill -f containerd || true

    echo "🧹 清理容器/镜像/卷/网络..."
    systemctl start docker || true
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker rmi -f $(docker images -aq) 2>/dev/null || true
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    docker network rm $(docker network ls -q | grep -vE '(^ID$|^NAME$|bridge|host|none)') 2>/dev/null || true
    docker system prune -af --volumes 2>/dev/null || true

    echo "🧹 停止并禁用/屏蔽 docker 与 containerd..."
    systemctl stop docker docker.socket containerd || true
    systemctl disable docker docker.socket containerd || true
    systemctl mask docker docker.socket containerd || true

    echo "🧹 删除数据与配置目录..."
    rm -rf /etc/hysteria
    rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    rm -rf ~/.docker

    echo "🧹 卸载相关包..."
    apt purge -y docker docker.io docker-engine docker-compose docker-compose-plugin containerd runc >/dev/null 2>&1 || true
    apt autoremove -y >/dev/null 2>&1 || true
    systemctl daemon-reload

    echo "✅ 已彻底卸载 Docker 与 Hysteria 所有组件"
  fi
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
