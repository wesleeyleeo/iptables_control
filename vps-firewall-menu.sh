#!/usr/bin/env bash
set -u

VERSION="2026-06-09"
BACKUP_DIR="${BACKUP_DIR:-/root/iptables-backups}"
IPV4_RULES_FILE="${IPV4_RULES_FILE:-/etc/iptables.rules}"
IPV6_RULES_FILE="${IPV6_RULES_FILE:-/etc/ip6tables.rules}"
DEFAULT_SSH_PORT="${DEFAULT_SSH_PORT:-22}"
BACKUP_DONE=0

if [[ -t 1 ]]; then
  RED="$(tput setaf 1 2>/dev/null || true)"
  GREEN="$(tput setaf 2 2>/dev/null || true)"
  YELLOW="$(tput setaf 3 2>/dev/null || true)"
  BLUE="$(tput setaf 4 2>/dev/null || true)"
  BOLD="$(tput bold 2>/dev/null || true)"
  RESET="$(tput sgr0 2>/dev/null || true)"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

info() { printf "%s\n" "${BLUE}==>${RESET} $*"; }
ok() { printf "%s\n" "${GREEN}OK:${RESET} $*"; }
warn() { printf "%s\n" "${YELLOW}WARN:${RESET} $*" >&2; }
err() { printf "%s\n" "${RED}ERROR:${RESET} $*" >&2; }
pause() {
  printf "\n"
  read -r -p "按回车返回主菜单..." _
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请用 root 执行：sudo bash $0"
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_iptables() {
  if ! has_cmd iptables && ! has_cmd ip6tables; then
    err "系统里没有 iptables/ip6tables。请先安装 iptables。"
    exit 1
  fi
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

read_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "${value:-$default}"
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

select_family() {
  local choice
  printf "\n选择 IP 版本：\n" >&2
  printf "  1) IPv4\n" >&2
  printf "  2) IPv6\n" >&2
  printf "  3) IPv4 + IPv6\n" >&2
  read -r -p "请选择 [3]: " choice
  case "${choice:-3}" in
    1) printf "4" ;;
    2) printf "6" ;;
    3) printf "46" ;;
    *) warn "选择无效，默认 IPv4 + IPv6"; printf "46" ;;
  esac
}

select_proto() {
  local choice
  printf "\n选择协议：\n" >&2
  printf "  1) TCP\n" >&2
  printf "  2) UDP\n" >&2
  printf "  3) TCP + UDP\n" >&2
  read -r -p "请选择 [1]: " choice
  case "${choice:-1}" in
    1) printf "tcp" ;;
    2) printf "udp" ;;
    3) printf "tcp,udp" ;;
    *) warn "选择无效，默认 TCP"; printf "tcp" ;;
  esac
}

select_target() {
  local choice
  printf "\n选择放行位置：\n" >&2
  printf "  1) 主机 INPUT（普通服务 / Docker 外部映射端口）\n" >&2
  printf "  2) Docker DOCKER-USER（容器内部端口）\n" >&2
  printf "  3) 两个都处理\n" >&2
  read -r -p "请选择 [1]: " choice
  case "${choice:-1}" in
    1) printf "input" ;;
    2) printf "docker" ;;
    3) printf "both" ;;
    *) warn "选择无效，默认 INPUT"; printf "input" ;;
  esac
}

valid_port_expr() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{1,5}(:[0-9]{1,5})?$ ]] || return 1
  local left="${value%%:*}"
  local right="${value##*:}"
  [[ "$left" -ge 1 && "$left" -le 65535 && "$right" -ge 1 && "$right" -le 65535 ]] || return 1
  if [[ "$value" == *:* ]]; then
    [[ "$left" -le "$right" ]] || return 1
  fi
}

ask_port() {
  local prompt="$1"
  local port
  while true; do
    read -r -p "$prompt（如 8080 或 3000:3010）: " port
    if valid_port_expr "$port"; then
      printf "%s" "$port"
      return
    fi
    warn "端口格式不正确。"
  done
}

ask_ports() {
  local prompt="$1"
  local ports item ok_list
  while true; do
    read -r -p "$prompt（可多个，用空格分隔；如 8080 8443 3000:3010）: " ports
    ok_list=""
    read -r -a PORT_ITEMS <<< "$ports"
    for item in "${PORT_ITEMS[@]}"; do
      item="$(trim_value "$item")"
      if [[ -z "$item" ]] || ! valid_port_expr "$item"; then
        ok_list=""
        break
      fi
      if [[ -z "$ok_list" ]]; then
        ok_list="$item"
      else
        ok_list="$ok_list $item"
      fi
    done
    if [[ -n "$ok_list" ]]; then
      printf "%s" "$ok_list"
      return
    fi
    warn "端口格式不正确。"
  done
}

