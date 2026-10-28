# Regole proxy

bindhosts può eseguire un proxy TLS locale che intercetta le richieste dei domini
che elenchi e le riscrive o blocca per percorso URL. Funziona indipendentemente
dalle regole hosts: hosts decide cosa viene bloccato con `0.0.0.0`, proxy decide
cosa viene risposto localmente.

## Attivazione

1. Passa alla vista **Proxy** nella pagina delle regole.
2. Attiva l'interruttore accanto alla scheda.
3. Aggiungi almeno un dominio e una regola.
4. Premi il pulsante action.

Alla prima attivazione viene generata una CA locale in
`/data/adb/bindhosts/proxy/certs/` e installata nell'archivio attendibile di
sistema. La chiave privata non lascia mai il dispositivo e non fa parte del modulo.

## Dichiarare un dominio

Il proxy firma certificati solo per i domini che gli vengono indicati. Aggiungi una
riga hosts in `proxy/custom.txt`:

```
127.0.0.1 api.example.com
```

Quell'indirizzo viene scritto nel file hosts di sistema, quindi le richieste per il
dominio raggiungono il proxy locale invece di Internet. Una riga per dominio; la CA
può firmarne quanti vuoi.

## Regole

Una regola per riga. `<path>` viene confrontato con il percorso della richiesta; un
`*` finale lo rende una corrispondenza per prefisso.

```
mock    <path> [body]     rispondere localmente con body
forward <path>            inoltrare la richiesta al server reale
block   <path>            chiudere la connessione
```

Esempio:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

Le regole sono valutate nell'ordine del file e vince la prima corrispondenza. I
percorsi senza regola vengono inoltrati.

## Set di regole

`proxy/sources.txt` accetta un URL per riga. I download vengono memorizzati in
`proxy/cache/` e riutilizzati quando tutti falliscono, così un'esecuzione offline
produce comunque l'ultimo set conosciuto.

## I set di regole scaricati sono di sola lettura

Le regole recuperate da `sources.txt` vengono unite nel prodotto ma non sono
modificabili nel WebUI. La pagina di query le contrassegna con `SRC` e non offre un
pulsante di eliminazione. Per disattivare una regola scaricata, rimuovi il suo URL
da `sources.txt`.

Anche la vista Hosts non mostra pulsanti sulle righe `SRC`: una regola scaricata
non può essere rimossa dalla pagina di query. Rimuovi il suo URL da `sources.txt`.

## Lista bianca e lista nera

Entrambe sono viste su `proxy/custom.txt`:

- **Lista bianca** elenca le regole `forward`
- **Lista nera** elenca le regole `block`

Modificare l'una o l'altra modifica `proxy/custom.txt`. Non sono file separati.

## Disattivazione

Spegnere proxy ferma il demone, libera `127.0.0.1:443` e rimuove le voci proxy dal
file hosts. I file delle regole e la CA vengono conservati, quindi riattivarlo non
richiede configurazione.

La CA resta nell'archivio attendibile fino al riavvio successivo. Non è possibile
smontarla a caldo perché il mount si trova in un gruppo di propagazione condiviso.

## Risoluzione dei problemi

Controlla `/data/adb/bindhosts/proxy.log`:

| Riga | Significato |
|---|---|
| `loaded N system roots` | Deve essere diverso da zero, altrimenti le richieste upstream falliscono |
| `signed leaf for <dominio>` | È stato emesso un certificato per quel dominio |
| `drop <dominio> (not in proxy rules)` | Un dominio bloccato ha raggiunto il proxy |
| `daemon exited ... (fail=x/10)` | Il demone muore ripetutamente; dopo 10 avvii brevi il proxy si disattiva da solo |

Se proxy è attivo ma le richieste non vengono intercettate, verifica che il dominio
abbia una riga `127.0.0.1` in `proxy/custom.txt`.
