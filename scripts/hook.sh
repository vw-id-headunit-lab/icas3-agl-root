#!/bin/sh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# 由 /lge/app_rw/wlan/wlan_startup.sh 第 2 行调用（该脚本以非 root 运行）
echo | /bin/busybox.suid su root -c '
U=sshd-persistent.service
# 本固件出厂默认网段，可用环境变量覆盖
ALLOW_SUBNET=${ALLOW_SUBNET:-10.173.189.0/24}
# 保底 shell：只对本网段开放（原来是全开）
/usr/sbin/iptables -C INPUT -s "$ALLOW_SUBNET" -p tcp --dport 4445 -j ACCEPT 2>/dev/null || \
  /usr/sbin/iptables -I INPUT -s "$ALLOW_SUBNET" -p tcp --dport 4445 -j ACCEPT 2>/dev/null
/bin/ps | grep -q "[s]ocat TCP-LISTEN:4445" || \
  /usr/bin/socat TCP-LISTEN:4445,reuseaddr,fork EXEC:/bin/sh,pty >/dev/null 2>&1 &
# 正式：systemd 单元（幂等）
if ! /bin/systemctl is-active --quiet "$U"; then
  /usr/bin/systemd-run --no-block --unit="$U" \
    --property=Restart=always --property=RestartSec=5s --property=KillMode=process \
    /bin/sh /data/lge/wlan/serve.sh >/dev/null 2>&1 &
fi
'