ask_ports_optional() {
  local prompt="$1"
  local ports item ok_list
  while true; do
    read -r -p "$prompt（可留空；多个用空格分隔；如 80 443 14946）: " ports
    ports="$(trim_value "$ports")"
    if [[ -z "$ports" ]]; then
      printf ""
      return
    fi
    ok_list=""
    read -r -a PORT_ITEMS <<< "$ports"
    for item in "${PORT_ITEMS[@]}"; do
      item="$(trim_value "$item")"
      if [[ -z "$item" ]] || ! valid_port_expr "$item"; then
        ok_list=""
        break
      fi
      if [[ -z "$ok_list" ]]; then
        ok_list="$item"
      else
        ok_list="$ok_list $item"
      fi
    done
    if [[ -n "$ok_list" ]]; then
      printf "%s" "$ok_list"
      return
    fi
    warn "端口格式不正确。"
  done
}

ask_source() {
  local src
  read -r -p "限制来源 IP/CIDR（留空表示所有来源，例如 1.2.3.4 或 1.2.3.0/24）: " src
  printf "%s" "$src"
}

bin_for_family() {
  case "$1" in
    4) printf "iptables" ;;
    6) printf "ip6tables" ;;
  esac
}

save_bin_for_family() {
  case "$1" in
    4) printf "iptables-save" ;;
    6) printf "ip6tables-save" ;;
  esac
}

restore_bin_for_family() {
  case "$1" in
    4) printf "iptables-restore" ;;
    6) printf "ip6tables-restore" ;;
  esac
}

rules_file_for_family() {
  case "$1" in
    4) printf "%s" "$IPV4_RULES_FILE" ;;
    6) printf "%s" "$IPV6_RULES_FILE" ;;
  esac
}

save_cmd_for_family() {
  case "$1" in
    4) printf "iptables-save" ;;
    6) printf "ip6tables-save" ;;
  esac
}

family_name() {
  case "$1" in
    4) printf "IPv4" ;;
    6) printf "IPv6" ;;
  esac
}

family_available() {
  local family="$1"
  local bin
  bin="$(bin_for_family "$family")"
  has_cmd "$bin"
}

chain_exists() {
  local bin="$1"
  local chain="$2"
  "$bin" -L "$chain" -n >/dev/null 2>&1
}

build_rule_args() {
  local proto="$1"
  local port="$2"
  local src="$3"
  RULE_ARGS=(-p "$proto" --dport "$port")
  if [[ -n "$src" ]]; then
    RULE_ARGS=(-s "$src" "${RULE_ARGS[@]}")
  fi
}

rule_exists() {
  local bin="$1"
  local chain="$2"
  local proto="$3"
  local port="$4"
  local src="$5"
  build_rule_args "$proto" "$port" "$src"
  "$bin" -C "$chain" "${RULE_ARGS[@]}" -j ACCEPT >/dev/null 2>&1
}

first_terminal_line() {
  local bin="$1"
  local chain="$2"
  "$bin" -L "$chain" -n --line-numbers 2>/dev/null | awk '$2 == "DROP" || $2 == "REJECT" || $2 == "RETURN" {print $1; exit}'
}

first_terminal_target() {
  local bin="$1"
  local chain="$2"
  "$bin" -L "$chain" -n --line-numbers 2>/dev/null | awk '$2 == "DROP" || $2 == "REJECT" || $2 == "RETURN" {print $2; exit}'
}

backup_once() {
  local ts
  if [[ "$BACKUP_DONE" -eq 1 ]]; then
    return
  fi
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  if has_cmd iptables-save; then
    iptables-save > "$BACKUP_DIR/iptables-$ts.rules" 2>/dev/null || true
  fi
  if has_cmd ip6tables-save; then
    ip6tables-save > "$BACKUP_DIR/ip6tables-$ts.rules" 2>/dev/null || true
  fi
  BACKUP_DONE=1
  ok "已备份当前规则到 $BACKUP_DIR"
}

add_accept_rule() {
  local family="$1"
  local chain="$2"
  local proto="$3"
  local port="$4"
  local src="$5"
  local bin insert_at
  bin="$(bin_for_family "$family")"

  if ! family_available "$family"; then
    warn "$(family_name "$family") 工具不存在，跳过。"
    return
  fi
  if ! chain_exists "$bin" "$chain"; then
    warn "$(family_name "$family") 链 $chain 不存在，跳过。"
    return
  fi
  if rule_exists "$bin" "$chain" "$proto" "$port" "$src"; then
    ok "$(family_name "$family") $chain 已存在 $proto/$port 放行规则，跳过。"
    return
  fi

  backup_once
  build_rule_args "$proto" "$port" "$src"
  insert_at="$(first_terminal_line "$bin" "$chain")"
  if [[ -n "$insert_at" ]]; then
    "$bin" -I "$chain" "$insert_at" "${RULE_ARGS[@]}" -j ACCEPT
  else
    "$bin" -A "$chain" "${RULE_ARGS[@]}" -j ACCEPT
  fi
  ok "已放行 $(family_name "$family") $chain $proto/$port"
}

