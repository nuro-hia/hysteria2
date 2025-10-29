#!/bin/bash
# =====================================================
# Hysteria 对接 XBoard 管理脚本 (CF DNS 自动申请证书)
# 作者: nuro | 日期: 2025-10-30
# =====================================================

set -e
CONFIG_DIR="/etc/hysteria"
IMAGE="ghcr.io/cedar2025/hysteria:latest"
CONTAINER="hysteria"
ACME_HOME="/root/.acme.sh"

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

install_acme() {
  if [ ! -x "${ACME_HOME}/acme.sh" ]; then
    echo "🪪 安装 acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email=cf@local
  fi
  "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

issue_cf_dns_cert() {
  local domain="$1" email="$2" spikey="$3"
  mkdir -p "$CONFIG_DIR"
  install_acme

  echo "🔐 使用 Cloudflare DNS 验证方式为 ${domain} 申请证书..."
  export CF_Email="${email}"
  export CF_Key="${spikey}"

  "${ACME_HOME}/acme.sh" --issue --dns dns_cf -d "${domain}" --keylength ec-256

  echo "📦 安装证书到 ${CONFIG_DIR}..."
  "${ACME_HOME}/acme.sh" --install-cert -d "${domain}" --ecc \
    --fullchain-file "${CONFIG_DIR}/tls.crt" \
    --key-file "${CONFIG_DIR}/tls.key" \
    --reloadcmd "docker restart ${CONTAINER} >/dev/null 2>&1 || true"

  chmod 600 "${CONFIG_DIR}/tls.key"
  echo "✅ 证书申请成功：${CONFIG_DIR}/tls.crt / ${CONFIG_DIR}/tls.key"
}

install_hysteria() {
  install_docker
  mkdir -p "$CONFIG_DIR"

  echo ""
  read -rp "🌐 面板地址(如 https://mist.mistea.link): " API_HOST
  read -rp "🔑 通讯密钥(apiKey): " API_KEY
  read -rp "🆔 节点 ID(nodeID): " NODE_ID
  read -rp "🏷️ 节点域名(证书 CN): " DOMAIN
  echo ""
  echo "📩 请输入 Cloudflare 账户邮箱 与 Global API Key(SPI Key)"
  read -rp "📧 邮箱: " CF_EMAIL
  read -rp "🔐 Global API Key(SPI Key): " CF_KEY

  echo "📜 正在通过 Cloudflare DNS 验证申请证书..."
  issue_cf_dns_cert "${DOMAIN}" "${CF_EMAIL}" "${CF_KEY}"

  echo "🐳 启动 Hysteria 容器..."
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker pull "$IMAGE" || true
  docker run -itd --restart=always --network=host \
    -v "${CONFIG_DIR}/tls.crt:/etc/hysteria/tls.crt" \
    -v "${CONFIG_DIR}/tls.key:/etc/hysteria/tls.key" \
    -e apiHost="${API_HOST}" \
    -e apiKey="${API_KEY}" \
    -e nodeID="${NODE_ID}" \
    -e domain="${DOMAIN}" \
    -e acmeEmail="disabled" \
    --name "${CONTAINER}" \
    "${IMAGE}"

  echo ""
  echo "✅ 部署完成"
  echo "--------------------------------------"
  echo "🌐 面板地址: ${API_HOST}"
  echo "🔑 通讯密钥: ${API_KEY}"
  echo "🆔 节点 ID: ${NODE_ID}"
  echo "🏷️ 节点域名: ${DOMAIN}"
  echo "📜 证书文件: ${CONFIG_DIR}/tls.crt"
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
  docker pull "$IMAGE"
  docker restart "$CONTAINER" || true
  echo "✅ 镜像已更新并重启"
  pause
}

uninstall_docker_all() {
  echo "⚠️ 卸载 Docker 及全部组件"
  read -rp "确认继续？(y/n): " c
  if [[ $c =~ ^[Yy]$ ]]; then
    echo "🧹 停止所有容器..."
    docker stop $(docker ps -aq) >/dev/null 2>&1 || true
    echo "🧹 删除容器与镜像..."
    docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
    docker rmi -f $(docker images -q) >/dev/null 2>&1 || true
    echo "🧹 删除配置与服务..."
    rm -rf "$CONFIG_DIR" /var/lib/docker /var/lib/containerd /etc/docker
    apt purge -y docker docker.io docker-compose docker-compose-plugin containerd runc >/dev/null 2>&1 || true
    apt autoremove -y >/dev/null 2>&1
    systemctl disable docker >/dev/null 2>&1 || true
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
