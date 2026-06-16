 #!/usr/bin/env bash
  set -euo pipefail

  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 执行：sudo bash $0"
    exit 1
  fi

  echo "[1/5] 检测系统并安装 fail2ban..."

  if command -v apt >/dev/null 2>&1; then
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

  echo "[2/5] 检测 SSH 端口..."

  SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  SSH_PORT="${SSH_PORT:-22}"

  echo "SSH 端口：$SSH_PORT"

  echo "[3/5] 检测 SSH 日志..."

  if [ -f /var/log/auth.log ]; then
    BACKEND="auto"
    LOGPATH="/var/log/auth.log"
  elif [ -f /var/log/secure ]; then
    BACKEND="auto"
    LOGPATH="/var/log/secure"
  else
    BACKEND="systemd"
    LOGPATH=""
  fi

  mkdir -p /etc/fail2ban/jail.d

  echo "[4/5] 写入 fail2ban SSH 规则..."

  if [ "$BACKEND" = "systemd" ]; then
    cat >/etc/fail2ban/jail.d/sshd.local <<EOF
  [sshd]
  enabled = true
  port = $SSH_PORT
  backend = systemd
  maxretry = 5
  findtime = 10m
  bantime = 1h
  EOF
  else
    cat >/etc/fail2ban/jail.d/sshd.local <<EOF
  [sshd]
  enabled = true
  port = $SSH_PORT
  backend = $BACKEND
  logpath = $LOGPATH
  maxretry = 5
  findtime = 10m
  bantime = 1h
  EOF
  fi

  echo "[5/5] 启动 fail2ban..."

  systemctl enable --now fail2ban
  systemctl restart fail2ban

  echo
  echo "完成。当前状态："
  fail2ban-client status || true
  echo
  echo "SSHD jail 状态："
  fail2ban-client status sshd || true