delete_accept_rule_loop() {
  local family="$1"
  local chain="$2"
  local proto="$3"
  local port="$4"
  local src="$5"
  local bin count
  bin="$(bin_for_family "$family")"
  count=0

  if ! family_available "$family"; then
    warn "$(family_name "$family") 工具不存在，跳过。"
    return
  fi
  if ! chain_exists "$bin" "$chain"; then
    warn "$(family_name "$family") 链 $chain 不存在，跳过。"
    return
  fi

  build_rule_args "$proto" "$port" "$src"
  while "$bin" -C "$chain" "${RULE_ARGS[@]}" -j ACCEPT >/dev/null 2>&1; do
    backup_once
    "$bin" -D "$chain" "${RULE_ARGS[@]}" -j ACCEPT
    count=$((count + 1))
  done

  if [[ "$count" -eq 0 ]]; then
    warn "$(family_name "$family") $chain 没找到完全匹配的 $proto/$port 规则。"
  else
    ok "已删除 $(family_name "$family") $chain $count 条 $proto/$port 规则。"
  fi
}

save_rules() {
  local family="$1"
  local save_bin file
  save_bin="$(save_bin_for_family "$family")"
  file="$(rules_file_for_family "$family")"
  if ! has_cmd "$save_bin"; then
    warn "$(family_name "$family") 保存工具不存在，跳过。"
    return
  fi
  "$save_bin" > "$file"
  ok "已保存 $(family_name "$family") 到 $file"
}

restore_rules() {
  local family="$1"
  local restore_bin file
  restore_bin="$(restore_bin_for_family "$family")"
  file="$(rules_file_for_family "$family")"
  if ! has_cmd "$restore_bin"; then
    warn "$(family_name "$family") 恢复工具不存在，跳过。"
    return
  fi
  if [[ ! -f "$file" ]]; then
    warn "$file 不存在，跳过。"
    return
  fi
  backup_once
  "$restore_bin" < "$file"
  ok "已从 $file 恢复 $(family_name "$family")"
}

for_each_family() {
  local families="$1"
  local fn="$2"
  local family
  for family in 4 6; do
    [[ "$families" == *"$family"* ]] || continue
    "$fn" "$family"
  done
}

list_rules() {
  local family="$1"
  local bin
  bin="$(bin_for_family "$family")"
  if ! family_available "$family"; then
    warn "$(family_name "$family") 工具不存在，跳过。"
    return
  fi
  printf "\n%s%s INPUT:%s\n" "$BOLD" "$(family_name "$family")" "$RESET"
  "$bin" -L INPUT -n -v --line-numbers || true
  if chain_exists "$bin" DOCKER-USER; then
    printf "\n%s%s DOCKER-USER:%s\n" "$BOLD" "$(family_name "$family")" "$RESET"
    "$bin" -L DOCKER-USER -n -v --line-numbers || true
  fi
}

list_all_rules() {
  for_each_family "$(select_family)" list_rules
}

open_port_menu() {
  local families target proto_csv input_ports docker_ports src proto family input_port docker_port
  families="$(select_family)"
  target="$(select_target)"
  proto_csv="$(select_proto)"
  if [[ "$target" == "input" ]]; then
    input_ports="$(ask_ports "主机 INPUT 端口")"
  elif [[ "$target" == "docker" ]]; then
    docker_ports="$(ask_ports "Docker 容器内部端口，不是外部映射端口")"
  else
    input_ports="$(ask_ports "主机 INPUT 端口，通常是外部映射端口")"
    docker_ports="$(ask_ports "Docker DOCKER-USER 端口，通常是容器内部端口")"
  fi
  src="$(ask_source)"

  IFS=',' read -r -a PROTOS <<< "$proto_csv"
  for family in 4 6; do
    [[ "$families" == *"$family"* ]] || continue
    for proto in "${PROTOS[@]}"; do
      if [[ "$target" == "input" || "$target" == "both" ]]; then
        read -r -a INPUT_PORT_ITEMS <<< "$input_ports"
        for input_port in "${INPUT_PORT_ITEMS[@]}"; do
          add_accept_rule "$family" INPUT "$proto" "$input_port" "$src"
        done
      fi
      if [[ "$target" == "docker" || "$target" == "both" ]]; then
        read -r -a DOCKER_PORT_ITEMS <<< "$docker_ports"
        for docker_port in "${DOCKER_PORT_ITEMS[@]}"; do
          add_accept_rule "$family" DOCKER-USER "$proto" "$docker_port" "$src"
        done
      fi
    done
  done

  if confirm "是否立即保存规则，保证重启后还在"; then
    for_each_family "$families" save_rules
  else
    warn "未保存，重启或防火墙恢复后可能丢失。"
  fi
}

