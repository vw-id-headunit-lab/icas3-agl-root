# 持久化钩子

## 目标

重启后自动恢复 root 远程访问，不需要人工介入，并且**尽量不动厂商文件**。

## 先看清：哪一步需要键盘

持久化链本身（开机自动拉起 sshd）**不需要键盘**，但它的**前置**和**兜底**都需要：

| 阶段 | 何时 | 需要键盘？ | 内容 |
|---|---|---|---|
| **0 首次部署** | 只做一次 | ✅ **需要** | 进控制台 → 上传脚本 → 改 `wlan_startup.sh` → 手动验证 → 重启验证 |
| **1 自动恢复** | 每次开机 | ❌ 不需要 | `wlan_startup.sh` → `hook.sh` → `systemd-run` → `serve.sh` → `sshd:22` |
| **2 故障恢复** | 出错时 | ✅ **必须** | 进控制台 → 回滚 → 重启 |

**这不是可选项**：设备上没有第二条独立于网络的入口，网络一旦断掉，物理控制台是唯一出路。
所以**动手前必须先用键盘确认能进 root**（见 [disclaimer.md](disclaimer.md)）。

### 阶段 0 的完整动作（从零到自启）

**0.1 建立网络**

车机自己开 Wi-Fi 热点（SSID/开关在车机设置里），网段 `<LAB_SUBNET>`；笔电接入后
AGL 是 `<AGL_IP>`。

```sh
ip route | grep 10.173.189       # 笔电应有一条到该网段的路由
ping -c 3 <AGL_IP>               # 通才继续
```

**0.2 用键盘进控制台**

```text
USB 键盘（或 ESP32 HID / BadUSB）→ Alt+F3（或 Ctrl+Alt+F1）
→ root → 空密码回车 → uid=0
```

此时设备上**没有任何远程入口**，所有操作都在这块键盘上敲。

**0.3 在控制台里建第一个远程入口（4445）**

没有它，后面的文件只能靠键盘手敲。

```sh
echo | /bin/busybox.suid su root -c '
  /usr/sbin/iptables -C INPUT -s <LAB_SUBNET> -p tcp --dport 4445 -j ACCEPT 2>/dev/null || \
  /usr/sbin/iptables -I INPUT -s <LAB_SUBNET> -p tcp --dport 4445 -j ACCEPT
  /usr/bin/socat TCP-LISTEN:4445,reuseaddr,fork EXEC:/bin/sh,pty >/dev/null 2>&1 &
'
```

笔电验证：

```sh
printf 'id\n' | nc -w 5 <AGL_IP> 4445     # 期望 uid=0(root)
```

**0.4 传脚本到车机**

```sh
# 笔电：在 scripts/ 目录起临时服务
python3 -m http.server 8010
# AGL（经 4445 shell）：
wget -q -O /data/lge/wlan/serve.sh http://<笔电IP>:8010/serve.sh
wget -q -O /data/lge/wlan/hook.sh  http://<笔电IP>:8010/hook.sh
chmod 755 /data/lge/wlan/*.sh
```

**0.5 备份并插入调用**

```sh
cp -a /lge/app_rw/wlan/wlan_startup.sh /data/lge/wlan_startup.sh.bak
sed -i '2i /data/lge/wlan/hook.sh >/dev/null 2>&1 &' /lge/app_rw/wlan/wlan_startup.sh
head -3 /lge/app_rw/wlan/wlan_startup.sh
```

**0.6 先手动验证，不要直接重启**

```sh
sh /data/lge/wlan/hook.sh && sleep 5
systemctl is-active sshd-persistent.service
netstat -lnt | grep ':22 '
```

**0.7 从笔电登录并验证自愈**

```sh
ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP> 'id'
ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP> 'pkill -f "sshd -D -e -h /data/lge/ssh"'
sleep 10
ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP> 'systemctl is-active sshd-persistent'
```

**0.8 重启验证**

```sh
reboot
ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP> 'id; systemctl is-active sshd-persistent'
```

**只有到这里**，才可以把 4445 收窄或关闭。

## 硬约束：根文件系统只读

