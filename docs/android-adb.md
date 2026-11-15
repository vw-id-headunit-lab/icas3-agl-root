# Android adb 通道（经 AGL 中继）

> **本节的思路与最初实现来自合作伙伴 [NullYing](https://github.com/NullYing)，感谢分享。**

## 拓扑

```text
宿主机 ──<LAB_SUBNET>──> AGL(<AGL_IP>)
                              │  socat 15559 -> <ANDROID_IP>:5555
                              ▼
                         Android adbd (<ANDROID_IP>:5555)
```

AGL 是 Android 的网络网关。Android 的 `adbd` 在内部链路 `<ANDROID_IP>:5555`
监听，但被 `ANDROID_ISOLATION_*` 隔离链阻断。

## 步骤

```sh
# 0) 先确认隔离链已由网络服务创建（最多等 120s）
iptables -L ANDROID_ISOLATION_OUT_FILTER
iptables -L ANDROID_ISOLATION_IN_FILTER

# 1) AGL -> Android 5555
iptables -I ANDROID_ISOLATION_OUT_FILTER 1 -p tcp --dport 5555 -j ACCEPT

# 2) Android -> AGL 的 SYN-ACK（源端口 5555）
iptables -I ANDROID_ISOLATION_IN_FILTER 1 -s <ANDROID_IP>/32 -p tcp --sport 5555 -j ACCEPT

# 3) 宿主机 -> AGL:15559
iptables -I INPUT 1 -p tcp --dport 15559 -j ACCEPT

# 4) 端口转发
setsid -f socat TCP-LISTEN:15559,fork,reuseaddr TCP:<ANDROID_IP>:5555 </dev/null
```

宿主机：

```sh
adb connect <AGL_IP>:15559
adb devices
```

## 重要注意事项

| 注意点 | 说明 |
|---|---|
| 隔离链存在性 | 链由网络服务创建，必须先等它出现，否则规则加不上 |
| `adb connect` 不能当探针 | 中继不正常时会挂住 >60 s；探针用 `socat -T3 /dev/null TCP:<ANDROID_IP>:5555` |
| 重启后失效 | iptables 与 socat 都不持久，需重跑 |
| stdin 重定向 | 用 `setsid -f ... </dev/null`，否则后台进程可能持有终端 |
| 不要 `adb root` | 该车为 user 版本，`ro.debuggable=0`，`adb root` 必然失败 |

## 回滚

```sh
iptables -D ANDROID_ISOLATION_OUT_FILTER -p tcp --dport 5555 -j ACCEPT
iptables -D ANDROID_ISOLATION_IN_FILTER -s <ANDROID_IP>/32 -p tcp --sport 5555 -j ACCEPT
iptables -D INPUT -p tcp --dport 15559 -j ACCEPT
pkill -f "TCP-LISTEN:15559"
```

## 范围说明

本通道只提供 **adb shell（uid 2000，`shell` 域）**，不提供 Android root。