close_port_menu() {
  local families target proto_csv input_ports docker_ports src proto family input_port docker_port
  families="$(select_family)"
  target="$(select_target)"
  proto_csv="$(select_proto)"
  if [[ "$target" == "input" ]]; then
    input_ports="$(ask_ports "要关闭的主机 INPUT 端口")"
  elif [[ "$target" == "docker" ]]; then
    docker_ports="$(ask_ports "要关闭的 Docker 容器内部端口")"
  else
    input_ports="$(ask_ports "要关闭的主机 INPUT 端口")"
    docker_ports="$(ask_ports "要关闭的 Docker 容器内部端口")"
  fi
  src="$(ask_source)"

  warn "关闭端口只删除完全匹配的 ACCEPT 规则。如果规则带了来源 IP，关闭时也要填写同样来源。"
  IFS=',' read -r -a PROTOS <<< "$proto_csv"
  for family in 4 6; do
    [[ "$families" == *"$family"* ]] || continue
    for proto in "${PROTOS[@]}"; do
      if [[ "$target" == "input" || "$target" == "both" ]]; then
        read -r -a INPUT_PORT_ITEMS <<< "$input_ports"
        for input_port in "${INPUT_PORT_ITEMS[@]}"; do
          delete_accept_rule_loop "$family" INPUT "$proto" "$input_port" "$src"
        done
      fi
      if [[ "$target" == "docker" || "$target" == "both" ]]; then
        read -r -a DOCKER_PORT_ITEMS <<< "$docker_ports"
        for docker_port in "${DOCKER_PORT_ITEMS[@]}"; do
          delete_accept_rule_loop "$family" DOCKER-USER "$proto" "$docker_port" "$src"
        done
      fi
    done
  done

  if confirm "是否立即保存规则"; then
    for_each_family "$families" save_rules
  else
    warn "未保存，重启或防火墙恢复后可能回到旧规则。"
  fi
}

normalize_proto_values() {
  local value="$1"
  case "$value" in
    tcp) printf "tcp" ;;
    udp) printf "udp" ;;
    both|tcp+udp|tcp_udp) printf "tcp,udp" ;;
    *) return 1 ;;
  esac
}

apply_service_row() {
  local name="$1"
  local families="$2"
  local target="$3"
  local proto_value="$4"
  local input_port="$5"
  local docker_port="$6"
  local src="$7"
  local proto_csv proto family

  if [[ ! "$families" =~ ^(4|6|46|64)$ ]]; then
    warn "[$name] IP 版本无效：$families"
    return
  fi
  if [[ "$target" != "input" && "$target" != "docker" && "$target" != "both" ]]; then
    warn "[$name] target 无效：$target"
    return
  fi
  proto_csv="$(normalize_proto_values "$proto_value")" || {
    warn "[$name] protocol 无效：$proto_value"
    return
  }
  if [[ "$target" == "input" || "$target" == "both" ]]; then
    if ! valid_port_expr "$input_port"; then
      warn "[$name] input_port 无效：$input_port"
      return
    fi
  fi
  if [[ "$target" == "docker" || "$target" == "both" ]]; then
    if ! valid_port_expr "$docker_port"; then
      warn "[$name] docker_port 无效：$docker_port"
      return
    fi
  fi

  info "应用服务：$name"
  IFS=',' read -r -a PROTOS <<< "$proto_csv"
  for family in 4 6; do
    [[ "$families" == *"$family"* ]] || continue
    for proto in "${PROTOS[@]}"; do
      if [[ "$target" == "input" || "$target" == "both" ]]; then
        add_accept_rule "$family" INPUT "$proto" "$input_port" "$src"
      fi
      if [[ "$target" == "docker" || "$target" == "both" ]]; then
        add_accept_rule "$family" DOCKER-USER "$proto" "$docker_port" "$src"
      fi
    done
  done
}

batch_import_menu() {
  local file line line_no name families target proto input_port docker_port src
  read -r -p "请输入服务配置 CSV 路径: " file
  if [[ ! -f "$file" ]]; then
    err "文件不存在：$file"
    return
  fi

  warn "CSV 格式：name,family,target,protocol,input_port,docker_port,source"
  warn "family=4/6/46，target=input/docker/both，protocol=tcp/udp/both。"
  if ! confirm "确认开始批量应用"; then
    warn "已取消。"
    return
  fi

  line_no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line%%$'\r'}"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "$line" == \#* ]] && continue
    if [[ "$line_no" -eq 1 && "$line" == name,* ]]; then
      continue
    fi

    IFS=',' read -r name families target proto input_port docker_port src _extra <<< "$line"
    name="${name//[[:space:]]/}"
    families="${families//[[:space:]]/}"
    target="${target//[[:space:]]/}"
    proto="${proto//[[:space:]]/}"
    input_port="${input_port//[[:space:]]/}"
    docker_port="${docker_port//[[:space:]]/}"
    src="${src//[[:space:]]/}"
    if [[ -z "$name" ]]; then
      warn "第 $line_no 行缺少服务名，跳过。"
      continue
    fi
    apply_service_row "$name" "$families" "$target" "$proto" "$input_port" "$docker_port" "$src"
  done < "$file"

  if confirm "是否立即保存 IPv4 + IPv6 规则"; then
    for_each_family "46" save_rules
  else
    warn "未保存，重启或防火墙恢复后可能丢失。"
  fi
}

