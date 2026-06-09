# VPS iptables 防火墙菜单脚本使用说明

脚本位置：

```bash
wget -O vps-firewall-menu.sh https://raw.githubusercontent.com/wesleeyleeo/iptables_control/main/vps-firewall-menu.sh && chmod +x vps-firewall-menu.sh && sudo ./vps-firewall-menu.sh
```

## 能做什么

- 查看 IPv4/IPv6 的 `INPUT` 和 `DOCKER-USER` 规则编号
- 菜单式开放/关闭端口，支持 TCP、UDP、端口范围，也支持空格分隔一次输入多个端口
- 支持只开放主机端口、只开放 Docker 容器端口，或者两个都开放
- 自动检测 VPS 是否存在 Docker 的 `DOCKER-USER` 链，不存在就跳过
- 每次修改前自动备份到 `/root/iptables-backups`
- 修改后可选择保存到：
  - IPv4：`/etc/iptables.rules`
  - IPv6：`/etc/ip6tables.rules`
- 可安装开机自动恢复
- 可启用“未放行端口一律拒绝”白名单模式
- 支持用 CSV 批量导入一组服务端口
- 可安装 `fw` 快捷命令，之后直接输入 `fw` 打开菜单
- 提供应急全放通和基础规则重置

## Docker 端口要注意

如果容器这样映射：

```bash
docker run -p 23656:5230 ...
```

开放时建议选“两个都处理”：

- `INPUT` 填 `23656`
- `DOCKER-USER` 填 `5230`

原因是 Docker 做完 DNAT 后，`DOCKER-USER` 里看到的一般是容器内部端口。

## 推荐流程

1. 先选 `1) 查看状态`
2. 再选 `2) 查看规则编号`
3. 开服务选 `3) 开放端口 / 服务`
4. 关闭服务选 `4) 关闭端口 / 服务`
5. 需要白名单模式时选 `9) 启用未放行端口一律拒绝`
6. 服务很多时选 `10) 批量导入服务配置 CSV`
7. 操作完成后选择保存规则
8. 第一次使用建议执行 `8) 安装开机自动恢复`
9. 想以后直接输入 `fw` 时，选 `13) 安装/更新 fw 快捷命令`

## 快捷命令

菜单第 `13` 项会安装：

- 主脚本：`/usr/local/sbin/vps-firewall-menu.sh`
- 快捷命令：`/usr/local/bin/fw`

安装后直接执行：

```bash
fw
```

如果当前用户不是 root，`fw` 会自动调用 `sudo`。

## 一次输入多个端口

在菜单里开放或关闭端口时，用空格分隔：

```text
22 80 443 47624 3000:3010
```

端口范围也可以和单端口混用。不要用逗号。

## 未放行端口一律拒绝

菜单第 `9` 项会把防火墙切到白名单模式：

- `INPUT DROP`：没明确开放的主机端口不允许访问
- `FORWARD DROP`：没明确开放的转发流量不允许访问
- `OUTPUT ACCEPT`：服务器主动访问外网不受影响
- 自动补齐本机回环、已建立连接、IPv6 邻居发现等基础规则
- 如果存在 Docker 的 `DOCKER-USER` 链，会在末尾补 `DROP`

执行前会让你确认 SSH 端口，默认是 `22`。脚本会先放行 SSH，再切换默认拒绝，避免把自己挡在外面。

如果你的 SSH 不是 22，可以在菜单里输入真实端口，或者执行脚本前指定：

```bash
sudo DEFAULT_SSH_PORT=2222 ./vps-firewall-menu.sh
```

## 批量导入

示例文件：

```bash
/Downloads/vps-firewall-services.example.csv
```

CSV 格式：

```text
name,family,target,protocol,input_port,docker_port,source
```

- `family`：`4`、`6`、`46`
- `target`：`input`、`docker`、`both`
- `protocol`：`tcp`、`udp`、`both`
- `input_port`：主机端口或 Docker 外部映射端口
- `docker_port`：Docker 容器内部端口
- `source`：来源 IP/CIDR，留空表示所有来源

## 安全提醒

- 远程 VPS 上不要随便执行“完全重置”，除非确认 SSH 端口填写正确，并且云厂商控制台/VNC 可用。
- IPv6 不要全挡 ICMPv6，脚本的基础重置会保留邻居发现需要的 ICMPv6。
- 如果规则改错，菜单里的“应急：临时全放通”适合在云控制台登录后救急。
