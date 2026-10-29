# 対策LinuxでのDoHを用いた対策

[フィルタリングの仕組みと対策](./bypass.md)を読んで仕組みをある程度理解したうえで行うこと。

対象環境: Arch Linux + NetworkManager + systemd-resolved。
他ディストリでも systemd 前提ならほぼ同じ手順で再現できる。

## 方針

OS 全体の DNS を DNS over HTTPS にする。
ブラウザ単位の DoH 設定では OS 全体に効かないため、localhost のフォワーダを経由する。

```
アプリ → 127.0.0.53 (systemd-resolved stub) → 127.0.0.1:53 (dnscrypt-proxy) → DoH (443/TCP)
```

systemd-resolved は DoH 未対応のため (issue [#8639](https://github.com/systemd/systemd/issues/8639)、Arch の systemd 262 時点で `DNSOverTLS` のみ)、
DoH への変換は `dnscrypt-proxy` (Arch公式 `extra`) に担当させる。

## DNSサーバー

[bypass.md](./bypass.md) の3サーバを併用する。
`dnscrypt-proxy` の負荷分散 (既定 wp2) が生存サーバを自動選択するため、死んでいるサーバを混ぜても問題ない。

| 名称 | リゾルバURL | IP (2026-10-29 時点) | 状態 |
|-|-|-|-|
| OpenNIC(ns1.mo.us.dns.opennic.glue) | <https://renardbleu.dev/dns-query> | 203.88.117.153 | 443 応答なし (予備) |
| OpenNIC(ns2.au.dns.opennic.glue) | <https://dns1.slowb.ro/dns-query> | 103.1.184.110 | 生存確認 |
| OpenNIC(ns5.au.dns.opennic.glue) | <https://dns2.slowb.ro/dns-query> | 168.138.12.137 | 443 応答なし (予備) |

IP は `dns1.slowb.ro` 自身の DoH で逆引きして正規性を cross-check した
(`one.one.one.one` → `1.1.1.1` が正しく返ることを確認)。
スタンプに IP を直書きするため、学内の DNS 毒による bootstrap 問題は起きない。

## SDNS スタンプの生成

`dnscrypt-proxy` の static 定義には `sdns://` スタンプが必要。
DoH スタンプのバイナリ形式は次の通り。

```
0x02 | props u64LE | addr(長さ付き) | hashes(長さ付き, 空=0x00) | hostname(長さ付き) | path(長さ付き)
```

注意: addr と hostname の間に hashes フィールド (空なら `0x00` 1バイト) が必要。
これを忘れると `Stamp error ... certificate hash must be 32 bytes` で起動しない
(addr が hashes として誤読されるため)。

```python
import base64, struct
def doh_stamp(addr, host, path='/dns-query', props=0):
    b = b'\x02' + struct.pack('<Q', props)
    ab = addr.encode(); b += bytes([len(ab)]) + ab
    b += b'\x00'  # hashes: 空
    hb = host.encode(); b += bytes([len(hb)]) + hb
    pb = path.encode(); b += bytes([len(pb)]) + pb
    return 'sdns://' + base64.urlsafe_b64encode(b).decode().rstrip('=')
```

## 1. dnscrypt-proxy の導入と設定

```sh
sudo pacman -S dnscrypt-proxy bind  # bind は dig 等の検証用
```

`/etc/dnscrypt-proxy/dnscrypt-proxy.toml` を次で上書きする
(既存はバックアップしておくこと)。

```toml
server_names = ['slowb-au2', 'slowb-au5', 'renardbleu']
listen_addresses = ['127.0.0.1:53']
max_clients = 250
timeout = 10000
keepalive = 30
cache = true
cache_size = 4096

# 学内では UDP/53 が塞がれているため、疎通確認は DoH 先の 443 で行う
netprobe_address = '103.1.184.110:443'

[static.'slowb-au2']
stamp = 'sdns://AgAAAAAAAAAADTEwMy4xLjE4NC4xMTAADWRuczEuc2xvd2Iucm8KL2Rucy1xdWVyeQ'

[static.'slowb-au5']
stamp = 'sdns://AgAAAAAAAAAADjE2OC4xMzguMTIuMTM3AA1kbnMyLnNsb3diLnJvCi9kbnMtcXVlcnk'

[static.renardbleu]
stamp = 'sdns://AgAAAAAAAAAADjIwMy44OC4xMTcuMTUzAA5yZW5hcmRibGV1LmRldgovZG5zLXF1ZXJ5'
```

## 2. systemd-resolved の設定

`/etc/systemd/resolved.conf.d/doh.conf`:

```ini
[Resolve]
DNS=127.0.0.1
FallbackDNS=127.0.0.1
Domains=~.
DNSSEC=no
DNSOverTLS=no
Cache=yes
```

`Domains=~.` で全クエリをグローバル (DoH) に流し、link の DHCP DNS を使わせない。
`FallbackDNS` も loopback にして fail-closed にする。

## 3. NetworkManager の設定

`/etc/NetworkManager/conf.d/90-doh.conf`:

```ini
[main]
# 常時DoH: NMはDNSを触らない。VPN利用時は要調整。
dns=none
```

`dns=none` は resolv.conf 管理のみ停止し、resolved への link DNS 通知は残るため、
接続ごとに DHCP DNS の無視も設定する。既存接続には手動で、

```sh
for uuid in $(nmcli -t -f UUID connection show); do
  nmcli connection modify "$uuid" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes
done
```

新規 SSID 用に dispatcher で自動化する。
`/etc/NetworkManager/dispatcher.d/10-doh-ignore-dns` (実行権限付き):

```sh
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
```

## 4. 有効化

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now dnscrypt-proxy systemd-resolved
sudo systemctl restart NetworkManager  # Wi-Fiが一瞬切れる
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
```

## 5. 検証

```sh
ss -lntup | grep ':53 '                     # 127.0.0.1:53 に dnscrypt がいること
dig @127.0.0.1 one.one.one.one +short       # 1.1.1.1 が返ること (146.112.61.106 は毒)
resolvectl status                           # Global DNS=127.0.0.1, Link側DNSが空であること
```

## 学内での検証結果 (2026-10-29)

学内 Wi-Fi (WPA2 802.1X) 接続直後に dispatcher が自動適用され、Link 側 DNS は空・`Default Route: no` になった。

- `dig one.one.one.one +short` → `1.1.1.1`, `1.0.0.1` (正規応答)
- `curl https://proton.me` → `200`、`curl https://example.com` → `200`
- フィルタ前は名前解決毒により応答が帰ってこなかった Web チャットも疎通した

なお ping (ICMP) は research-log 通り 100% loss のままだが、これはフィルタの仕様であり DNS とは無関係。
TCP 80/443 の利用には支障ない。

## ロールバック

```sh
sudo systemctl disable --now dnscrypt-proxy
sudo rm /etc/systemd/resolved.conf.d/doh.conf /etc/NetworkManager/conf.d/90-doh.conf \
  /etc/NetworkManager/dispatcher.d/10-doh-ignore-dns
sudo systemctl restart systemd-resolved NetworkManager
```

作業前に退避した設定ファイル (`/root/doh-backup-*`) で上書き復旧する。
