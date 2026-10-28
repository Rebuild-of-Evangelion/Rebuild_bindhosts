# Proxyregler

bindhosts kan köra en lokal TLS-proxy som fångar upp förfrågningar till de domäner
du listar och skriver om eller blockerar dem per URL-sökväg. Den arbetar oberoende av
hosts-reglerna: hosts avgör vad som blockeras med `0.0.0.0`, proxy avgör vad som
besvaras lokalt.

## Aktivera

1. Byt till vyn **Proxy** på regelsidan.
2. Slå på reglaget bredvid fliken.
3. Lägg till minst en domän och en regel.
4. Tryck på action-knappen.

Vid första aktiveringen skapas en lokal CA i `/data/adb/bindhosts/proxy/certs/` och
installeras i systemets certifikatarkiv. Den privata nyckeln lämnar aldrig enheten
och ingår inte i modulen.

## Deklarera en domän

Proxyn signerar bara certifikat för domäner den fått veta om. Lägg till en hosts-rad
i `proxy/custom.txt`:

```
127.0.0.1 api.example.com
```

Adressen skrivs till systemets hosts-fil, så förfrågningar till domänen når den
lokala proxyn i stället för internet. En rad per domän; CA:n kan signera hur många
som helst.

## Regler

En regel per rad. `<path>` jämförs med förfrågans sökväg; ett avslutande `*` gör det
till en prefixmatchning.

```
mock    <path> [body]     svara lokalt med body
forward <path>            skicka vidare till den riktiga servern
block   <path>            stäng anslutningen
```

Exempel:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

Reglerna utvärderas i filordning och första träffen vinner. Sökvägar utan regel
skickas vidare.

## Regelmängder

`proxy/sources.txt` tar en URL per rad. Nedladdningar cachas i `proxy/cache/` och
återanvänds när alla nedladdningar misslyckas, så en offlinekörning ger fortfarande
den senast kända regelmängden.

## Nedladdade regelmängder är skrivskyddade

Regler från `sources.txt` slås samman i produkten men kan inte redigeras i WebUI.
Förfrågningssidan markerar dem med `SRC` och erbjuder ingen raderingsknapp. För att
sluta använda en nedladdad regel tar du bort dess URL från `sources.txt`.

Hosts-vyn visar en knapp på `SRC`-rader, men inte heller den raderar något: den
lägger till domänen i `hosts/whitelist.txt` så att nästa ombyggnad hoppar över den.

## Vitlista och svartlista

Båda är vyer över `proxy/custom.txt`:

- **Vitlista** listar `forward`-reglerna
- **Svartlista** listar `block`-reglerna

Att redigera någon av dem ändrar `proxy/custom.txt`. De är inte separata filer.

## Inaktivera

Att stänga av proxy stoppar daemonen, frigör `127.0.0.1:443` och tar bort
proxy-posterna från hosts-filen. Regelfiler och CA behålls, så att slå på igen kräver
ingen konfiguration.

CA:n ligger kvar i certifikatarkivet till nästa omstart. Den kan inte avmonteras
under drift eftersom monteringen ligger i en delad spridningsgrupp.

## Felsökning

Titta i `/data/adb/bindhosts/proxy.log`:

| Rad | Betydelse |
|---|---|
| `loaded N system roots` | Måste vara skilt från noll, annars misslyckas förfrågningar uppströms |
| `signed leaf for <domän>` | Ett certifikat utfärdades för domänen |
| `drop <domän> (not in proxy rules)` | En blockerad domän nådde proxyn |
| `daemon exited ... (fail=x/10)` | Daemonen dör gång på gång; efter 10 korta starter inaktiverar proxyn sig själv |

Om proxy är på men förfrågningar inte fångas upp, kontrollera att domänen har en
`127.0.0.1`-rad i `proxy/custom.txt`.
