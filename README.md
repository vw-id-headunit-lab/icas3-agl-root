# icas3 AGL Root

[简体中文](#简体中文) | [English](#english)

## 概述 / Overview

本仓库只包含**脚本与文档**，不包含固件、厂商二进制、提取的接口类、车辆数据或机器相关配置。

记录一台大众 ID.3（2021，中国，ICAS3 车机，SW 2995）上的三件事：

1. **AGL（VM3）取得 root** —— 空 root 密码 + 可触达的登录控制台；
2. **持久化钩子** —— 借厂商启动脚本拉起 systemd 单元，开机自动恢复；
3. **Android（VM4）adb 通道** —— 经 AGL 中继访问 Android adbd。

> **平台**：MEB Gen1 / ICAS3 SW 2995 / Exynos Auto V9，QNX + AGL + Android 三 guest。
> 文中 `<LAB_SUBNET>` / `<AGL_IP>` / `<ANDROID_IP>` / `<LOCAL_KEY>` 为占位符。
> 本固件的出厂默认值分别是 `10.173.189.0/24`、`10.173.189.1`、`192.168.0.99`
> （均写在厂商只读分区的 `firewall_rules.IPv4` / `rule_handle.sh` 里，**同型号每台车相同**）；
> 若你的车改过网络配置，请以实际为准。密钥填你自己的私钥路径。

## 免责声明 / Disclaimer

> **仅限你自己的车辆，风险自负。**
> 本项目会在 `/data` 下新增两个脚本、在厂商启动脚本里**插入一行调用**，
> 并在运行时**接管 22 端口**（固件 sshd 文件不动，仅本次开机被 mask）与调整防火墙规则。
> **最坏后果是车机反复重启、再也连不上，只能靠 USB 键盘进控制台现场恢复。**
> 作者不对任何损失负责。

**按步骤分级的风险**（完整版见 [docs/disclaimer.md](docs/disclaimer.md)）：

| 步骤 | 风险 | 可回滚 |
|---|---|---|
| 键盘进控制台、登录 root | 🟢 低 | — |
| **改 `wlan_startup.sh`** | 🔴 **高**（unit 为 `FailureAction=reboot-immediate`，写错即重启循环） | 需物理控制台 |
| 放置 `hook.sh` / `serve.sh` | 🟢 低 | 删文件 |
| `mask --runtime sshd.socket` | 🟡 中（本次开机移除厂商 SSH） | 重启复原 |
| 改 `iptables` | 🟡 中（写错会锁死自己） | 重启复原 |
| `reboot` 验证 | 🟡 中（唯一会暴露 hook 错误的时刻） | 物理控制台 |
| ADB 中继 | 🟢 低 | 重启复原 |

**开工前必做**：备份 `wlan_startup.sh`、`iptables-save`、**先确认 USB 键盘能进 root 控制台**
（断网后唯一的恢复通道）。**做不到最后一条不要开始。**

**面向厂商**：本仓库是对一处**配置缺陷**的记录，目标设备为作者本人车辆；**不含**固件、厂商二进制、
接口类、车辆数据或凭据。**本项目与大众汽车集团及任何供应商无隶属、赞助或背书关系。**
若需复现细节或讨论修复，请通过 Issue 联系。

**法律**：本项目只使用设备自身提供的接口（控制台登录、`systemd`、`iptables`、`sshd`），
并在 `/data` 下新增自己的脚本；**厂商二进制未做任何改动**。
改装车辆可能影响保修与合规，请自行确认并遵守当地法律。

---

## 简体中文

### 目录

- [当前状态](#当前状态)
- [支持的车型](#支持的车型)
- [前置条件](#前置条件)
- [仓库结构](#仓库结构)
- [AGL root](#agl-root)
- [持久化钩子](#持久化钩子)
- [Android adb 通道](#android-adb-通道)
- [快速开始](#快速开始)
- [验证](#验证)
- [卸载与恢复原状](#卸载与恢复原状)
- [常见问题](#常见问题)
- [边界与不包含的内容](#边界与不包含的内容)
- [致谢](#致谢)
- [许可证](#许可证)

### 当前状态

- **已在实车验证**：AGL root、持久化 SSH、重启后自动恢复、自愈、Android adb 通道；
- **验证机型**：ID.3（2021–2023）、ID.4 X（2021–2023）；
- **平台**：MEB Gen1 / ICAS3 / Exynos Auto V9（QNX + AGL + Android 三 guest）；
- 其他车型与代际见下一个表。

### 支持的车型

| 车型 | 年款 | 车机平台 | 状态 |
|---|---|---|---|
| **ID.3** | **2021 / 2022 / 2023** | ICAS3（MEB Gen1） | ✅ **已实测** |
| **ID.4 X** | **2021 / 2022 / 2023** | ICAS3（MEB Gen1） | ✅ **已实测** |
| ID.4 CROZZ | 2021 / 2022 / 2023 | ICAS3（同代） | ⚠️ **未验证** |
| ID.3 / ID.4 X **Gen2** | 2024 起 | ICAS3 + ID.S 5.0（**MEB Gen2**） | ❌ 不适用 |

**代际划分**：

- **Gen1**（2021–2023）：**ICAS3** 车机，MEB Gen1，本仓库的目标平台；
- **Gen2**（2024 起）：硬件同属 **ICAS3** 家族，但软件平台换成 **ID.S 5.0**（MEB Gen2）、
  12.9 英寸屏，系统版本与分区布局不同，**本仓库未验证、不适用**。

**两步确认**（Gen1 与 Gen2 都属 ICAS3 家族，所以还要看软件版本）：

1. **先确认是 ICAS3 家族** —— 在 AGL 里执行：

   ```sh
   uname -r                                    # ICAS3 为 4.14.137-*
   ls /lge/app_ro/network/firewall_rules.IPv4  # 存在即为 ICAS3（LG 车机）
   ```

2. **再看软件版本** —— 车机「系统信息 → 软件版本」：

   | 显示 | 判定 |
   |---|---|
   | **SW 2995**（或其他 2xxx/3xxx 编号） | **Gen1**，本仓库适用 |
   | **ID.S 5.0** 系列 | **Gen2**，本仓库不适用 |

   注意：AGL 里的 `/etc/os-release` 只显示 `Samsung Embedded Linux 2.6.1`，
   **看不出整车软件版本**，必须到车机界面上看。

### 前置条件

| 项 | 要求 | 说明 |
|---|---|---|
| 车辆 | **你拥有所有权或获授权** | 租赁车、公司车、他人车辆不适用 |
| 物理通道 | 车机 USB 口可接键盘（或 ESP32/BadUSB） | **必需**，见 [AGL root](#agl-root) |
| 车机固件 | ICAS3 SW 2995（本仓库验证过的版本） | 其他版本需自行验证 |
| 笔电（宿主机） | Linux/macOS，含 `ssh`、`adb`、`socat`、`curl` | 用于连接、传文件与调试 |
| **车机热点** | 车机 Wi-Fi 热点已开启，笔电可接入 | 提供 `<LAB_SUBNET>`，AGL 为 `<AGL_IP>` |
| 网络 | 笔电与 AGL 同网段（`ping <AGL_IP>` 通） | 远程登录与 adb 中继 |
| 风险接受 | 明白可能失去远程访问、需到车旁恢复 | 见 [免责声明](#免责声明--disclaimer) |

### 仓库结构

```text
icas3-agl-root/
├── README.md                 本文件（中文 + English）
├── LICENSE                   MIT（仅覆盖自编代码与文档）
├── THIRD_PARTY_NOTICES.md    致谢与第三方声明
├── docs/
│   ├── agl-root.md           三种入口方式、证据、为什么算配置缺陷
│   ├── persistence.md        dm-verity 约束、挂载点选择、三阶段生命周期、回滚
│   ├── android-adb.md        拓扑、四步命令、注意事项、回滚
│   └── disclaimer.md         完整免责声明（车主 / 厂商 / 法律）
└── scripts/
    ├── serve.sh              服务实现（等防火墙 → 密钥 → mask → sshd -D）
    ├── hook.sh               开机触发器（受限 iptables + 兜底 + systemd-run，幂等）
    └── adb-setup.sh          ADB 中继（等隔离链 → 三条规则 → socat）
```

### AGL root

这**不是代码缺陷，而是配置缺陷**：

| 事实 | 值 |
|---|---|
| `/etc/shadow` 中 root 的密码字段 | 空（`root::…`），且是全系统唯一空密码账户 |
| `login` 行为 | 接受空密码登录 → `uid=0` |
| `busybox.suid su` | 接受空密码（非 root → `su root -c id` → `uid=0`） |
| 入口 | 车机 USB 口插入 **USB HID 键盘** → 切到控制台 → getty |

拿到本地 root 后，先在控制台里起一个临时 shell（socat）用来传文件，
再换成密钥认证的 SSH —— 具体步骤见「[持久化钩子](#持久化钩子)」的第 2–5 步。

#### 进入控制台的三种方式

**方式 A：物理 USB 键盘**（最直接）

```text
USB 键盘 → Alt+F3（或 Ctrl+Alt+F1）→ 用户名 root → 密码直接回车 → uid=0
```

**方式 B：ESP32-S3 USB HID 键盘模拟**（有现成网页，推荐）

使用合作伙伴的项目 **[esp32-hid-web](https://github.com/vw-id-headunit-lab/esp32-hid-web)**
（感谢 [NullYing](https://github.com/NullYing) 分享）。板子插上就被识别成 USB 键盘，
**自带操作网页，点点鼠标就行，不需要写脚本**：

```text
ESP32-S3（原生 USB/OTG）──USB 数据线──> 车机 Type-C
手机连热点 S3-HID-XXXXXX（密码 esp32hid123）
浏览器打开 http://192.168.4.1    ← 等页面显示「USB 已连接」
```

网页上的操作顺序：

| 步骤 | 在网页上做什么 |
|---|---|
| 1 | 「目标系统」选 **Linux** |
| 2 | 点组合键按钮 **Ctrl+Alt+F1**，切到车机控制台 |
| 3 | 在文本框输入 `root`，点「发送到 USB」（会自动回车） |
| 4 | 点 **Enter**（空密码） |
| 5 | 看到 `uid=0` 即登录成功 |

> 想自动化时才用它的 HTTP API（`/api/key`、`/api/type`），细节见
> [项目 README](https://github.com/vw-id-headunit-lab/esp32-hid-web)。
> 注意它的按键白名单是 `CTRL_ALT_F1`，**没有 `Alt+F3`**；若你的固件只认 `Alt+F3`，用方式 A 或 C。

**方式 C：可编程键盘 / BadUSB**（离线、可重复、不依赖手机）

任何能枚举为 USB 键盘并回放脚本的设备都行（BadUSB、Flipper Zero 的 BadUSB、Digispark、
支持宏的机械键盘等）。写入下面的序列，插到车机 USB 口即可自动登录：

```text
DELAY 3000          # 等 USB 枚举 + getty 就绪
CTRL ALT F1         # 切控制台（若固件只认 Alt+F3，改成 ALT F3）
DELAY 1500
STRING root
ENTER
DELAY 800
ENTER               # 空密码
```

要点：

- **延时**必须留够（枚举 2–3 秒、切 VT 1–1.5 秒、登录提示 0.5–1 秒）；太快会丢键；
- 键盘布局按 **US** 处理，本例只输入 `root`，不受布局影响；
- 有些设备默认以「存储」而非「键盘」枚举，需改成 HID 模式；
- 相比方式 B，它**不需要热点、不需要网络**，适合现场一次性使用。

细节见 [docs/agl-root.md](docs/agl-root.md)。

### 持久化钩子

目标：**重启后自动恢复 root SSH，且不依赖手工操作**。

#### 完整生命周期（三阶段，注意哪一步需要键盘）

```text
┌─ 阶段 0：首次部署 —— 必须有键盘/控制台 ──────────────┐
│  USB 键盘 / ESP32 HID / BadUSB                       │
│      → getty → root（空密码）                        │
│      → 写入 /data/lge/wlan/serve.sh、hook.sh         │
│      → 在 wlan_startup.sh 第 2 行插入调用            │
│      → 手动跑一次 hook.sh，验证 22 端口可登录         │
│      → reboot 验证                                   │
└──────────────────────────────────────────────────────┘
                        ↓  成功后
┌─ 阶段 1：之后每次开机 —— 无需键盘 ───────────────────┐
│  wlanmgr.service                                     │
│    → /lge/app_rw/wlan/wlan_startup.sh                │
│      → /data/lge/wlan/hook.sh                        │
│        → systemd-run sshd-persistent.service         │
│          → /data/lge/wlan/serve.sh → sshd :22        │
└──────────────────────────────────────────────────────┘
                        ↓  任一环节失败
┌─ 阶段 2：恢复 —— 必须回到键盘/控制台 ────────────────┐
│  USB 键盘 → getty → root → 执行回滚 → reboot         │
└──────────────────────────────────────────────────────┘
```

> **要点**：持久化链只覆盖「阶段 1」。**阶段 0 和阶段 2 都依赖物理控制台**——
> 这也是 [docs/disclaimer.md](docs/disclaimer.md) 把「先确认键盘能进 root」列为开工前提的原因。

#### 端到端操作流程（从零到开机自启）

> 这一节是**真正动手的完整顺序**。注意第 0 步是网络、第 1 步是键盘——
> 两者缺一，后面的命令都没有地方执行。

**第 0 步 · 建立网络（笔电 ↔ 车机）**

车机会自己开一个 Wi-Fi 热点（SSID 与开关见车机设置），网段是 `<LAB_SUBNET>`；
笔电接入后拿到 `10.173.189.x`，AGL 是 `10.173.189.1`。

```sh
# 笔电：确认已连上车机热点，且能到 AGL
ip route | grep 10.173.189          # 应有一条 10.173.189.0/24 的路由
ping -c 3 <AGL_IP>                  # 通
```

**第 1 步 · 用键盘进控制台拿 root（此时还没有任何远程入口）**

```text
USB 键盘（或 ESP32 HID / BadUSB）插入车机
→ Alt+F3（或 Ctrl+Alt+F1）切到控制台
→ 用户名 root，密码直接回车
→ 得到 uid=0 的 shell
```

**第 2 步 · 在控制台里建第一个远程入口（4445）**

没有这一步，后续文件只能靠键盘手敲。用 `busybox.suid` 提权后起 socat：

```sh
echo | /bin/busybox.suid su root -c '
  /usr/sbin/iptables -C INPUT -s <LAB_SUBNET> -p tcp --dport 4445 -j ACCEPT 2>/dev/null || \
  /usr/sbin/iptables -I INPUT -s <LAB_SUBNET> -p tcp --dport 4445 -j ACCEPT
  /usr/bin/socat TCP-LISTEN:4445,reuseaddr,fork EXEC:/bin/sh,pty >/dev/null 2>&1 &
'
```

笔电验证：

```sh
nc -zv <AGL_IP> 4445           # 探测端口
printf 'id\n' | nc -w 5 <AGL_IP> 4445    # 应返回 uid=0(root)
```

**第 3 步 · 把脚本传到车机**

```sh
# 方式一：笔电起个临时 HTTP 服务，AGL 侧 wget
#   笔电： python3 -m http.server 8010 --directory ./icas3-agl-root/scripts
#   AGL ：
wget -q -O /data/lge/wlan/serve.sh http://<笔电IP>:8010/serve.sh
wget -q -O /data/lge/wlan/hook.sh  http://<笔电IP>:8010/hook.sh
chmod 755 /data/lge/wlan/*.sh

# 方式二：直接通过 4445 shell 用 heredoc 写（没有笔电 HTTP 服务时）
```

**第 4 步 · 备份并插入开机调用**

```sh
cp -a /lge/app_rw/wlan/wlan_startup.sh /data/lge/wlan_startup.sh.bak
sed -i '2i /data/lge/wlan/hook.sh >/dev/null 2>&1 &' /lge/app_rw/wlan/wlan_startup.sh
head -3 /lge/app_rw/wlan/wlan_startup.sh      # 确认第 2 行是调用
```

**第 5 步 · 先手动起一次，不等重启**

```sh
sh /data/lge/wlan/hook.sh && sleep 5
systemctl is-active sshd-persistent.service   # active
netstat -lnt | grep ':22 '                    # LISTEN
```

**第 6 步 · 从笔电登录新 SSH，并验证自愈**

```sh
ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP> 'id'   # uid=0(root)
# 自愈：杀掉再等 10 秒
ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP> 'pkill -f "sshd -D -e -h /data/lge/ssh"'
sleep 10 && ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP> 'systemctl is-active sshd-persistent'
```

**第 7 步 · 重启验证（唯一会暴露 hook 错误的时刻）**

```sh
reboot
# 起来后
ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP> 'id; systemctl is-active sshd-persistent'
```

> 到这一步才可以把 4445 收窄或关掉。**在新 SSH 验证通过之前，别删旧入口。**

#### 阶段 1 的结构

```text
/lge/app_rw/wlan/wlan_startup.sh     ← 厂商脚本，可写分区，wlanmgr.service 的 ExecStart
  └─ /data/lge/wlan/hook.sh          ← 我们插入的一行
       └─ systemd-run --unit=sshd-persistent.service
            --property=Restart=always --property=RestartSec=5s
            └─ /data/lge/wlan/serve.sh
                 ├─ 等 firewall-manager.service 就绪（≤60 秒）
                 ├─ 主机密钥持久化 /data/lge/ssh/
                 ├─ mask --runtime sshd.socket + stop sshd.service（腾出 22）
                 ├─ iptables 只放行 <LAB_SUBNET>
                 ├─ 端口占用检查
                 └─ exec sshd -D（密钥认证）
```

关键点：

- **挂载点**：根文件系统受 dm-verity 保护且只读，`/etc/systemd/system` 不可写，
  因此不能新建「开机自动加载」的 unit；唯一可行的是注入可写分区里被 unit 硬编码引用的脚本。
- **自愈**：`Restart=always`，sshd 被杀后 5 秒内恢复。
- **安全**：密钥认证 + 网段限制（不再使用无认证的裸 shell）。
- **风险**：这些厂商脚本所在 unit 多为 `FailureAction=reboot-immediate`，
  因此注入行必须后台执行（`&`），不得影响脚本退出码。

细节与回滚见 [docs/persistence.md](docs/persistence.md)。

### Android adb 通道

> **本节的思路来自合作伙伴 [NullYing](https://github.com/NullYing)，感谢分享。**

原理：AGL 有 root，是 Android 的网络网关；Android 的 `adbd` 在内部链路
`<ANDROID_IP>:5555` 监听，但被 `ANDROID_ISOLATION_*` 隔离链挡住。
在 AGL 上放行并做端口转发即可：

```sh
# 1) AGL → Android 5555
iptables -I ANDROID_ISOLATION_OUT_FILTER 1 -p tcp --dport 5555 -j ACCEPT
# 2) Android → AGL 的 SYN-ACK
iptables -I ANDROID_ISOLATION_IN_FILTER 1 -s <ANDROID_IP>/32 -p tcp --sport 5555 -j ACCEPT
# 3) 笔电 → AGL:15559
iptables -I INPUT 1 -p tcp --dport 15559 -j ACCEPT
# 4) 转发
setsid -f socat TCP-LISTEN:15559,fork,reuseaddr TCP:<ANDROID_IP>:5555 </dev/null
```

笔电侧：

```sh
adb connect <AGL_IP>:15559
```

注意：

- 隔离链由网络服务创建，**必须先等它出现**（`scripts/adb-setup.sh` 内有 ≤120 秒等待）；
- `adb connect` 在中继不正常时会挂住 >60 秒，**不要拿它当探针**；
- 探针用 `socat -T3 /dev/null TCP:<ANDROID_IP>:5555`；
- 整车重启后链路消失，需重跑 `scripts/adb-setup.sh`。

细节见 [docs/android-adb.md](docs/android-adb.md)。

### 快速开始

```sh
# 1. 先取得 AGL root（见 AGL root 一节：键盘 + 空密码）

# 2. 部署持久化入口
install -m 0755 scripts/serve.sh /data/lge/wlan/serve.sh
install -m 0755 scripts/hook.sh  /data/lge/wlan/hook.sh

# 3. 插入开机调用（会改厂商脚本，先备份！）
cp -a /lge/app_rw/wlan/wlan_startup.sh /data/lge/wlan_startup.sh.bak
sed -i '2i /data/lge/wlan/hook.sh >/dev/null 2>&1 &' /lge/app_rw/wlan/wlan_startup.sh
head -3 /lge/app_rw/wlan/wlan_startup.sh     # 确认第 2 行

# 4. 生成主机密钥，并放入你的登录公钥
#    主机密钥在车机上生成；authorized_keys 里放**你笔电**的公钥
mkdir -p /data/lge/ssh && chmod 700 /data/lge/ssh
ssh-keygen -q -t ed25519 -N '' -f /data/lge/ssh/ssh_host_ed25519_key
# 笔电执行：cat ~/.ssh/id_ed25519.pub        （复制输出）
# 车机执行：cat > /data/lge/ssh/authorized_keys   （粘贴后 Ctrl-D）

# 5. 先手动起一次（不等重启）
sh /data/lge/wlan/hook.sh && sleep 5 && netstat -lnt | grep ':22 '

# 6. 笔电登录
ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP>
```

### 验证

| 项 | 命令 | 期望 |
|---|---|---|
| 服务在跑 | `systemctl is-active sshd-persistent.service` | `active` |
| 端口接管 | `netstat -lnt \| grep ':22 '` | 只有我们的 sshd |
| **自愈** | `pkill -f "sshd -D -e -h /data/lge/ssh"`，等 10 秒 | 恢复 `active` |
| **开机持久** | `reboot`，起来后再查 | 仍为 `active` |
| 防火墙 | `iptables -S INPUT \| grep 22` | 只有 `-s <LAB_SUBNET>` |
| adb | `adb connect <AGL_IP>:15559` | `device` |

### 卸载与恢复原状

```sh
# 1) 停掉并移除我们的服务（运行时）
systemctl stop sshd-persistent.service
systemctl reset-failed sshd-persistent.service 2>/dev/null

# 2) 让固件自带的 SSH 回来
systemctl unmask --runtime sshd.socket
systemctl start sshd.socket

# 3) 恢复厂商脚本（关键）
cp -a /data/lge/wlan_startup.sh.bak /lge/app_rw/wlan/wlan_startup.sh
diff /data/lge/wlan_startup.sh.bak /lge/app_rw/wlan/wlan_startup.sh && echo RESTORED

# 4) 移除我们放的文件（可选；.bak 确认无误后也可删）
rm -rf /data/lge/wlan/serve.sh /data/lge/wlan/hook.sh /data/lge/ssh
rm -f  /data/lge/wlan_startup.sh.bak

# 5) 重启确认回到原状
reboot
```

adb 中继的回滚见 [docs/android-adb.md](docs/android-adb.md)。

### 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `ssh` 连不上 22 | 固件 sshd 仍占着 22，我们的没起来 | 看 `/data/lge/ssh/boot-hook.log`；确认 `serve.sh` 的 mask/stop 执行成功 |
| 重启后 22 没起来 | `wlan_startup.sh` 的调用行丢了或被覆盖 | 进控制台检查第 2 行；重新插入 |
| 车机反复重启 | 注入行让 `wlan_startup.sh` 返回非 0 | **物理控制台**恢复 `.bak` |
| `systemd-run` 失败 | 单元已存在 / 非 root 上下文 | `hook.sh` 已做幂等；确认 `busybox.suid` 提权成功 |
| `adb connect` 卡住 | 中继未就绪 | 先用 `socat -T3` 探针，再 `adb connect` |
| 中文/特殊字符输不进控制台 | 方式 B 的 Unicode 模式与目标系统不匹配 | 控制台登录只需 ASCII（`root`），不受影响 |
| 换了别的固件 | 路径/unit 名可能不同 | 先按 [前置条件](#前置条件) 逐项核对，再决定是否继续 |

### 边界与不包含的内容

- **不包含**：固件镜像、厂商二进制、提取的 JAR、车辆数据、凭据、机器相关配置；
- **不做**：bootloader 解锁、dm-verity 关闭、分区刷写、OTA 修改；
- **不建议**在行驶中操作；所有步骤应在静止/台架上完成；
- 本仓库**不是**通用 AGL 模拟器，也不是 Android 提权方案；
- **Android 侧仍无 root**：本仓库只解决 AGL root 与 adb 通道。

### 致谢

本项目能写成，离不开合作伙伴 [NullYing](https://github.com/NullYing)（org:
[vw-id-headunit-lab](https://github.com/vw-id-headunit-lab)）的分享：

| 贡献 | 用到的地方 |
|---|---|
| **[esp32-hid-web](https://github.com/vw-id-headunit-lab/esp32-hid-web)** —— ESP32-S3 USB HID 键盘模拟 | 方式 B：无物理键盘进入控制台 |
| **Android ADB 通道**（隔离链放行 + socat 中继） | 《Android adb 通道》一节 |
| **持久化形态参考**（systemd 单元 + 主机密钥 + 防火墙时序 + 日志/幂等） | 《持久化钩子》一节 |

方式 A（物理键盘）与方式 C（可编程键盘）是通用做法，不涉及第三方项目。
文档的风险分级写法参考了 [iDrive7/8 SSH root](https://github.com/cauliflowermossgrape/idrive7-8-ssh-root) 的组织方式。

### 许可证

MIT，仅覆盖本仓库中自编的代码与文档，不覆盖厂商材料。
见 [LICENSE](LICENSE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

*最后更新：2026-11-15 ｜ 已在实车验证（MEB Gen1 / ICAS3 SW 2995）*

---

## English

### Contents

- [Status](#status)
- [Supported models](#supported-models)
- [Prerequisites](#prerequisites)
- [Repository layout](#repository-layout)
- [AGL root](#agl-root-1)
- [Persistence hook](#persistence-hook)
- [Android adb channel](#android-adb-channel)
- [Quick start](#quick-start)
- [Verification](#verification)
- [Uninstall and restore](#uninstall-and-restore)
- [FAQ](#faq)
- [Scope and exclusions](#scope-and-exclusions)
- [Acknowledgements](#acknowledgements)
- [License](#license)

### Status

- **Verified on real vehicles**: AGL root, persistent SSH, recovery after reboot,
  self-healing, and the Android adb channel;
- **Verified models**: ID.3 (2021–2023) and ID.4 X (2021–2023);
- **Platform**: MEB Gen1 / ICAS3 / Exynos Auto V9 (QNX + AGL + Android);
- Other models and generations are listed in the table below.

### Supported models

| Model | Model years | Head unit | Status |
|---|---|---|---|
| **ID.3** | **2021 / 2022 / 2023** | ICAS3 (MEB Gen1) | ✅ **verified** |
| **ID.4 X** | **2021 / 2022 / 2023** | ICAS3 (MEB Gen1) | ✅ **verified** |
| ID.4 CROZZ | 2021 / 2022 / 2023 | ICAS3 (same generation) | ⚠️ **not verified** |
| ID.3 / ID.4 X **Gen2** | 2024 onwards | ICAS3 + ID.S 5.0 (**MEB Gen2**) | ❌ not applicable |

Generation split:

- **Gen1** (2021–2023): **ICAS3** head unit, MEB Gen1 — the target of this
  repository;
- **Gen2** (2024 onwards): still the **ICAS3** family, but running the **ID.S 5.0**
  software platform (MEB Gen2) with a 12.9-inch screen; the system version and
  partition layout differ, so it is **unverified and out of scope** here.

**Two checks** (both Gen1 and Gen2 belong to the ICAS3 family, so the software
version matters too):

1. **Confirm the ICAS3 family** — inside AGL:

   ```sh
   uname -r                                    # ICAS3 reports 4.14.137-*
   ls /lge/app_ro/network/firewall_rules.IPv4  # present => ICAS3 (LG unit)
   ```

2. **Check the software version** — head unit UI → system information:

   | Shown | Verdict |
   |---|---|
   | **SW 2995** (or another 2xxx/3xxx number) | **Gen1**, supported here |
   | **ID.S 5.0** family | **Gen2**, out of scope |

   Note: `/etc/os-release` inside AGL only reports `Samsung Embedded Linux 2.6.1`
   and **does not reveal the vehicle software version** — you must read it on the
   head unit screen.

### Prerequisites

| Item | Requirement |
|---|---|
| Vehicle | **You own it or are explicitly authorized** |
| Physical access | USB keyboard (or ESP32/BadUSB) reachable on the head unit — **required** |
| Firmware | ICAS3 SW 2995 (the validated version); others need your own verification |
| Host | Linux/macOS with `ssh`, `adb`, `socat`, `curl` |
| **Car hotspot** | the head unit's Wi-Fi hotspot is on; laptop can join it |
| Network | Host on the same subnet as AGL (`<LAB_SUBNET>`) |
| Risk acceptance | You accept losing remote access and needing to be at the car |

### Repository layout

```text
icas3-agl-root/
├── README.md                 this file (Chinese + English)
├── LICENSE                   MIT (authored code and docs only)
├── THIRD_PARTY_NOTICES.md    credits and third-party notices
├── docs/
│   ├── agl-root.md           three ways in, evidence, why it is a config defect
│   ├── persistence.md        dm-verity limits, mount choice, lifecycle, rollback
│   ├── android-adb.md        topology, four steps, caveats, rollback
│   └── disclaimer.md         full disclaimer (owner / manufacturer / legal)
└── scripts/
    ├── serve.sh              service (wait firewall -> key -> mask -> sshd -D)
    ├── hook.sh               boot trigger (restricted iptables + fallback + systemd-run)
    └── adb-setup.sh          ADB relay (wait chains -> three rules -> socat)
```

### AGL root

This is **a configuration defect, not a code flaw**: the root account in
`/etc/shadow` has an empty password field and is the only account with an empty password.
`login` and `busybox.suid su` both accept it.

Three ways to reach the console:

- **A. Physical USB keyboard** — plug in, `Alt+F3` (or `Ctrl+Alt+F1`), log in as
  `root` with an empty password.
- **B. ESP32-S3 USB HID bridge** — the collaborator's project
  [esp32-hid-web](https://github.com/vw-id-headunit-lab/esp32-hid-web)
  (thanks to [NullYing](https://github.com/NullYing)). The board enumerates as a
  USB keyboard and **ships its own web UI, so you just click** — no scripting:

  ```text
  ESP32-S3 (native USB/OTG) --USB cable--> head unit Type-C
  phone joins hotspot S3-HID-XXXXXX (password esp32hid123)
  open http://192.168.4.1  (wait for "USB connected")
  ```

  On that page: pick **Linux** as the target system, press the **Ctrl+Alt+F1**
  button to switch to the console, type `root` and press “send to USB”, then press
  **Enter** for the empty password — you should see `uid=0`.

  The HTTP API (`/api/key`, `/api/type`) is only needed for automation. Note the
  key whitelist provides `CTRL_ALT_F1`, **not** `Alt+F3`; if your firmware only
  accepts `Alt+F3`, use method A or C.

- **C. Programmable keyboard / BadUSB** — replay offline: wait 3 s, `CTRL ALT F1`
  (or `ALT F3`), `root`, `ENTER`, then `ENTER` for the empty password. Mind the
  delays; no phone, hotspot or network required.

### Persistence hook

Three phases — note which ones need a keyboard:

```text
Phase 0  first-time deploy   [KEYBOARD REQUIRED]
         console -> root -> upload serve.sh/hook.sh
         -> add one line to wlan_startup.sh
         -> run hook.sh manually -> verify port 22 -> reboot to verify

Phase 1  every boot          [no keyboard]
         wlanmgr -> wlan_startup.sh -> hook.sh
         -> systemd-run sshd-persistent -> serve.sh -> sshd :22

Phase 2  recovery            [KEYBOARD REQUIRED]
         console -> root -> rollback -> reboot
```

**The boot chain only covers Phase 1.** Phase 0 (deploy) and Phase 2 (rollback)
both depend on the physical console, which is why the disclaimer requires
confirming console access before starting.

End-to-end flow (the actual order of operations):

```text
0. Network      laptop joins the head unit's Wi-Fi hotspot (<LAB_SUBNET>, AGL = <AGL_IP>)
1. Console      USB keyboard -> Alt+F3 -> root + empty password      [KEYBOARD]
2. First shell  start socat on 4445 from the console so the laptop can reach it
3. Transfer     wget serve.sh / hook.sh into /data/lge/wlan/ over the hotspot
4. Install      back up wlan_startup.sh, insert the call on line 2
5. Verify       run hook.sh manually, check port 22, log in with your key
6. Self-heal    kill sshd, confirm it returns within 10 s
7. Reboot       confirm the whole chain comes back with no keyboard
```

Without step 0 there is no route to AGL, and without step 1 there is no shell to
write anything. Both are prerequisites, not optional.

The root filesystem is dm-verity protected and read-only, so no unit can be added
under `/etc/systemd/system`. The only writable, unit-referenced mount is a vendor
script on a writable partition:

```text
/lge/app_rw/wlan/wlan_startup.sh  (vendor, ExecStart of wlanmgr.service)
  └─ /data/lge/wlan/hook.sh
       └─ systemd-run --unit=sshd-persistent.service --property=Restart=always
            └─ /data/lge/wlan/serve.sh
                 ├─ wait for firewall-manager (<=60 s)
                 ├─ persist host key under /data
                 ├─ runtime-mask sshd.socket and stop sshd.service (free port 22)
                 ├─ iptables: allow <LAB_SUBNET> only
                 ├─ port-in-use check
                 └─ exec sshd -D with key authentication
```

Because the surrounding units use `FailureAction=reboot-immediate`, the injected
line must run in the background so it never changes the vendor script's exit code.

### Android adb channel

> **Credit: the technique was discovered and shared by
> [NullYing](https://github.com/NullYing).**

AGL has root and acts as the network gateway. Android `adbd` listens on the
internal link `<ANDROID_IP>:5555` but is blocked by the `ANDROID_ISOLATION_*`
chains:

```sh
iptables -I ANDROID_ISOLATION_OUT_FILTER 1 -p tcp --dport 5555 -j ACCEPT
iptables -I ANDROID_ISOLATION_IN_FILTER 1 -s <ANDROID_IP>/32 -p tcp --sport 5555 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 15559 -j ACCEPT
setsid -f socat TCP-LISTEN:15559,fork,reuseaddr TCP:<ANDROID_IP>:5555 </dev/null
```

```sh
adb connect <AGL_IP>:15559
```

Caveats: wait for the isolation chains first; never use `adb connect` as a probe;
the relay disappears after a reboot and must be re-run.

### Quick start

```sh
# 1. get AGL root first (see "AGL root": keyboard + empty password)

# 2. deploy the persistence entry
install -m 0755 scripts/serve.sh /data/lge/wlan/serve.sh
install -m 0755 scripts/hook.sh  /data/lge/wlan/hook.sh

cp -a /lge/app_rw/wlan/wlan_startup.sh /data/lge/wlan_startup.sh.bak
sed -i '2i /data/lge/wlan/hook.sh >/dev/null 2>&1 &' /lge/app_rw/wlan/wlan_startup.sh

mkdir -p /data/lge/ssh && chmod 700 /data/lge/ssh
ssh-keygen -q -t ed25519 -N '' -f /data/lge/ssh/ssh_host_ed25519_key
# authorized_keys must contain YOUR laptop's public key:
#   laptop: cat ~/.ssh/id_ed25519.pub
#   car:    cat > /data/lge/ssh/authorized_keys   (paste, then Ctrl-D)

# 3. start once, then log in
sh /data/lge/wlan/hook.sh && sleep 5 && netstat -lnt | grep ':22 '
ssh -p 22 -i <LOCAL_KEY> root@<AGL_IP>
```

### Verification

| Item | Command | Expected |
|---|---|---|
| Service running | `systemctl is-active sshd-persistent.service` | `active` |
| Port taken | `netstat -lnt \| grep ':22 '` | only our sshd |
| Self-healing | `pkill -f "sshd -D -e -h /data/lge/ssh"`, wait 10 s | back to `active` |
| Survives reboot | `reboot`, then check again | still `active` |
| Firewall | `iptables -S INPUT \| grep 22` | only `-s <LAB_SUBNET>` |
| adb | `adb connect <AGL_IP>:15559` | `device` |

### Uninstall and restore

```sh
systemctl stop sshd-persistent.service
systemctl unmask --runtime sshd.socket && systemctl start sshd.socket
cp -a /data/lge/wlan_startup.sh.bak /lge/app_rw/wlan/wlan_startup.sh
rm -rf /data/lge/wlan/serve.sh /data/lge/wlan/hook.sh /data/lge/ssh
rm -f  /data/lge/wlan_startup.sh.bak
reboot
```

### FAQ

| Symptom | Cause | Fix |
|---|---|---|
| Port 22 unreachable | vendor sshd still holds it | check `/data/lge/ssh/boot-hook.log` |
| Not coming back after reboot | the injected line is missing | restore from `.bak` on the console |
| Boot loop | injected line changed the exit code | console: restore `.bak` |
| `systemd-run` fails | unit already exists | `hook.sh` is idempotent; re-check |
| `adb connect` hangs | relay not ready | probe with `socat -T3` first |
| Unit fails to start | `busybox.suid` escalation failed | check `/data/lge/ssh/boot-hook.log` |
| Different firmware | paths/unit names may differ | check every row of [Prerequisites](#prerequisites) first |

### Scope and exclusions

No firmware images, vendor binaries, extracted JARs, vehicle data, credentials or
machine-specific configuration are included. This repository does **not** cover
bootloader unlocking, disabling dm-verity, partition flashing or OTA modification,
and it does **not** provide Android root.

### Acknowledgements

This project builds on material shared by [NullYing](https://github.com/NullYing)
(org: [vw-id-headunit-lab](https://github.com/vw-id-headunit-lab)):

| Contribution | Used in |
|---|---|
| [esp32-hid-web](https://github.com/vw-id-headunit-lab/esp32-hid-web) | Method B |
| Android ADB channel (isolation-chain rule + socat relay) | “Android adb channel” |
| Persistence shape (systemd unit, host key, firewall ordering, idempotency) | “Persistence hook” |

Methods A and C are generic techniques. The risk-grading style follows
[iDrive7/8 SSH root](https://github.com/cauliflowermossgrape/idrive7-8-ssh-root).

### License

MIT for the authored code and documentation only; vendor material is excluded.
See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

## Disclaimer

> **Your own vehicle only, at your own risk.** This project adds two scripts under
> `/data`, inserts one line into a vendor boot script, and at runtime takes over
> port 22 (the stock sshd file is untouched; it is only masked for this boot) and
> adjusts firewall rules.
> **Worst case: the head unit boots in a loop and you cannot connect any more —
> recovery requires a physical USB keyboard on the console.**

Risk by step (full version: [docs/disclaimer.md](docs/disclaimer.md)):

| Step | Risk | Reversible |
|---|---|---|
| Console login as root | 🟢 low | — |
| **Editing `wlan_startup.sh`** | 🔴 **high** — `FailureAction=reboot-immediate` | needs console |
| Installing `hook.sh` / `serve.sh` | 🟢 low | delete files |
| `mask --runtime sshd.socket` | 🟡 medium | reboot restores |
| Changing `iptables` | 🟡 medium | reboot restores |
| `reboot` to verify | 🟡 medium | physical console |
| ADB relay | 🟢 low | reboot restores |

**Before you start**: back up `wlan_startup.sh`, run `iptables-save`, and
**confirm a USB keyboard reaches a root console** — the only recovery path once
the network is gone. **If you cannot confirm that, do not start.**

**For manufacturers**: this repository records a configuration defect found on the
author's own vehicle; no firmware, vendor binaries, extracted interface classes,
vehicle data or credentials are included. **This project is not affiliated with,
sponsored by or endorsed by Volkswagen AG or any supplier.**

**Legal**: this project only uses interfaces the device itself exposes (console
login, `systemd`, `iptables`, `sshd`) and adds its own scripts under `/data`;
**no vendor binary is altered**. Modifying a vehicle may affect warranty and
compliance — verify and comply with local law.

---

*Last updated: 2026-11-15 — verified on a real vehicle (MEB Gen1 / ICAS3 SW 2995).*
