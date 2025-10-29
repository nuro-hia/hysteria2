#!/bin/bash
# ============================================================
# Hysteria 对接 XBoard 极简快速部署版（官方 run 模式）
# 作者: nuro
# 日期: 2025-10-30
# 特点: 无 docker-compose，纯 docker run + 自签证书
# ============================================================

set -e
CONFIG_DIR="/etc/hysteria"
IMAGE_NAME="ghcr.io/cedar2025/hysteria:latest"
CONTAINER_NAME="hysteria"

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
}

menu() {
  clear
  echo "=============================="
  echo " Hysteria 对接 XBoard 快速脚本"
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
  read -rp "请选择操作: " opt
  case "$opt" in
    1) install_hysteria ;;
    2) docker restart $CONTAINER_NAME || echo "⚠️ 未找到容器"; pause ;;
    3) docker stop $CONTAINER_NAME || echo "⚠️ 未找到容器"; pause ;;
    4) remove_all ;;
    5) docker logs -f $CONTAINER_NAME || echo "⚠️ 未找到容器"; pause ;;
    6) docker pull $IMAGE_NAME && docker restart $CONTAINER_NAME; pause ;;
    7) uninstall_all ;;
    8) exit 0 ;;
    *) echo "❌ 无效选项"; sleep 1; menu ;;
  esac
}

pause() { echo ""; read -rp "按回车返回菜单..." _; menu; }

install_hysteria() {
  install_docker
  mkdir -p "$CONFIG_DIR"

  echo ""
  read -rp "🌐 面板地址: " API_HOST
  read -rp "🔑 通讯密钥: " API_KEY
  read -rp "🆔 节点 ID: " NODE_ID
  read -rp "🏷️  节点域名 (证书 CN): " DOMAIN

  CERT_FILE="${CONFIG_DIR}/tls.crt"
  KEY_FILE="${CONFIG_DIR}/tls.key"

  echo ""
  echo "📜 生成自签证书..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  echo "✅ 证书生成成功"

  echo "🐳 启动 Hysteria 容器..."
  docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true
  docker run -itd --restart=always --network=host \
    -v "${CERT_FILE}:/etc/hysteria/tls.crt" \
    -v "${KEY_FILE}:/etc/hysteria/tls.key" \
    -e apiHost="${API_HOST}" \
    -e apiKey="${API_KEY}" \
    -e nodeID="${NODE_ID}" \
    -e domain="${DOMAIN}" \
    --name "${CONTAINER_NAME}" \
    "${IMAGE_NAME}"

  echo ""
  echo "✅ 部署完成"
  echo "--------------------------------------"
  echo "📄 证书文件: ${CERT_FILE}"
  echo "📡 容器名称: ${CONTAINER_NAME}"
  echo "🌍 面板地址: ${API_HOST}"
  echo "--------------------------------------"
  pause
}

remove_all() {
  echo "⚠️ 确认要删除 Hysteria 容器与配置？"
  read -rp "输入 y 继续: " c
  if [[ $c =~ ^[Yy]$ ]]; then
    docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true
    docker rmi $IMAGE_NAME >/dev/null 2>&1 || true
    rm -rf "$CONFIG_DIR"
    echo "✅ 已删除容器与配置"
  fi
  pause
}

uninstall_all() {
  echo "⚠️ 卸载 Docker 全部组件"
  read -rp "确认继续? y/n: " c
  if [[ $c =~ ^[Yy]$ ]]; then
    docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true
    docker rmi $IMAGE_NAME >/dev/null 2>&1 || true
    rm -rf "$CONFIG_DIR"
    apt purge -y docker docker.io docker-compose docker-compose-plugin containerd runc >/dev/null 2>&1
    rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    echo "✅ 已彻底卸载 Docker 及所有组件"
  fi
  pause
}

menu
