# Proxy-Regeln

bindhosts kann einen lokalen TLS-Proxy betreiben, der Anfragen an die von dir
gelisteten Domains abfängt und pro URL-Pfad umschreibt oder blockiert. Er arbeitet
unabhängig von den hosts-Regeln: hosts entscheidet, was per `0.0.0.0` blockiert
wird, proxy entscheidet, was lokal beantwortet wird.

## Aktivieren

1. In der Regelseite auf die Ansicht **Proxy** wechseln.
2. Den Schalter neben dem Tab einschalten.
3. Mindestens eine Domain und eine Regel hinzufügen.
4. Die Action-Schaltfläche drücken.

Beim ersten Aktivieren wird unter `/data/adb/bindhosts/proxy/certs/` eine lokale CA
erzeugt und in den System-Truststore installiert. Der private Schlüssel verlässt das
Gerät nicht und ist nicht Teil des Moduls.

## Domain deklarieren

Der Proxy signiert nur Zertifikate für Domains, die ihm genannt wurden. Füge eine
hosts-Zeile in `proxy/custom.txt` hinzu:

```
127.0.0.1 api.example.com
```

Diese Adresse wird in die System-hosts-Datei geschrieben, sodass Anfragen für die
Domain den lokalen Proxy statt das Internet erreichen. Eine Zeile pro Domain; die CA
kann beliebig viele signieren.

## Regeln

Eine Regel pro Zeile. `<path>` wird gegen den Anfragepfad geprüft; ein abschließendes
`*` macht daraus eine Präfixübereinstimmung.

```
mock    <path> [body]     lokal mit body antworten
forward <path>            Anfrage an den echten Server weiterreichen
block   <path>            Verbindung schließen
```

Beispiel:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

Regeln werden in Dateireihenfolge geprüft, der erste Treffer gewinnt. Pfade ohne
passende Regel werden weitergeleitet.

## Regelsätze

`proxy/sources.txt` nimmt eine URL pro Zeile. Downloads werden unter `proxy/cache/`
zwischengespeichert und wiederverwendet, wenn alle Downloads fehlschlagen — ein
Offline-Lauf liefert also den zuletzt bekannten Regelsatz.

## Whitelist und Blacklist

Beide sind Ansichten auf `proxy/custom.txt`:

- **Whitelist** listet die `forward`-Regeln
- **Blacklist** listet die `block`-Regeln

Beide zu bearbeiten ändert `proxy/custom.txt`. Es sind keine eigenen Dateien.

## Deaktivieren

Das Ausschalten von proxy stoppt den Daemon, gibt `127.0.0.1:443` frei und entfernt
die Proxy-Einträge aus der hosts-Datei. Regelsätze und CA bleiben erhalten, ein
erneutes Aktivieren braucht also keine Einrichtung.

Die CA bleibt bis zum nächsten Neustart im Truststore. Zur Laufzeit lässt sie sich
nicht aushängen, weil der Mount in einer gemeinsamen Propagation-Gruppe liegt.

## Fehlersuche

Prüfe `/data/adb/bindhosts/proxy.log`:

| Zeile | Bedeutung |
|---|---|
| `loaded N system roots` | Muss ungleich 0 sein, sonst schlagen Upstream-Anfragen fehl |
| `signed leaf for <domain>` | Für diese Domain wurde ein Zertifikat ausgestellt |
| `drop <domain> (not in proxy rules)` | Eine blockierte Domain hat den Proxy erreicht |
| `daemon exited ... (fail=x/10)` | Der Daemon stirbt wiederholt; nach 10 kurzen Starts deaktiviert sich der Proxy selbst |

Wenn proxy aktiv ist, Anfragen aber nicht abgefangen werden, prüfe, ob die Domain
eine `127.0.0.1`-Zeile in `proxy/custom.txt` hat.