```text
/dev/dm-0 on / type ext4 (ro,...)
dm-mod.create="dm-verity,,,ro, ... sha256 <hash> ..."
```

- `/etc`、`/lib/systemd/system`、`/usr` 均不可写；
- systemd 只扫描 `/etc/systemd/system`、`/run/systemd/system`（tmpfs，重启清空）、`/lib/systemd/system`；
- ⇒ **无法新建"开机自动加载"的 unit 文件**。

可写分区只有 `/data`、`/lge/app_rw`、`/vw`。

## 可用的挂载点

厂商 unit 里硬编码了若干 `/lge/app_rw/...` 路径（没有通用钩子机制）：

```text
wlanmgr.service:  ExecStart=/bin/sh /lge/app_rw/wlan/wlan_startup.sh
btapp.service:    ExecStart=/bin/sh /lge/app_rw/bt/btapp_boot.sh
carplay.service:  ExecStart=/lge/app_rw/smartlink/carplay/carplay
```

这些都是**可写、且被 unit 引用**的脚本 → 可作为开机触发点。

本仓库使用 `wlan_startup.sh`（第 2 行插入一行调用）。

## 结构

```text
/lge/app_rw/wlan/wlan_startup.sh
  └─ /data/lge/wlan/hook.sh
       └─ systemd-run --unit=sshd-persistent.service
            --property=Restart=always --property=RestartSec=5s --property=KillMode=process
            └─ /data/lge/wlan/serve.sh
```

`serve.sh` 依次：

1. 等 `firewall-manager.service` 初始化完成（最多 60 s）——避免 iptables 规则被防火墙清掉；
2. 主机密钥持久化到 `/data/lge/ssh/`；
3. `systemctl mask --runtime --now sshd.socket` + `stop sshd.service`——腾出 22 端口；
4. `iptables` 只放行本网段；
5. 端口占用检查；
6. `exec sshd -D`（密钥认证）。

## 日志与排错

`serve.sh` 把输出写到 `/data/lge/ssh/boot-hook.log`（超过 256 KB 自动轮转为 `.1`），
并用 `trap` 记录退出阶段，失败时最后一行形如：

```text
hook exit=1 stage=free-port
```

| stage | 含义 |
|---|---|
| `entry` | 刚进入脚本 |
| `wait-firewall` | 等 `firewall-manager.service` |
| `host-key` | 生成/复用主机密钥、`sshd -t` 自检 |
| `free-port` | `mask --runtime sshd.socket` + `stop sshd.service` |
| `firewall` | 加定向 iptables 规则 |
| `check-port` | 端口占用检查 |
| `start-sshd` | `exec sshd -D` |

排错顺序：先看 `stage`，再看该阶段的命令是否成功（例如 `free-port` 失败通常是
`sshd.socket` 已被别的进程占用或 mask 失败）。

## 为什么要 background

这些厂商脚本所在 unit 大多带：

```ini
FailureAction=reboot-immediate
```

注入行若影响脚本退出码，会直接把整车打进重启循环。因此调用必须后台执行：

```sh
/data/lge/wlan/hook.sh >/dev/null 2>&1 &
```

## 幂等

`hook.sh` 先判断单元是否已 active，避免重复启动：

```sh
if ! systemctl is-active --quiet "$U"; then
  systemd-run --unit="$U" ... &
fi
```

## 验证

```sh
systemctl is-active sshd-persistent.service   # active
netstat -lnt | grep ':22 '                    # LISTEN
pkill -f "sshd -D -e -h /data/lge/ssh"; sleep 8
systemctl is-active sshd-persistent.service   # 仍为 active（自愈）
```

重启后再验一次上述三条。

## 回滚

```sh
cp /data/lge/wlan/hook.sh.bak /data/lge/wlan/hook.sh
systemctl stop sshd-persistent.service
systemctl unmask --runtime sshd.socket && systemctl start sshd.socket
```

`mask --runtime` 本身重启即失效。

## 已知风险

- 修改厂商脚本存在被完整性校验发现的可能（本平台未观察到）；
- 整包刷写会覆盖 `/lge/app_rw` 下的修改；
- 停用固件 `sshd.socket` 在本次开机内会移除厂商默认 SSH。