delete_by_number_menu() {
  local families family bin chain number
  families="$(select_family)"
  for family in 4 6; do
    [[ "$families" == *"$family"* ]] || continue
    bin="$(bin_for_family "$family")"
    if ! family_available "$family"; then
      warn "$(family_name "$family") 工具不存在，跳过。"
      continue
    fi
    printf "\n%s%s 当前规则编号%s\n" "$BOLD" "$(family_name "$family")" "$RESET"
    list_rules "$family"
    read -r -p "输入要删除的链名（INPUT 或 DOCKER-USER，留空跳过 $(family_name "$family")）: " chain
    [[ -n "$chain" ]] || continue
    if ! chain_exists "$bin" "$chain"; then
      warn "$chain 不存在，跳过。"
      continue
    fi
    read -r -p "输入规则编号: " number
    if [[ ! "$number" =~ ^[0-9]+$ ]]; then
      warn "编号无效，跳过。"
      continue
    fi
    backup_once
    "$bin" -D "$chain" "$number"
    ok "已删除 $(family_name "$family") $chain 第 $number 条。"
  done
  if confirm "是否立即保存规则"; then
    for_each_family "$families" save_rules
  fi
}

save_menu() {
  for_each_family "$(select_family)" save_rules
}

restore_menu() {
  local families
  families="$(select_family)"
  warn "恢复会覆盖当前运行中的规则。"
  if confirm "确认从默认规则文件恢复"; then
    for_each_family "$families" restore_rules
  fi
}

ensure_rule_at_top() {
  local bin="$1"
  local chain="$2"
  shift 2
  if "$bin" -C "$chain" "$@" >/dev/null 2>&1; then
    return
  fi
  "$bin" -I "$chain" 1 "$@"
}

ensure_rule_at_end() {
  local bin="$1"
  local chain="$2"
  local insert_at
  shift 2
  if "$bin" -C "$chain" "$@" >/dev/null 2>&1; then
    return
  fi
  insert_at="$(first_terminal_line "$bin" "$chain")"
  if [[ -n "$insert_at" ]]; then
    "$bin" -I "$chain" "$insert_at" "$@"
  else
    "$bin" -A "$chain" "$@"
  fi
}

ensure_docker_user_drop() {
  local bin="$1"
  local insert_at target
  insert_at="$(first_terminal_line "$bin" DOCKER-USER)"
  target="$(first_terminal_target "$bin" DOCKER-USER)"
  if [[ "$target" == "DROP" || "$target" == "REJECT" ]]; then
    return
  fi
  if [[ -n "$insert_at" ]]; then
    "$bin" -I DOCKER-USER "$insert_at" -j DROP
  else
    "$bin" -A DOCKER-USER -j DROP
  fi
}

enable_default_deny_family() {
  local family="$1"
  local bin
  bin="$(bin_for_family "$family")"

  if ! family_available "$family"; then
    warn "$(family_name "$family") 工具不存在，跳过。"
    return
  fi

  backup_once
  "$bin" -P INPUT DROP
  "$bin" -P FORWARD DROP
  "$bin" -P OUTPUT ACCEPT

  ensure_rule_at_top "$bin" INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ensure_rule_at_top "$bin" INPUT -i lo -j ACCEPT
  if [[ "$family" == "4" ]]; then
    ensure_rule_at_end "$bin" INPUT -p icmp --icmp-type 8 -j ACCEPT
  else
    ensure_rule_at_end "$bin" INPUT -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
    ensure_rule_at_end "$bin" INPUT -p ipv6-icmp --icmpv6-type neighbor-solicitation -j ACCEPT
    ensure_rule_at_end "$bin" INPUT -p ipv6-icmp --icmpv6-type neighbor-advertisement -j ACCEPT
    ensure_rule_at_end "$bin" INPUT -p ipv6-icmp --icmpv6-type router-advertisement -j ACCEPT
  fi

  if chain_exists "$bin" DOCKER-USER; then
    ensure_rule_at_top "$bin" DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ensure_docker_user_drop "$bin"
    ok "$(family_name "$family") 已启用默认拒绝，并补齐 DOCKER-USER 末尾 DROP。"
  else
    ok "$(family_name "$family") 已启用默认拒绝。DOCKER-USER 不存在，已跳过 Docker。"
  fi
}

