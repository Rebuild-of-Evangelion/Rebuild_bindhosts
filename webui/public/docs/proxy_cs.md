# Pravidla proxy

bindhosts umí spustit lokální TLS proxy, které zachytává požadavky na uvedené domény
a přepisuje nebo blokuje je podle cesty URL. Pracuje nezávisle na pravidlech hosts:
hosts rozhoduje, co se blokuje přes `0.0.0.0`, proxy rozhoduje, co se odpovídá lokálně.

## Zapnutí

1. Přepněte na zobrazení **Proxy** na stránce pravidel.
2. Zapněte přepínač vedle karty.
3. Přidejte alespoň jednu doménu a jedno pravidlo.
4. Stiskněte tlačítko action.

Při prvním zapnutí se v `/data/adb/bindhosts/proxy/certs/` vytvoří lokální CA a
nainstaluje se do systémového úložiště důvěry. Soukromý klíč neopouští zařízení a
není součástí modulu.

## Deklarace domény

Proxy podepisuje certifikáty jen pro domény, o kterých ví. Přidejte řádek hosts do
`proxy/custom.txt`:

```
127.0.0.1 api.example.com
```

Tato adresa se zapíše do systémového hosts, takže požadavky na doménu dorazí do
lokálního proxy místo na internet. Jeden řádek na doménu; CA jich může podepsat
libovolně mnoho.

## Pravidla

Jedno pravidlo na řádek. `<path>` se porovnává s cestou požadavku; koncová `*` z něj
udělá shodu prefixem.

```
mock    <path> [body]     odpovědět lokálně tělem body
forward <path>            předat požadavek skutečnému serveru
block   <path>            uzavřít spojení
```

Příklad:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

Pravidla se vyhodnocují v pořadí v souboru, vyhrává první shoda. Cesty bez pravidla
se předávají dál.

## Sady pravidel

`proxy/sources.txt` přijímá jednu URL na řádek. Stažený obsah se ukládá do
`proxy/cache/` a použije se, když všechna stahování selžou, takže offline běh stále
vytvoří poslední známou sadu pravidel.

## Bílý a černý seznam

Oba jsou zobrazení `proxy/custom.txt`:

- **Bílý seznam** vypisuje pravidla `forward`
- **Černý seznam** vypisuje pravidla `block`

Úprava kteréhokoli z nich mění `proxy/custom.txt`. Nejsou to samostatné soubory.

## Vypnutí

Vypnutí proxy zastaví daemona, uvolní `127.0.0.1:443` a odstraní záznamy proxy
ze souboru hosts. Soubory pravidel a CA zůstávají, takže opětovné zapnutí
nevyžaduje konfiguraci.

CA zůstává v úložišti důvěry do dalšího restartu. Za běhu ji nelze odpojit, protože
přípojný bod leží ve sdílené propagační skupině.

## Řešení problémů

Podívejte se do `/data/adb/bindhosts/proxy.log`:

| Řádek | Význam |
|---|---|
| `loaded N system roots` | Musí být nenulové, jinak požadavky na server selžou |
| `signed leaf for <doména>` | Pro doménu byl vydán certifikát |
| `drop <doména> (not in proxy rules)` | Blokovaná doména dorazila do proxy |
| `daemon exited ... (fail=x/10)` | Daemon opakovaně padá; po 10 krátkých startech se proxy samo vypne |

Pokud je proxy zapnuté, ale požadavky se nezachytávají, zkontrolujte, zda má doména
řádek `127.0.0.1` v `proxy/custom.txt`.
