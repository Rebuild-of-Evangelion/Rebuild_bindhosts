# Proxy rules

bindhosts can run a local TLS proxy that intercepts requests for the domains you
list and rewrites or blocks them per URL path. It works independently of the
hosts rules: hosts decides what gets blocked with `0.0.0.0`, proxy decides what
gets answered locally.

## Enabling

1. Switch to the **Proxy** view in the rules page.
2. Turn on the switch next to the tab.
3. Add at least one domain and one rule.
4. Press the action button.

On first enable a local CA is generated under
`/data/adb/bindhosts/proxy/certs/` and installed into the system trust store.
The private key never leaves the device and is not part of the module.

## Declaring a domain

The proxy only signs certificates for domains it is told about. Add a hosts line
to `proxy/custom.txt`:

```
127.0.0.1 api.example.com
```

That address is written into the system hosts file, so requests for the domain
reach the local proxy instead of the internet. One line per domain; the CA can
sign any number of them.

## Rules

One rule per line. `<path>` is matched against the request path; a trailing `*`
turns it into a prefix match.

```
mock    <path> [body]     answer locally with body
forward <path>            pass the request to the real server
block   <path>            close the connection
```

Example:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

Rules are matched in file order and the first match wins. Paths without a
matching rule are forwarded.

## Rule sets

`proxy/sources.txt` takes one URL per line. Downloads are cached under
`proxy/cache/` and reused when every download fails, so an offline run still
produces the last known rule set.

## Whitelist and blacklist

Both are views over `proxy/custom.txt`:

- **Whitelist** lists the `forward` rules
- **Blacklist** lists the `block` rules

Editing either one edits `proxy/custom.txt`. They are not separate files.

## Disabling

Switching proxy off stops the daemon, releases `127.0.0.1:443` and removes the
proxy entries from the hosts file. Rule files and the CA are kept, so enabling it
again needs no setup.

The CA stays in the trust store until the next reboot. It cannot be unmounted at
runtime because the mount lives in a shared propagation group.

## Troubleshooting

Check `/data/adb/bindhosts/proxy.log`:

| Line | Meaning |
|---|---|
| `loaded N system roots` | Must be non-zero, otherwise upstream requests fail |
| `signed leaf for <domain>` | A certificate was issued for that domain |
| `drop <domain> (not in proxy rules)` | A blocked domain reached the proxy |
| `daemon exited ... (fail=x/10)` | The daemon keeps dying; after 10 short starts the proxy disables itself |

If proxy is enabled but requests are not intercepted, check that the domain has a
`127.0.0.1` line in `proxy/custom.txt`.
