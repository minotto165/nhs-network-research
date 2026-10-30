# 対策LinuxでのDoHを用いた対策

[フィルタリングの仕組みと対策](./bypass.md)を読んで仕組みをある程度理解したうえで行うこと。

Arch Linux + NetworkManager + systemd-resolved 向け。他ディストリでも systemd 前提なら手順 2 以降で再現できる。

## 方針

OS 全体の DNS を DoH にする。systemd-resolved は DoH に対応していないため
(issue [#8639](https://github.com/systemd/systemd/issues/8639))、
`dnscrypt-proxy` を localhost フォワーダとして使う。

```
アプリ → 127.0.0.53 → 127.0.0.1:53 (dnscrypt-proxy) → DoH (443/TCP)
```

## 1. 自動セットアップ (Arch Linux)

`scripts/setup-arch-doh.sh` を sudo で実行する。
パッケージ導入・下記の設定・新規 SSID への自動適用・検証まで行う。

```sh
sudo bash scripts/setup-arch-doh.sh
```

## 2. 手動設定 (他ディストリ向け)

`dnscrypt-proxy` を導入し、`/etc/dnscrypt-proxy/dnscrypt-proxy.toml` に static 定義を書く。
スタンプは `sdns://` 形式で、IP 直書きのため学内の DNS フィルタリングの影響を受けない。

```toml
server_names = ['dnscry-tokyo', 'dns4all', 'slowb-au2']
listen_addresses = ['127.0.0.1:53']
cache = true

[static.'dnscry-tokyo']
stamp = 'sdns://AgAAAAAAAAAADDEwMy4xNzkuNDUuNgAPdHlvMDIuZG5zY3J5LnB0Ci9kbnMtcXVlcnk'

[static.dns4all]
stamp = 'sdns://AgAAAAAAAAAACTE5NC4wLjUuMwAOZG9oLmRuczRhbGwuZXUKL2Rucy1xdWVyeQ'

[static.'slowb-au2']
stamp = 'sdns://AgAAAAAAAAAADTEwMy4xLjE4NC4xMTAADWRuczEuc2xvd2Iucm8KL2Rucy1xdWVyeQ'
```

自作スタンプを作る場合は addr と hostname の間に空 hashes (`0x00` 1バイト) が必要。
無いと `certificate hash must be 32 bytes` で起動しない。

`/etc/systemd/resolved.conf.d/doh.conf` に次の内容を書き、
systemd-resolved を 127.0.0.1 向きにする。

```ini
[Resolve]
DNS=127.0.0.1
FallbackDNS=127.0.0.1
Domains=~.
```

`/etc/NetworkManager/conf.d/90-doh.conf` に次の内容を書き、
NetworkManager には DNS を触らせない。

```ini
[main]
dns=none
```

さらに接続ごとの DHCP DNS を無視する。

```sh
for uuid in $(nmcli -t -f UUID connection show); do
  nmcli connection modify "$uuid" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes
done
```

新規 SSID 用に dispatcher (`/etc/NetworkManager/dispatcher.d/10-doh-ignore-dns`) で自動化する。
中身は `scripts/setup-arch-doh.sh` を参照。

```sh
sudo systemctl enable --now dnscrypt-proxy systemd-resolved
sudo systemctl restart NetworkManager
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
```

## 3. DNSサーバー

[bypass.md](./bypass.md) の推奨2件にフォールバック1件を併用する。
負荷分散が生存サーバを自動選択するため、死んでいるサーバを混ぜてもよい。

| 名称 | リゾルバURL | 位置づけ |
|-|-|-|
| dnscry.pt Tokyo | <https://tyo02.dnscry.pt/dns-query> | 推奨 |
| dns4all (SIDN Labs) | <https://doh.dns4all.eu/dns-query> | 推奨 |
| OpenNIC(ns2.au.dns.opennic.glue) | <https://dns1.slowb.ro/dns-query> | フォールバック |

## 4. 検証

```sh
dig one.one.one.one +short       # 1.1.1.1 が返ること (146.112.61.106 はフィルタ)
curl -s -o /dev/null -w "%{http_code}\n" https://proton.me   # 200 が返ること
```

戻すときはバックアップ (`/root/doh-backup-*`) から復旧する。手順はスクリプト末尾に記載。