enable_default_deny_menu() {
  local families ssh_port
  warn "这会把 INPUT 和 FORWARD 默认策略改成 DROP：未明确放行的端口会被拒绝。"
  warn "脚本会先放行 SSH，再补齐 lo、已建立连接、IPv6 邻居发现等基础规则。"
  ssh_port="$(read_default "SSH 保底端口，直接回车默认 $DEFAULT_SSH_PORT，必须放行否则可能连不上服务器" "$DEFAULT_SSH_PORT")"
  if ! valid_port_expr "$ssh_port"; then
    err "SSH 端口无效，取消。"
    return
  fi
  families="$(select_family)"
  if ! confirm "确认启用“未放行端口一律拒绝”"; then
    warn "已取消。"
    return
  fi

  for family in 4 6; do
    [[ "$families" == *"$family"* ]] || continue
    if family_available "$family"; then
      add_accept_rule "$family" INPUT tcp "$ssh_port" ""
    fi
    enable_default_deny_family "$family"
  done

  if confirm "是否立即保存规则"; then
    for_each_family "$families" save_rules
  else
    warn "未保存，重启或防火墙恢复后可能回到旧规则。"
  fi
}

policy_for_chain() {
  local bin="$1"
  local chain="$2"
  "$bin" -S "$chain" 2>/dev/null | awk -v chain="$chain" '$1 == "-P" && $2 == chain {print $3; exit}'
}

policy_label() {
  local policy="$1"
  case "$policy" in
    ACCEPT) printf "%s默认允许%s" "$YELLOW" "$RESET" ;;
    DROP) printf "%s默认拒绝%s" "$GREEN" "$RESET" ;;
    REJECT) printf "%s默认拒绝%s" "$GREEN" "$RESET" ;;
    "") printf "未知" ;;
    *) printf "%s" "$policy" ;;
  esac
}

print_family_status() {
  local family="$1"
  local bin input_policy forward_policy
  bin="$(bin_for_family "$family")"
  if ! family_available "$family"; then
    return
  fi
  input_policy="$(policy_for_chain "$bin" INPUT)"
  forward_policy="$(policy_for_chain "$bin" FORWARD)"
  printf "%s: INPUT=%s (%s)  FORWARD=%s (%s)\n" \
    "$(family_name "$family")" \
    "${input_policy:-未知}" "$(policy_label "$input_policy")" \
    "${forward_policy:-未知}" "$(policy_label "$forward_policy")"
}

ssh_rule_status() {
  local family="$1"
  local port="$2"
  local bin
  bin="$(bin_for_family "$family")"
  if ! family_available "$family"; then
    return
  fi
  if rule_exists "$bin" INPUT tcp "$port" ""; then
    printf "%s: SSH tcp/%s 已放行\n" "$(family_name "$family")" "$port"
  else
    printf "%s: %sSSH tcp/%s 未检测到放行规则%s\n" "$(family_name "$family")" "$YELLOW" "$port" "$RESET"
  fi
}

print_default_deny_summary() {
  local input4 input6
  input4=""
  input6=""
  if has_cmd iptables; then input4="$(policy_for_chain iptables INPUT)"; fi
  if has_cmd ip6tables; then input6="$(policy_for_chain ip6tables INPUT)"; fi

  if [[ "$input4" == "ACCEPT" || "$input6" == "ACCEPT" ]]; then
    warn "当前存在 INPUT 默认 ACCEPT：未匹配到拒绝规则的入站端口会默认放行。"
    warn "如果要白名单模式，请返回主菜单选 9：启用未放行端口一律拒绝。"
  elif [[ "$input4" == "DROP" || "$input6" == "DROP" || "$input4" == "REJECT" || "$input6" == "REJECT" ]]; then
    ok "当前没有检测到 INPUT 默认 ACCEPT：未放行端口默认拒绝。"
  fi
}

print_accept_ports_for_chain() {
  local family="$1"
  local chain="$2"
  local bin save_cmd label count
  bin="$(bin_for_family "$family")"
  save_cmd="$(save_cmd_for_family "$family")"
  label="$(family_name "$family")"
  count=0

  if ! family_available "$family" || ! has_cmd "$save_cmd" || ! chain_exists "$bin" "$chain"; then
    return 1
  fi

  "$save_cmd" -t filter 2>/dev/null | awk -v chain="$chain" -v label="$label" '
    $1 == "-A" && $2 == chain && $0 ~ / -j ACCEPT( |$)/ {
      proto = "all"
      dport = ""
      sport = ""
      src = "any"
      for (i = 3; i <= NF; i++) {
        if ($i == "-p" && (i + 1) <= NF) proto = $(i + 1)
        if (($i == "--dport" || $i == "--dports") && (i + 1) <= NF) dport = $(i + 1)
        if (($i == "--sport" || $i == "--sports") && (i + 1) <= NF) sport = $(i + 1)
        if ($i == "-s" && (i + 1) <= NF) src = $(i + 1)
      }
      if (dport != "") {
        printf "  %s %-11s %-5s %-15s 来源 %s\n", label, chain, proto, dport, src
        found = 1
      }
    }
    END { if (found) exit 0; exit 1 }
  ' && count=1 || count=0

  if [[ "$count" -eq 0 ]]; then
    return 1
  fi
  return 0
}

