# フィルタリング調査記録

フィルタリングの挙動を分析するため、様々な通信を試した。
実行環境はAndroidのTermuxを用いた。
なお、個人情報保護のため一部ログは`xxxxx`のように隠している。

## ping

試しにpingを打ってみる。

```shell
$ ping example.com
PING example.com (104.18.26.120) 56(84) bytes of data.
^C
--- example.com ping statistics ---
13 packets transmitted, 0 received, 100% packet loss, time 12290ms
```

```shell
$ ping 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
^C
--- 8.8.8.8 ping statistics ---
83 packets transmitted, 0 received, 100% packet loss, time 83976ms
```

どうやらpingはすべてブロックされているらしい。

## curl

まずは、通常ブロックされるサイト(`one.one.one.one`)へgetリクエストを送ってみる。

```shell
$ curl -v one.one.one.one
* Host one.one.one.one:80 was resolved.
* IPv6: (none)
* IPv4: 146.112.61.106
*   Trying 146.112.61.106:80...                         
* Established connection to one.one.one.one (146.112.61.106 port 80) from 10.68.56.43 port 45938
* using HTTP/1.x
> GET / HTTP/1.1
> Host: one.one.one.one
> User-Agent: curl/8.18.0
> Accept: */*
>
* Request completely sent off
< HTTP/1.1 403 Forbidden
< Server: Cisco Umbrella
< Date: Tue, 10 Feb 2026 03:50:29 GMT
< Content-Type: text/html
< Transfer-Encoding: chunked
< Connection: keep-alive
<
## <html><head><scrft type="text/javascript">location.replace("https://block.opendns.com/?url=xxxxx");</script></head></html>
* Connection #0 to host one.one.one.one:80 left intact
```

名前解決後のIPアドレスが146.112.61.106(OpenDNS)だから、DNSによる名前解決の時点でフィルタリングされている。
レスポンスのJavaScriptでURLの書き換えを行い、ブロック画面へ遷移させている模様。

## curl IPアドレス指定

DNSでのフィルタリングらしいので、事前にIPアドレスを調べてリクエストを送ってみる。
185.70.42.45はproton.meのもの。

```shell
$ curl -v http://185.70.42.45/
*   Trying 185.70.42.45:80...
* Established connection to 185.70.42.45 (185.70.42.45 port 80) from 10.68.56.43 port 40148
* using HTTP/1.x
> GET / HTTP/1.1
> Host: 185.70.42.45
> User-Agent: curl/8.18.0
> Accept: */*
>
* Request completely sent off
< HTTP/1.1 421 Misdirected Request
< content-length: 104
< cache-control: no-cache
< content-type: text/html
<
<html><body><h1>421 Misdirected Request</h1>Request sent to a non-authoritative server.</body></html>
* Connection #0 to host 185.70.42.45:80 left intact                   
```

IPアドレスだとリクエストが通った。
protonのサーバーがIPアドレスでのアクセスを許容していないからエラーが帰ってきたが、OpenDNSのメッセージではないからサーバーへリクエストは届いている。

## dig (8.8.8.8)

ここからは、DNSによる名前解決に注目するため、digを用いる。
まずは普通に外部のDNSサーバーを指定してみる。

```shell
$ dig example.com @8.8.8.8

; <<>> DiG 9.20.18 <<>> example.com @8.8.8.8
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 40748
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1410
;; QUESTION SECTION:
;example.com.                   IN      A

;; ANSWER SECTION:
example.com.            137     IN      A       104.18.27.120
example.com.            137     IN      A       104.18.26.120

;; Query time: 68 msec
;; SERVER: 8.8.8.8#53(8.8.8.8) (UDP)
;; WHEN: Mon Feb 16 12:59:13 JST 2026
;; MSG SIZE  rcvd: 72
```

```shell
$ dig one.one.one.one @8.8.8.8

; <<>> DiG 9.20.18 <<>> one.one.one.one @8.8.8.8
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 33275
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1410
;; QUESTION SECTION:
;one.one.one.one.               IN      A

;; ANSWER SECTION:
one.one.one.one.        0       IN      A       146.112.61.106

;; Query time: 140 msec
;; SERVER: 8.8.8.8#53(8.8.8.8) (UDP)
;; WHEN: Mon Feb 16 12:56:20 JST 2026
;; MSG SIZE  rcvd: 60
```

一見成功しているように見えるが、one.one.one.oneがOpenDNSのIPアドレスになったので失敗している。

