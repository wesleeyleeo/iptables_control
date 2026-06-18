#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-/data/docker}"
OLD="/var/lib/docker"
DAEMON_JSON="/etc/docker/daemon.json"

die() {
  echo "错误：$*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"
}

install_rsync_if_missing() {
  if command -v rsync >/dev/null 2>&1; then
    return 0
  fi

  echo "缺少 rsync，正在安装..."
  if command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y rsync
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y rsync
  elif command -v yum >/dev/null 2>&1; then
    yum install -y rsync
  else
    die "缺少 rsync，且找不到 apt/dnf/yum 自动安装"
  fi
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

stop_docker() {
  echo "[2/8] 停止 Docker..."
  systemctl stop docker.socket 2>/dev/null || true
  systemctl stop docker.service 2>/dev/null || true
  systemctl stop containerd.service 2>/dev/null || true
}

start_docker() {
  echo "[5/8] 启动 Docker..."
  systemctl start containerd.service 2>/dev/null || true
  systemctl start docker.service
}

write_daemon_json() {
  mkdir -p /etc/docker

  if [ -f "$DAEMON_JSON" ]; then
    cp "$DAEMON_JSON" "$DAEMON_JSON.bak.$(date +%Y%m%d%H%M%S)"
  fi

  if [ -s "$DAEMON_JSON" ]; then
    python3 -c 'import json,sys,pathlib
target=sys.argv[1]
path=pathlib.Path(sys.argv[2])
data=json.loads(path.read_text() or "{}")
if not isinstance(data, dict):
    raise SystemExit("daemon.json 顶层必须是 JSON 对象")
data["data-root"]=target
path.write_text(json.dumps(data, indent=2, ensure_ascii=False)+"\n")' "$TARGET" "$DAEMON_JSON"
  else
    printf '{\n  "data-root": "%s"\n}\n' "$TARGET" >"$DAEMON_JSON"
  fi

  python3 -m json.tool "$DAEMON_JSON" >/dev/null
}

main() {
  need_root
  check_cmd docker
  check_cmd python3
  check_cmd systemctl
  install_rsync_if_missing

  echo "[1/8] 检查环境..."

  [ -d /data ] || die "/data 不存在"
  [ -d "$OLD" ] || die "$OLD 不存在"

  if ! mountpoint -q /data; then
    echo "警告：/data 不是独立挂载点，请确认这是你想要的位置"
  fi

  current_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "$OLD")"

  echo "当前 Docker Root Dir: $current_root"
  echo "目标 Docker Root Dir: $TARGET"

  if [ "$current_root" = "$TARGET" ]; then
    echo "Docker 已经使用 $TARGET，无需迁移"
    exit 0
  fi

  stop_docker

  echo "[3/8] 复制 Docker 数据到 $TARGET..."
  mkdir -p "$TARGET"
  rsync -aHAXx --numeric-ids "$OLD"/ "$TARGET"/

  echo "[4/8] 写入 Docker 配置..."
  write_daemon_json

  start_docker

  echo "[6/8] 检查迁移结果..."
  sleep 2

  new_root="$(docker info -f '{{.DockerRootDir}}')"
  echo "新的 Docker Root Dir: $new_root"

  if [ "$new_root" != "$TARGET" ]; then
    die "迁移失败：Docker Root Dir 不是 $TARGET"
  fi

  docker ps -a

  echo "[7/8] 删除旧 Docker 数据..."
  if [ "$OLD" = "$TARGET" ]; then
    die "旧目录和目标目录相同，拒绝删除"
  fi
  rm -rf "$OLD"

  echo "[8/8] 完成"
  echo "Docker 数据已迁移到：$TARGET"
  echo "旧目录已删除：$OLD"
  df -h / "$TARGET"
}

main "$@"