print_allowed_ports_summary() {
  local printed=0
  local family bin
  printf "\n%s已放行端口%s\n" "$BOLD" "$RESET"
  for family in 4 6; do
    if print_accept_ports_for_chain "$family" INPUT; then
      printed=1
    fi
  done
  if [[ "$printed" -eq 0 ]]; then
    printf "  未检测到 INPUT 链 tcp/udp 端口放行规则。\n"
  fi

  printed=0
  for family in 4 6; do
    bin="$(bin_for_family "$family")"
    if family_available "$family" && chain_exists "$bin" DOCKER-USER; then
      if [[ "$printed" -eq 0 ]]; then
        printf "\n%sDocker 已放行端口%s\n" "$BOLD" "$RESET"
      fi
      if print_accept_ports_for_chain "$family" DOCKER-USER; then
        printed=1
      fi
    fi
  done
}

status_menu() {
  printf "\n%s系统信息%s\n" "$BOLD" "$RESET"
  uname -a
  printf "\niptables: "
  if has_cmd iptables; then iptables --version; else printf "不存在\n"; fi
  printf "ip6tables: "
  if has_cmd ip6tables; then ip6tables --version; else printf "不存在\n"; fi
  if has_cmd docker; then
    printf "docker: "
    docker --version
  fi

  printf "\n%s默认动作%s\n" "$BOLD" "$RESET"
  print_family_status 4
  print_family_status 6
  print_default_deny_summary

  printf "\n%sSSH 保底端口%s\n" "$BOLD" "$RESET"
  ssh_rule_status 4 "$DEFAULT_SSH_PORT"
  ssh_rule_status 6 "$DEFAULT_SSH_PORT"

  print_allowed_ports_summary

  if { has_cmd iptables && chain_exists iptables DOCKER-USER; } || { has_cmd ip6tables && chain_exists ip6tables DOCKER-USER; }; then
    printf "\n%sDocker 链%s\n" "$BOLD" "$RESET"
    if has_cmd iptables && chain_exists iptables DOCKER-USER; then ok "IPv4 DOCKER-USER 存在"; fi
    if has_cmd ip6tables && chain_exists ip6tables DOCKER-USER; then ok "IPv6 DOCKER-USER 存在"; fi
  fi
}

install_autorestore() {
  local families restore_script service_file
  families="$(select_family)"
  restore_script="/usr/local/sbin/iptables-restore-all.sh"
  backup_once

  cat > "$restore_script" <<EOF
#!/bin/sh
set -e
EOF
  if [[ "$families" == *"4"* ]]; then
    cat >> "$restore_script" <<EOF
if command -v iptables-restore >/dev/null 2>&1 && [ -f "$IPV4_RULES_FILE" ]; then
  iptables-restore < "$IPV4_RULES_FILE"
fi
EOF
  fi
  if [[ "$families" == *"6"* ]]; then
    cat >> "$restore_script" <<EOF
if command -v ip6tables-restore >/dev/null 2>&1 && [ -f "$IPV6_RULES_FILE" ]; then
  ip6tables-restore < "$IPV6_RULES_FILE"
fi
EOF
  fi
  chmod +x "$restore_script"

  if [[ -d /etc/network/if-pre-up.d ]]; then
    cat > /etc/network/if-pre-up.d/iptables-restore-all <<EOF
#!/bin/sh
$restore_script
EOF
    chmod +x /etc/network/if-pre-up.d/iptables-restore-all
    ok "已安装 Debian/Ubuntu if-pre-up 自动恢复脚本。"
  fi

  if has_cmd systemctl && [[ -d /etc/systemd/system ]]; then
    service_file="/etc/systemd/system/iptables-restore-all.service"
    cat > "$service_file" <<EOF
[Unit]
Description=Restore iptables and ip6tables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$restore_script
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable iptables-restore-all.service
    ok "已安装 systemd 自动恢复服务：iptables-restore-all.service"
  fi
}

emergency_allow_all() {
  warn "这会临时放通所有 IPv4/IPv6 入站，并清空 filter 表规则。适合控制台救急，不建议长期使用。"
  read -r -p "确认请输入 ALLOW: " answer
  [[ "$answer" == "ALLOW" ]] || { warn "已取消。"; return; }
  backup_once
  if has_cmd iptables; then
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    ok "IPv4 已临时全放通。"
  fi
  if has_cmd ip6tables; then
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables -F
    ok "IPv6 已临时全放通。"
  fi
}