## dig (OpenNIC)

次によりマイナーなDNSサーバーを利用してみる。

```shell
$ dig one.one.one.one @172.233.66.93

; <<>> DiG 9.20.18 <<>> one.one.one.one @172.233.66.93
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 11869
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1410
;; QUESTION SECTION:
;one.one.one.one.               IN      A

;; ANSWER SECTION:
one.one.one.one.        0       IN      A       146.112.61.106

;; Query time: 48 msec
;; SERVER: 172.233.66.93#53(172.233.66.93) (UDP)
;; WHEN: Mon Feb 16 13:00:28 JST 2026
;; MSG SIZE  rcvd: 60
```

```shell
$ dig example.com @172.233.66.93

; <<>> DiG 9.20.18 <<>> example.com @172.233.66.93
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 30705
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1410
;; QUESTION SECTION:
;example.com.                   IN      A

;; ANSWER SECTION:
example.com.            12      IN      A       104.18.26.120
example.com.            12      IN      A       104.18.27.120

;; Query time: 72 msec
;; SERVER: 172.233.66.93#53(172.233.66.93) (UDP)
;; WHEN: Mon Feb 16 13:00:36 JST 2026
;; MSG SIZE  rcvd: 72
```

同じく失敗した。
禁止されていないサイトの名前解決自体は成功しているので、DNSリクエストを奪われているのだろう。

## dig dot/doh (8.8.8.8)

```shell
$ dig one.one.one.one +tls
;; Connection to 8.8.8.8#853(8.8.8.8) for one.one.one.one failed: connection refused.
;; no servers could be reached
;; Connection to 8.8.8.8#853(8.8.8.8) for one.one.one.one failed: connection refused.
;; no servers could be reached
;; Connection to 8.8.8.8#853(8.8.8.8) for one.one.one.one failed: connection refused.
;; Connection to 8.8.4.4#853(8.8.4.4) for one.one.one.one failed: connection refused.
;; no servers could be reached
```

```shell
$ dig one.one.one.one +https
;; Connection to 8.8.8.8#443(8.8.8.8) for one.one.one.one failed: connection refused.
;; no servers could be reached
;; Connection to 8.8.8.8#443(8.8.8.8) for one.one.one.one failed: connection refused.
;; no servers could be reached
;; Connection to 8.8.8.8#443(8.8.8.8) for one.one.one.one failed: connection refused.
;; Connection to 8.8.4.4#443(8.8.4.4) for one.one.one.one failed: connection refused.
;; no servers could be reached
```

dot/dohならいけるかと思ったが失敗した。

## dig dot/doh (BlahDNS)

```shell
$ dig example.com @dot-sg.blahdns.com +tls
;; Connection to 146.112.61.106#853(146.112.61.106) for example.com failed: connection refused.
;; no servers could be reached
;; Connection to 146.112.61.106#853(146.112.61.106) for example.com failed: connection refused.
;; no servers could be reached
;; Connection to 146.112.61.106#853(146.112.61.106) for example.com failed: connection refused.
;; no servers could be reached
```

```shell
$ dig example.com @doh-sg.blahdns.com +https=/dns-query
;; Connection to 146.112.61.106#443(146.112.61.106) for example.com failed: ALPN for HTTP/2 failed.
;; no servers could be reached
;; Connection to 146.112.61.106#443(146.112.61.106) for example.com failed: ALPN for HTTP/2 failed.
;; no servers could be reached
;; Connection to 146.112.61.106#443(146.112.61.106) for example.com failed: ALPN for HTTP/2 failed.
;; no servers could be reached
```

マイナーなDNSサーバーを使ってもdot/dohは失敗した。

## dig dot SNI指定 (BlahDNS)

```shell
$ dig example.com @46.250.226.242 +tls +tls-host=dot-sg.blahdns.com
;; Connection to 46.250.226.242#853(46.250.226.242) for example.com failed: connection refused.
;; no servers could be reached
;; Connection to 46.250.226.242#853(46.250.226.242) for example.com failed: connection refused.
;; no servers could be reached
;; Connection to 46.250.226.242#853(46.250.226.242) for example.com failed: connection refused.
;; no servers could be reached
```

SNI指定をしてもdotは失敗した。
ポートがブロックされていると見られる。

## dig doh SNI指定 (BlahDNS)

