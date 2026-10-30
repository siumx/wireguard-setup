# WireGuard setup

Ubuntu 上一鍵安裝 WireGuard Server，直接為每台裝置產出獨立的 Client `.conf`。

適用：Debian／Ubuntu、root（`sudo`）。

## Deploy

在 Server 執行：

```bash
curl -fLO https://raw.githubusercontent.com/siumx/wireguard-setup/main/wireguard-setup.sh
sudo bash wireguard-setup.sh
```

首次執行（沒有 `/etc/wireguard/wg0.conf`）會：

1. 安裝 `wireguard`、`dnsmasq`
2. 詢問 UDP Port（預設 `51820`）、公網出口介面、VPN IPv4 網段（預設 `10.66.66.0/24`）
3. 寫入 `wg0`、開啟 IPv4 forwarding、設定 dnsmasq（`interface=wg0`，`filter-AAAA`，上游 `1.1.1.1`）
4. 若 UFW 已啟用，放行該 UDP Port
5. 詢問 Endpoint（公網 IPv4 或網域，不含協定與 Port；有 `curl` 時會嘗試偵測）
6. 詢問 Client 名稱（空格分隔），寫入 Peer，把 `.conf` 放到執行 `sudo` 那位使用者的 `~/wireguard-client/`

之後再跑同一支腳本：偵測到 `wg0.conf` 就進入新增 Peer mode，沿用既有 Server 金鑰、UDP Port 與 VPN 網段，只再問 Endpoint 與新的 Client 名稱。

雲端 Security Group／VPC 防火牆必須放行 WireGuard UDP Port。腳本不會改雲端防火牆。

### 提示與約束

| 項目 | 行為 |
| --- | --- |
| 權限 | 必須 root。輸出目錄是 `$SUDO_USER` 的家目錄 |
| 鎖 | `/run/lock/wireguard-client.lock`，同時只能跑一份 |
| 網段 | 必須 `x.x.x.0/24`；Server 位址是 `.1`。與既有路由衝突會失敗 |
| Client 名稱 | 英數字、底線、連字號，長度 1–15，大小寫不敏感不可重複 |
| Client IP | 從 `.2` 起找尚未出現在 `wg0.conf` 的 `/32` |
| Endpoint | 每次都問，不記住上次輸入 |
| 備份 | 改 Server 設定前會把 `wg0.conf` 備份到 `/etc/wireguard/wg0.conf.backup.*`，並刪掉 `SaveConfig` |
| 符號連結 | `wg0.conf` 與輸出目錄不可是 symlink |

### Client 端

1. 下載自己的 `.conf`（GCP Web SSH 可點下載，或用 `scp`）
2. WireGuard 客戶端選 Import tunnel from file
**3. 每台裝置一份配置，不要共用同一個 `.conf`**

列出本機產生的檔案：

```bash
realpath ~/wireguard-client/*
```