reset_baseline() {
  local families ssh_port extra_ports port family
  warn "完全重置会清空 filter 表规则，并设置 INPUT/FORWARD 默认 DROP。"
  warn "如果 SSH 端口填错，可能会断开远程连接。建议先确认云厂商控制台可用。"
  read -r -p "确认请输入 RESET: " answer
  [[ "$answer" == "RESET" ]] || { warn "已取消。"; return; }

  families="$(select_family)"
  ssh_port="$(read_default "SSH 保底端口，直接回车默认 $DEFAULT_SSH_PORT" "$DEFAULT_SSH_PORT")"
  if ! valid_port_expr "$ssh_port"; then
    err "SSH 端口无效，取消。"
    return
  fi
  extra_ports="$(ask_ports_optional "额外保留端口")"
  backup_once

  for family in 4 6; do
    [[ "$families" == *"$family"* ]] || continue
    if ! family_available "$family"; then
      warn "$(family_name "$family") 工具不存在，跳过。"
      continue
    fi
    local bin
    bin="$(bin_for_family "$family")"
    "$bin" -F
    "$bin" -X
    "$bin" -P INPUT DROP
    "$bin" -P FORWARD DROP
    "$bin" -P OUTPUT ACCEPT
    "$bin" -A INPUT -i lo -j ACCEPT
    "$bin" -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    "$bin" -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
    if [[ "$family" == "4" ]]; then
      "$bin" -A INPUT -p icmp --icmp-type 8 -j ACCEPT
    else
      "$bin" -A INPUT -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
      "$bin" -A INPUT -p ipv6-icmp --icmpv6-type neighbor-solicitation -j ACCEPT
      "$bin" -A INPUT -p ipv6-icmp --icmpv6-type neighbor-advertisement -j ACCEPT
      "$bin" -A INPUT -p ipv6-icmp --icmpv6-type router-advertisement -j ACCEPT
    fi
    read -r -a EXTRA_PORTS <<< "$extra_ports"
    for port in "${EXTRA_PORTS[@]}"; do
      port="${port//[[:space:]]/}"
      [[ -n "$port" ]] || continue
      if valid_port_expr "$port"; then
        "$bin" -A INPUT -p tcp --dport "$port" -j ACCEPT
      else
        warn "跳过无效端口：$port"
      fi
    done
    ok "$(family_name "$family") 基础规则已重置。"
  done

  if has_cmd systemctl && systemctl list-unit-files docker.service >/dev/null 2>&1; then
    if confirm "检测到 Docker，是否重启 Docker 以重建 Docker 防火墙链"; then
      systemctl restart docker
      ok "Docker 已重启。"
    else
      warn "未重启 Docker。若本机使用 Docker，容器网络可能需要手动重启 Docker 后恢复。"
    fi
  fi

  if confirm "是否立即保存重置后的规则"; then
    for_each_family "$families" save_rules
  else
    warn "未保存，重启或恢复后可能回到旧规则。"
  fi
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf "%sVPS iptables 防火墙菜单%s  %s\n" "$BOLD" "$RESET" "$VERSION"
    printf "规则文件：IPv4=%s  IPv6=%s\n" "$IPV4_RULES_FILE" "$IPV6_RULES_FILE"
    printf "SSH 保底端口：%s\n" "$DEFAULT_SSH_PORT"
    printf "备份目录：%s\n\n" "$BACKUP_DIR"
    printf "  1) 查看状态\n"
    printf "  2) 查看规则编号\n"
    printf "  3) 开放端口 / 服务\n"
    printf "  4) 关闭端口 / 服务\n"
    printf "  5) 按规则编号删除\n"
    printf "  6) 保存当前规则\n"
    printf "  7) 从默认文件恢复规则\n"
    printf "  8) 安装开机自动恢复\n"
    printf "  9) 启用未放行端口一律拒绝\n"
    printf " 10) 批量导入服务配置 CSV\n"
    printf " 11) 应急：临时全放通\n"
    printf " 12) 完全重置为基础规则\n"
    printf "  0) 退出\n\n"
    read -r -p "请选择: " choice
    case "$choice" in
      1) status_menu; pause ;;
      2) list_all_rules; pause ;;
      3) open_port_menu; pause ;;
      4) close_port_menu; pause ;;
      5) delete_by_number_menu; pause ;;
      6) save_menu; pause ;;
      7) restore_menu; pause ;;
      8) install_autorestore; pause ;;
      9) enable_default_deny_menu; pause ;;
      10) batch_import_menu; pause ;;
      11) emergency_allow_all; pause ;;
      12) reset_baseline; pause ;;
      0) exit 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

need_root
require_iptables
main_menu
