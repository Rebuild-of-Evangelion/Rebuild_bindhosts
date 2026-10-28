# Proxy 规则

bindhosts 可以跑一个本地 TLS 反代，拦截你列出的域名的请求，按 URL 路径改写或拦截。
它和 hosts 规则相互独立：hosts 决定哪些域名被 `0.0.0.0` 拦掉，proxy 决定哪些请求在本地应答。

## 启用

1. 在规则页切到 **Proxy** 视图。
2. 打开标签旁边的开关。
3. 至少加一个域名和一条规则。
4. 按 action 按钮。

首次启用时会在 `/data/adb/bindhosts/proxy/certs/` 下生成一张本地 CA，并装进系统信任库。
私钥不出设备，也不随模块分发。

## 声明域名

反代只给「被告知过」的域名签发证书。在 `proxy/custom.txt` 里加一行 hosts 记录：

```
127.0.0.1 api.example.com
```

这一行会被写进系统 hosts，该域名的请求就会到达本地反代而不是公网。
一个域名一行，CA 可以签任意多个。

## 规则

一行一条。`<path>` 匹配请求路径，末尾的 `*` 表示前缀匹配。

```
mock    <path> [body]     本地返回 body
forward <path>            原样转发给真实服务器
block   <path>            直接断开连接
```

示例：

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

按文件顺序匹配，第一条命中即生效。没有规则命中的路径默认转发。

## 规则集

`proxy/sources.txt` 一行一个 URL。下载内容会缓存到 `proxy/cache/`，
所有下载都失败时用缓存重建，所以断网也能得到上次的规则集。

## 下载的规则集是只读的

`sources.txt` 下载的规则会合并进产物，但 WebUI 里不能编辑。
查询页给它们标 `SRC`，不提供删除按钮。要停用某条下载来的规则，
把它的 URL 从 `sources.txt` 里去掉。

Hosts 查询页的 `SRC` 条目有个按钮，但那也不是删除——它把域名写进
`hosts/whitelist.txt`，下次重建时跳过。

## 白名单与黑名单

两者都是 `proxy/custom.txt` 的视图：

- **白名单** 列出 `forward` 规则
- **黑名单** 列出 `block` 规则

编辑其中任何一个都是在改 `proxy/custom.txt`，不是独立文件。

## 禁用

关掉 proxy 会停止守护进程、释放 `127.0.0.1:443`、并从 hosts 里摘掉 proxy 条目。
规则文件和 CA 会保留，再次启用不需要重新配置。

CA 会一直留在信任库里直到下次重启。运行时撤不掉，因为挂载点位于共享传播组中。

## 排查

看 `/data/adb/bindhosts/proxy.log`：

| 日志 | 含义 |
|---|---|
| `loaded N system roots` | 必须非零，否则上游请求必然失败 |
| `signed leaf for <域名>` | 已为该域名签发证书 |
| `drop <域名> (not in proxy rules)` | 被拦截的域名打到了反代 |
| `daemon exited ... (fail=x/10)` | 守护进程反复退出，连续 10 次短命启动后会禁用 proxy |

如果 proxy 开着但请求没被拦截，先确认该域名在 `proxy/custom.txt` 里有 `127.0.0.1` 那一行。
