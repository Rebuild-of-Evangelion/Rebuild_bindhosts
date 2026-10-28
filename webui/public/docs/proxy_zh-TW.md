# Proxy 規則

bindhosts 可以執行一個本機 TLS 反向代理，攔截你列出的網域的請求，依 URL 路徑改寫或攔截。
它和 hosts 規則相互獨立：hosts 決定哪些網域被 `0.0.0.0` 攔掉，proxy 決定哪些請求在本機回應。

## 啟用

1. 在規則頁切到 **Proxy** 檢視。
2. 開啟標籤旁的開關。
3. 至少加一個網域和一條規則。
4. 按 action 按鈕。

首次啟用時會在 `/data/adb/bindhosts/proxy/certs/` 下產生一張本機 CA，並裝進系統信任庫。
私鑰不出裝置，也不隨模組分發。

## 宣告網域

反向代理只給「被告知過」的網域簽發憑證。在 `proxy/custom.txt` 裡加一行 hosts 記錄：

```
127.0.0.1 api.example.com
```

這一行會被寫進系統 hosts，該網域的請求就會到達本機反向代理而不是公網。
一個網域一行，CA 可以簽任意多個。

## 規則

一行一條。`<path>` 匹配請求路徑，末尾的 `*` 表示前綴匹配。

```
mock    <path> [body]     本機回傳 body
forward <path>            原樣轉發給真實伺服器
block   <path>            直接斷開連線
```

範例：

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

依檔案順序匹配，第一條命中即生效。沒有規則命中的路徑預設轉發。

## 規則集

`proxy/sources.txt` 一行一個 URL。下載內容會快取到 `proxy/cache/`，
所有下載都失敗時用快取重建，所以離線也能得到上次的規則集。

## 下載的規則集是唯讀的

`sources.txt` 下載的規則會合併進產物，但 WebUI 裡不能編輯。
查詢頁給它們標 `SRC`，不提供刪除按鈕。要停用某條下載來的規則，
把它的 URL 從 `sources.txt` 裡去掉。

Hosts 查詢頁的 `SRC` 條目也沒有按鈕：下載來的規則無法從查詢頁移除。
要停用某條，把它的 URL 從 `sources.txt` 裡去掉。

## 白名單與黑名單

兩者都是 `proxy/custom.txt` 的檢視：

- **白名單** 列出 `forward` 規則
- **黑名單** 列出 `block` 規則

編輯其中任何一個都是在改 `proxy/custom.txt`，不是獨立檔案。

## 停用

關掉 proxy 會停止守護行程、釋放 `127.0.0.1:443`、並從 hosts 裡摘掉 proxy 條目。
規則檔案和 CA 會保留，再次啟用不需要重新設定。

CA 會一直留在信任庫裡直到下次重開機。執行時撤不掉，因為掛載點位於共享傳播群組中。

## 排查

看 `/data/adb/bindhosts/proxy.log`：

| 日誌 | 含義 |
|---|---|
| `loaded N system roots` | 必須非零，否則上游請求必然失敗 |
| `signed leaf for <網域>` | 已為該網域簽發憑證 |
| `drop <網域> (not in proxy rules)` | 被攔截的網域打到了反向代理 |
| `daemon exited ... (fail=x/10)` | 守護行程反覆退出，連續 10 次短命啟動後會停用 proxy |

如果 proxy 開著但請求沒被攔截，先確認該網域在 `proxy/custom.txt` 裡有 `127.0.0.1` 那一行。