```shell
$ dig example.com @46.250.226.242 +https=/dns-query +tls-host=doh-sg.blahdns.com

; <<>> DiG 9.20.18 <<>> example.com @46.250.226.242 +https=/dns-query +tls-host=doh-sg.blahdns.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 21266
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;example.com.                   IN      A

;; ANSWER SECTION:
example.com.            238     IN      A       104.18.26.120
example.com.            238     IN      A       104.18.27.120

;; Query time: 192 msec
;; SERVER: 46.250.226.242#443(46.250.226.242) (HTTPS)
;; WHEN: Mon Feb 16 13:29:58 JST 2026
;; MSG SIZE  rcvd: 72
```

```shell
$ dig one.one.one.one @46.250.226.242 +https=/dns-query +tls-host=doh-sg.blahdns.com

; <<>> DiG 9.20.18 <<>> one.one.one.one @46.250.226.242 +https=/dns-query +tls-host=doh-sg.blahdns.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 33086
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;one.one.one.one.               IN      A

;; ANSWER SECTION:
one.one.one.one.        38147   IN      A       1.0.0.1
one.one.one.one.        38147   IN      A       1.1.1.1

;; Query time: 160 msec
;; SERVER: 46.250.226.242#443(46.250.226.242) (HTTPS)
;; WHEN: Mon Feb 16 13:30:26 JST 2026
;; MSG SIZE  rcvd: 76
```

DNSのドメインがブロックされていたらしく、dohではSNI指定をすると成功した。
通常ブロックされているサイトでも名前解決に成功したため、きちんと回避できている。

## curl doh SNI指定

```shell
$ curl example.com -v --doh-url https://doh-sg.blahdns.com/dns-query --resolve doh-sg.blahdns.com:443:46.250.226.242                                                  
* Added doh-sg.blahdns.com:443:46.250.226.242 to DNS cache                                                  * Host example.com:80 was resolved.                     
* IPv6: 2606:4700::6812:1b78, 2606:4700::6812:1a78      
* IPv4: 104.18.26.120, 104.18.27.120                    
*   Trying [2606:4700::6812:1b78]:80...                 
* Immediate connect fail for 2606:4700::6812:1b78: Network is unreachable                                   *   Trying 104.18.26.120:80...                          
* Established connection to example.com (104.18.26.120 port 80) from 10.68.56.43 port 60668                 * using HTTP/1.x                                        
> GET / HTTP/1.1                                        
> Host: example.com                                     
> User-Agent: curl/8.18.0                               
> Accept: */*                                           
>                                                       
* Request completely sent off                           
< HTTP/1.1 200 OK                                       
< Date: Mon, 16 Feb 2026 04:57:21 GMT                   
< Content-Type: text/html                               
< Transfer-Encoding: chunked                            
< Connection: keep-alive                                
< CF-RAY: 9cea76b649c778bd-NRT                          
< Last-Modified: Thu, 12 Feb 2026 14:00:39 GMT          
< Allow: GET, HEAD
< Accept-Ranges: bytes
< Age: 3031
< cf-cache-status: HIT
< Server: cloudflare
<
<!doctype html><html lang="en"><head><title>Example Domain</title><meta name="viewport" content="width=device-width, initial-scale=1"><style>body{background:#eee;width:60vw;margin:15vh auto;font-family:system-ui,sans-serif}h1{font-size:1.5em}div{opacity:0.8}a:link,a:visited{color:#348}</style></head><body><div><h1>Example Domain</h1><p>This domain is for use in documentation examples without needing permission. Avoid use in operations.</p><p><a href="https://iana.org/domains/example">Learn more</a></p></div></body></html>
* Connection #0 to host example.com:80 left intact
```

```shell
$ curl proton.me -v --doh-url https://doh-sg.blahdns.com/dns-query --resolve doh-sg.blahdns.com:443:46.250.226.242                                                    
* Added doh-sg.blahdns.com:443:46.250.226.242 to DNS cache                                                  * Host proton.me:80 was resolved.                       
* IPv6: (none)                                          
* IPv4: 185.70.42.45                                    
*   Trying 185.70.42.45:80...                       
* Established connection to proton.me (185.70.42.45 port 80) from 10.68.56.43 port 40052                    * using HTTP/1.x                                        
> GET / HTTP/1.1                                        
> Host: proton.me                                       
> User-Agent: curl/8.18.0                               
> Accept: */*                                           
>                                                       
* Request completely sent off                           
< HTTP/1.1 301 Moved Permanently                        
< content-length: 0                                     
< location: https://proton.me/                          
<                                                       
* Connection #0 to host proton.me:80 left 
```

