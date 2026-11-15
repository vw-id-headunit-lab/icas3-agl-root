#!/bin/sh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# 移植自合作方 boot-hook.sh 的 --serve 分支
# 主机密钥 / authorized_keys / 日志 全部放在可写的 /data
set -u
D=/data/lge/ssh
KEY=$D/ssh_host_ed25519_key
LOG=$D/boot-hook.log
PORT=${PORT:-22}
# 允许访问的网段：本固件出厂默认（见 /lge/app_ro/network/firewall_rules.IPv4）
# 若你的车改过网络配置，用环境变量覆盖：ALLOW_SUBNET=x.x.x.x/xx
ALLOW_SUBNET=${ALLOW_SUBNET:-10.173.189.0/24}

mkdir -p "$D" 2>/dev/null; chmod 700 "$D" 2>/dev/null
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -ge 262144 ]; then mv -f "$LOG" "$LOG.1"; fi
exec >> "$LOG" 2>&1
# 记录退出阶段（学合作方原版：失败时能看出死在哪一步）
STAGE=entry
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "hook exit=$rc stage=$STAGE"; fi' 0
echo "=== serve start $(date -u +%FT%TZ) port=$PORT ==="
STAGE=wait-firewall

# 1) 等 firewall-manager 初始化完成（最多 60s）
i=0
while [ "$i" -lt 60 ]; do
    if systemctl show firewall-manager.service -p ActiveState -p Result -p ExecMainStartTimestampMonotonic 2>/dev/null | /usr/bin/awk -F= '
        $1=="ActiveState"{d=($2=="inactive")}
        $1=="Result"{ok=($2=="success")}
        $1=="ExecMainStartTimestampMonotonic"{ran=($2+0>0)}
        END{exit !(d&&ok&&ran)}'; then break; fi
    sleep 1; i=$((i+1))
done
echo "firewall wait: ${i}s"

STAGE=host-key
# 2) 主机密钥
mkdir -p /var/run/sshd; chmod 755 /var/run/sshd
if [ ! -s "$KEY" ]; then
    if [ -s /run/sshkey ]; then cp /run/sshkey "$KEY";      # 复用固件预置密钥
    else /usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$KEY"; fi
fi
chmod 600 "$KEY"
/usr/sbin/sshd -t -h "$KEY" -p "$PORT" || { echo "sshd -t failed"; exit 1; }

STAGE=free-port
# 3) 只有 22 端口才需要腾开固件 sshd
if [ "$PORT" = "22" ]; then
    systemctl mask --runtime --now sshd.socket
    systemctl stop sshd.service
fi

STAGE=firewall
# 4) 防火墙：只放行本网段
/usr/sbin/iptables -C INPUT -s "$ALLOW_SUBNET" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
    /usr/sbin/iptables -I INPUT -s "$ALLOW_SUBNET" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null

STAGE=check-port
# 5) 端口占用检查
if /bin/netstat -lnt 2>/dev/null | /usr/bin/awk -v p=":$PORT" '$4 ~ p"$" {f=1} END{exit !f}'; then
    echo "port $PORT busy, abort"; exit 1
fi

STAGE=start-sshd
echo "starting sshd on $PORT"
exec /usr/sbin/sshd -D -e -h "$KEY" -p "$PORT" \
    -o AuthorizedKeysFile=/data/lge/ssh/authorized_keys \
    -o PidFile=/run/sshd-persistent.pid
