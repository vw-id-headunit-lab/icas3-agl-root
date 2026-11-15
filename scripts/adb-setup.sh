#!/bin/sh
# adb-setup.sh — 恢复 AGL ↔ Android 的 adb 通道
# 放在 /home 持久分区，开机后执行一次即可
# 回滚：iptables -D ANDROID_ISOLATION_OUT_FILTER -p tcp --dport 5555 -j ACCEPT
#       iptables -D ANDROID_ISOLATION_IN_FILTER -s <ANDROID_IP>/32 -p tcp --sport 5555 -j ACCEPT
#       iptables -D INPUT -p tcp --dport 15559 -j ACCEPT
#       pkill -f "TCP-LISTEN:15559"

log() { echo "[adb-setup] $*"; }

# 等隔离链被网络服务创建出来（最多 120 秒）
i=0
while [ $i -lt 60 ]; do
    if iptables -L ANDROID_ISOLATION_OUT_FILTER >/dev/null 2>&1 &&
       iptables -L ANDROID_ISOLATION_IN_FILTER  >/dev/null 2>&1; then
        break
    fi
    sleep 2
    i=$((i+1))
done

if ! iptables -L ANDROID_ISOLATION_IN_FILTER >/dev/null 2>&1; then
    log "ERROR: 隔离链不存在，网络服务可能没起来"
    exit 1
fi

# 1) AGL -> Android 5555
iptables -C ANDROID_ISOLATION_OUT_FILTER -p tcp --dport 5555 -j ACCEPT 2>/dev/null || {
    iptables -I ANDROID_ISOLATION_OUT_FILTER 1 -p tcp --dport 5555 -j ACCEPT && log "OUT ACCEPT 已加"
}

# 2) Android -> AGL 的 SYN-ACK（源端口 5555）
iptables -C ANDROID_ISOLATION_IN_FILTER -s <ANDROID_IP>/32 -p tcp --sport 5555 -j ACCEPT 2>/dev/null || {
    iptables -I ANDROID_ISOLATION_IN_FILTER 1 -s <ANDROID_IP>/32 -p tcp --sport 5555 -j ACCEPT && log "IN ACCEPT 已加"
}

# 3) Mac -> AGL:15559
iptables -C INPUT -p tcp --dport 15559 -j ACCEPT 2>/dev/null || {
    iptables -I INPUT 1 -p tcp --dport 15559 -j ACCEPT && log "INPUT 15559 已加"
}

# 4) socat 转发
if ! pgrep -f "TCP-LISTEN:15559" >/dev/null 2>&1; then
    setsid nohup socat TCP-LISTEN:15559,fork,reuseaddr TCP:<ANDROID_IP>:5555 >/dev/null 2>&1 &
    sleep 1
    log "socat 15559 已启动"
else
    log "socat 已在运行"
fi

# 5) 自检（socat 可靠；nc 对 adbd 会假阴性）
if socat -T2 /dev/null TCP:<ANDROID_IP>:5555 >/dev/null 2>&1; then
    log "OK: Android adbd 可达"
else
    log "WARN: Android adbd 不可达 — 检查 sys.usb.config（可能需插一次 USB）"
fi
log "完成。Mac 上执行: adb connect <AGL_IP>:15559"