これを踏まえてcurlしてみると、成功した。

## dig dot (BlahDNS) + AdAway

```adaway
dot-sg.blahdns.com -> 146.112.61.106
```

```shell
$ dig example.com @dot-sg.blahdns.com +tls
;; Connection to 146.112.61.106#853(146.112.61.106) for example.com failed: connection refused.
;; no servers could be reached
;; Connection to 146.112.61.106#853(146.112.61.106) for example.com failed: connection refused.
;; no servers could be reached
;; Connection to 146.112.61.106#853(146.112.61.106) for example.com failed: connection refused.
;; no servers could be reached
```

## dig doh (BlahDNS) + AdAway

```adaway
doh-sg.blahdns.com -> 46.250.226.242
```

```shell
$ dig one.one.one.one @doh-sg.blahdns.com +https=/dns-query

; <<>> DiG 9.20.18 <<>> one.one.one.one @doh-sg.blahdns.com +https=/dns-query
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 15060
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;one.one.one.one.               IN      A

;; ANSWER SECTION:
one.one.one.one.        37761   IN      A       1.0.0.1
one.one.one.one.        37761   IN      A       1.1.1.1

;; Query time: 1640 msec
;; SERVER: 46.250.226.242#443(doh-sg.blahdns.com) (HTTPS)
;; WHEN: Mon Feb 16 13:36:53 JST 2026
;; MSG SIZE  rcvd: 76
```

adawayでopennicの名前解決のみを行うことでも成功した。

## RethinkDNS での DoH ホスト名解決 (2026-10-30 追記)

Android の RethinkDNS に `https://tyo03.dnscry.pt/dns-query` を直接指定したところ疎通した。
学内 DNS では `tyo02.dnscry.pt`、`doh.dns4all.eu` 等の DoH 用ホスト名がフィルタ用 IP (`146.112.61.106` 等) にすり替えられているが、
RethinkDNS は DoH サーバーのホスト名を独自に解決するため、学内 DNS のすり替えの影響を受けにくいと見られる。
一方 iOS の構成プロファイルはホスト名を学内 DNS で解決するため、すり替え対象ホスト名のサーバーは使えない。

## Linux での OS 全体 DoH (2026-10-29 検証)

Arch Linux + NetworkManager + systemd-resolved で OS 全体に DoH を適用した。
systemd-resolved は DoH 未対応のため `dnscrypt-proxy` を localhost フォワーダにし、
`server_names` に dnscry.pt Tokyo・dns4all・dns1.slowb.ro の3件を併用した。

学内 Wi-Fi での検証結果:

```sh
$ dig one.one.one.one +short
1.1.1.1
1.0.0.1
$ curl -s -o /dev/null -w "%{http_code}\n" https://proton.me
200
$ resolvectl status  # Global DNS=127.0.0.1、Link 側 DNS なしを確認
```

`proton.me`、`example.com` ともに `200`。従来ブロックされていた Web チャットも疎通した。
ping は従来通り 100% loss のままだが、これはフィルタの仕様であり DNS とは無関係。

## DoH 用ホスト名のブロックと iOS 実機検証 (2026-10-30 追記)

学内 DNS (210.130.0.3 / 210.130.1.3) に DoH サーバーのホスト名を直接問い合わせたところ、
多くがフィルタ用 IP (`146.112.61.106` 等) にすり替えられていた。すり替えられていた主なホスト名:

- tyo02.dnscry.pt、doh.dns4all.eu、doh-de.blahdns.com、freedns.controld.com
- sky.rethinkdns.com、dns.aa.net.uk、doh.bortzmeyer.fr、dns.artikel10.org
- dns.comss.one、dns.cloudflare.com、cloudflare-dns.com

すり替えられていなかったホスト名:

- dns1.slowb.ro、tyo03.dnscry.pt、unfiltered.joindns4.eu ほか dnscry.pt の CNAME 系多数

iOS の構成プロファイルは DoH サーバーのホスト名を学内 DNS で解決するため (IP 直書き不可)、
ホスト名をすり替えられるサーバーは iPad で使えなかった (`tyo02`、`dns4all` で `proton.me` に到達不可)。
`tyo03.dnscry.pt` 単体のテストプロファイルでは iPad 実機で `proton.me` に到達できた。
