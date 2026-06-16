#!/usr/bin/env bash
set -euo pipefail

JAIL_NAME="sshd"
JAIL_FILE="/etc/fail2ban/jail.d/sshd.local"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 执行：sudo bash $0"
    exit 1
  fi
}

detect_ssh_port() {
  local ssh_port=""
  local sshd_config=""

  if command -v sshd >/dev/null 2>&1; then
    sshd_config="$(sshd -T 2>/dev/null || true)"
    ssh_port="$(printf '%s\n' "$sshd_config" | awk '/^port /{print $2; exit}')"
  fi

  if [ -z "$ssh_port" ]; then
    ssh_port="$(awk '
      /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
        print $2
        exit
      }
    ' /etc/ssh/sshd_config 2>/dev/null || true)"
  fi

  printf '%s\n' "${ssh_port:-22}"
}

detect_backend_and_logpath() {
  if [ -f /var/log/auth.log ]; then
    printf '%s|%s\n' "auto" "/var/log/auth.log"
  elif [ -f /var/log/secure ]; then
    printf '%s|%s\n' "auto" "/var/log/secure"
  else
    printf '%s|%s\n' "systemd" ""
  fi
}

install_fail2ban_package() {
  echo "[1/5] 检测系统并安装 fail2ban..."

  if command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y fail2ban
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release || true
    dnf install -y fail2ban
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y fail2ban
  else
    echo "不支持的系统：找不到 apt/dnf/yum"
    exit 1
  fi
}

write_sshd_jail() {
  local ssh_port="$1"
  local backend="$2"
  local logpath="$3"

  mkdir -p /etc/fail2ban/jail.d

  echo "[4/5] 写入 fail2ban SSH 规则..."

  if [ "$backend" = "systemd" ]; then
    cat >"$JAIL_FILE" <<EOF
[$JAIL_NAME]
enabled = true
port = $ssh_port
backend = systemd
maxretry = 5
findtime = 10m
bantime = -1
EOF
  else
    cat >"$JAIL_FILE" <<EOF
[$JAIL_NAME]
enabled = true
port = $ssh_port
backend = $backend
logpath = $logpath
maxretry = 5
findtime = 10m
bantime = -1
EOF
  fi
}

wait_fail2ban() {
  echo "等待 fail2ban 启动..."
  for _ in $(seq 1 10); do
    if fail2ban-client ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

install_or_update() {
  require_root

  install_fail2ban_package

  echo "[2/5] 检测 SSH 端口..."
  local ssh_port
  ssh_port="$(detect_ssh_port)"
  echo "SSH 端口：$ssh_port"

  echo "[3/5] 检测 SSH 日志..."
  local detected backend logpath
  detected="$(detect_backend_and_logpath)"
  backend="${detected%%|*}"
  logpath="${detected#*|}"

  write_sshd_jail "$ssh_port" "$backend" "$logpath"

  echo "[5/5] 启动 fail2ban..."
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  wait_fail2ban || true

  echo
  echo "完成。当前状态："
  fail2ban-client status || true
  echo
  echo "SSHD jail 状态："
  fail2ban-client status "$JAIL_NAME" || true
}

show_status() {
  require_root
  systemctl status fail2ban --no-pager || true
  echo
  fail2ban-client status || true
  echo
  fail2ban-client status "$JAIL_NAME" || true
}

show_banned_ips() {
  require_root
  fail2ban-client status "$JAIL_NAME" | sed -n 's/.*Banned IP list:[[:space:]]*//p'
}

show_stats() {
  require_root
  echo "Fail2ban 服务："
  systemctl is-active fail2ban || true
  echo
  echo "Jail 概览："
  fail2ban-client status || true
  echo
  echo "SSHD 统计："
  fail2ban-client status "$JAIL_NAME" || true
  echo
  echo "最近封禁记录："
  journalctl -u fail2ban -n 50 --no-pager | grep -Ei 'Ban|Unban' || true
}

unban_ip() {
  require_root
  local ip="${1:-}"

  if [ -z "$ip" ]; then
    read -r -p "请输入要解封的 IP: " ip
  fi

  if [ -z "$ip" ]; then
    echo "IP 不能为空"
    exit 1
  fi

  fail2ban-client set "$JAIL_NAME" unbanip "$ip"
}

restart_fail2ban() {
  require_root
  systemctl restart fail2ban
  wait_fail2ban || true
  fail2ban-client status "$JAIL_NAME" || true
}

show_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "Fail2ban SSH 管理面板"
    echo "======================"
    echo "1. 安装/更新 SSH 防护（永久封禁）"
    echo "2. 查看运行状态"
    echo "3. 查看封禁 IP"
    echo "4. 查看统计和最近封禁记录"
    echo "5. 解封 IP"
    echo "6. 重启 fail2ban"
    echo "0. 退出"
    echo
    read -r -p "请选择: " choice

    case "$choice" in
      1) install_or_update ;;
      2) show_status ;;
      3) show_banned_ips ;;
      4) show_stats ;;
      5) unban_ip ;;
      6) restart_fail2ban ;;
      0) exit 0 ;;
      *) echo "无效选择" ;;
    esac

    echo
    read -r -p "按回车返回菜单..." _
  done
}

default_command() {
  if [ -t 0 ]; then
    printf '%s\n' "menu"
  else
    printf '%s\n' "install"
  fi
}

case "${1:-$(default_command)}" in
  menu) show_menu ;;
  install) install_or_update ;;
  status) show_status ;;
  banned) show_banned_ips ;;
  stats) show_stats ;;
  unban) unban_ip "${2:-}" ;;
  restart) restart_fail2ban ;;
  *)
    echo "用法：$0 [menu|install|status|banned|stats|unban <ip>|restart]"
    exit 1
    ;;
esac
