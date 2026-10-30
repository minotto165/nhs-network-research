#!/usr/bin/env bash
# OS全体 DoH 化セットアップ (Arch Linux + NetworkManager 用)
# 構成: アプリ -> 127.0.0.1:53 (dnscrypt-proxy) -> DoH(443) x3
#   - dnscry-tokyo: https://tyo03.dnscry.pt/dns-query (45.67.86.123, 推奨)
#   - dns4all     : https://doh.dns4all.eu/dns-query (194.0.5.3, 推奨)
#   - slowb-au2   : https://dns1.slowb.ro/dns-query (103.1.184.110, フォールバック)
# 3併用 + 常時DoH。lb はデフォルト wp2 (速いサーバを自動選択) のため、
# 死んでいるサーバは自動で避けられ、復活すれば自動で使われる。
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: root で実行してください: sudo bash $0" >&2
  exit 1
fi

TS=$(date +%F-%H%M%S)
BK="/root/doh-backup-${TS}"
mkdir -p "$BK"
echo "=== バックアップ -> $BK ==="
cp -a /etc/dnscrypt-proxy/dnscrypt-proxy.toml "$BK/" 2>/dev/null || true
cp -a /etc/systemd/resolved.conf "$BK/" 2>/dev/null || true
cp -a /etc/systemd/resolved.conf.d "$BK/" 2>/dev/null || true
cp -a /etc/NetworkManager/NetworkManager.conf "$BK/" 2>/dev/null || true
cp -a /etc/NetworkManager/conf.d "$BK/" 2>/dev/null || true
cp -a /etc/resolv.conf "$BK/resolv.conf.bak" 2>/dev/null || true

echo "=== パッケージ導入 ==="
pacman -S --noconfirm --needed dnscrypt-proxy bind

echo "=== dnscrypt-proxy 設定 ==="
cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
# OS全体DoH用 (nhs-network-research の3サーバ併用・常時DoH)
# 平文DNSは校内でハイジャックされるため、スタンプにIP直書き (bootstrap不要)

server_names = ['dnscry-tokyo', 'dns4all', 'slowb-au2']
listen_addresses = ['127.0.0.1:53']
max_clients = 250
timeout = 10000
keepalive = 30
cache = true
cache_size = 4096

# campusでは UDP/53 が塞がれているため、疎通確認は DoH先の 443 で行う
netprobe_address = '45.67.86.123:443'

[static.'dnscry-tokyo']
stamp = 'sdns://AgAAAAAAAAAADDQ1LjY3Ljg2LjEyMwAPdHlvMDMuZG5zY3J5LnB0Ci9kbnMtcXVlcnk'

[static.dns4all]
stamp = 'sdns://AgAAAAAAAAAACTE5NC4wLjUuMwAOZG9oLmRuczRhbGwuZXUKL2Rucy1xdWVyeQ'

[static.'slowb-au2']
stamp = 'sdns://AgAAAAAAAAAADTEwMy4xLjE4NC4xMTAADWRuczEuc2xvd2Iucm8KL2Rucy1xdWVyeQ'
EOF
chmod 644 /etc/dnscrypt-proxy/dnscrypt-proxy.toml

echo "=== systemd-resolved 設定 ==="
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/doh.conf <<'EOF'
[Resolve]
# 全クエリを dnscrypt-proxy (DoH) へ。~. でlink DNSより優先。
DNS=127.0.0.1
FallbackDNS=127.0.0.1
Domains=~.
DNSSEC=no
DNSOverTLS=no
Cache=yes
EOF

echo "=== NetworkManager 設定 (DNS管理を無効化し常時DoH) ==="
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/90-doh.conf <<'EOF'
[main]
# 常時DoH: NMはDNSを触らない (DHCPの172.17.49.196等を無視)。VPN利用時は要調整。
dns=none
EOF

systemctl daemon-reload
echo "=== サービス起動 ==="
systemctl enable --now dnscrypt-proxy
systemctl enable --now systemd-resolved
sleep 2
echo "=== NetworkManager 再起動 (Wi-Fiが一瞬切れます) ==="
sleep 2
systemctl restart NetworkManager
sleep 5

echo "=== 既存接続のDHCP DNSを無視 (常時DoH) ==="
for uuid in $(nmcli -t -f UUID connection show); do
  nmcli connection modify "$uuid" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes 2>/dev/null || true
done

echo "=== 新規接続にも自動適用する dispatcher 設置 ==="
mkdir -p /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/10-doh-ignore-dns <<'EOF'
#!/bin/sh
# 常時DoH: 新規SSID等も含め DHCP のDNSを無視し DoH のみ使う
case "$2" in
  up|dhcp4-change|dhcp6-change)
    CUR=$(nmcli -g ipv4.ignore-auto-dns connection show "$CONNECTION_UUID" 2>/dev/null)
    if [ "$CUR" != "yes" ]; then
      nmcli connection modify "$CONNECTION_UUID" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes
      nmcli device reapply "$DEVICE_IFACE" 2>/dev/null || true
    fi
    ;;
esac
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/10-doh-ignore-dns
# 現行アクティブ接続に即時反映
for dev in $(nmcli -t -f DEVICE,STATE device status | awk -F: '$2=="connected" && $1!="lo" {print $1}'); do
  nmcli device reapply "$dev" 2>/dev/null || true
done
sleep 3
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved
sleep 2

echo
echo "=== 検証 ==="
echo "--- listen ---"
ss -lntup | grep -E ':53 ' || { echo "NG: :53 でlistenしていません"; exit 1; }
echo "--- DoH直 (dnscrypt) ---"
R1=$(dig @127.0.0.1 one.one.one.one +short | sort | tr '\n' ' ')
echo "one.one.one.one @127.0.0.1 = $R1"
case "$R1" in
  *146.112.61.106*) echo "NG: フィルタDNSに毒されています"; exit 1;;
  *1.1.1.1*) echo "OK: 正規応答 (Cloudflare)";;
  *) echo "WARN: 想定外の応答 (要確認)";;
esac
echo "--- OS経路 (stub) ---"
R2=$(dig @127.0.0.53 example.com +short | head -1)
echo "example.com @127.0.0.53 = $R2"
echo "--- resolvectl ---"
resolvectl status
echo "--- /etc/resolv.conf ---"
cat /etc/resolv.conf

echo
echo "=== 完了 ==="
echo "ロールバック: バックアップは $BK に保存。"
echo "  sudo systemctl disable --now dnscrypt-proxy"
echo "  sudo rm /etc/systemd/resolved.conf.d/doh.conf /etc/NetworkManager/conf.d/90-doh.conf"
echo "  sudo systemctl restart systemd-resolved NetworkManager"
