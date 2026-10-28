# Règles proxy

bindhosts peut lancer un proxy TLS local qui intercepte les requêtes des domaines
que vous listez et les réécrit ou les bloque par chemin d'URL. Il fonctionne
indépendamment des règles hosts : hosts décide de ce qui est bloqué par `0.0.0.0`,
proxy décide de ce qui est répondu localement.

## Activer

1. Passez à la vue **Proxy** dans la page des règles.
2. Activez l'interrupteur à côté de l'onglet.
3. Ajoutez au moins un domaine et une règle.
4. Appuyez sur le bouton action.

À la première activation, une CA locale est générée dans
`/data/adb/bindhosts/proxy/certs/` et installée dans le magasin de confiance du
système. La clé privée ne quitte jamais l'appareil et ne fait pas partie du module.

## Déclarer un domaine

Le proxy ne signe des certificats que pour les domaines qu'on lui indique. Ajoutez
une ligne hosts dans `proxy/custom.txt` :

```
127.0.0.1 api.example.com
```

Cette adresse est écrite dans le fichier hosts du système, les requêtes pour ce
domaine atteignent donc le proxy local au lieu d'Internet. Une ligne par domaine ;
la CA peut en signer autant que nécessaire.

## Règles

Une règle par ligne. `<path>` est comparé au chemin de la requête ; un `*` final en
fait une correspondance de préfixe.

```
mock    <path> [body]     répondre localement avec body
forward <path>            transmettre la requête au vrai serveur
block   <path>            fermer la connexion
```

Exemple :

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

Les règles sont évaluées dans l'ordre du fichier, la première correspondance
l'emporte. Les chemins sans règle correspondante sont transmis.

## Jeux de règles

`proxy/sources.txt` accepte une URL par ligne. Les téléchargements sont mis en cache
dans `proxy/cache/` et réutilisés quand tous les téléchargements échouent : une
exécution hors ligne produit donc le dernier jeu de règles connu.

## Liste blanche et liste noire

Les deux sont des vues sur `proxy/custom.txt` :

- **Liste blanche** affiche les règles `forward`
- **Liste noire** affiche les règles `block`

Modifier l'une ou l'autre modifie `proxy/custom.txt`. Ce ne sont pas des fichiers
séparés.

## Désactiver

Désactiver proxy arrête le démon, libère `127.0.0.1:443` et retire les entrées proxy
du fichier hosts. Les fichiers de règles et la CA sont conservés, une réactivation ne
demande donc aucune configuration.

La CA reste dans le magasin de confiance jusqu'au prochain redémarrage. Elle ne peut
pas être démontée à chaud car le montage se trouve dans un groupe de propagation
partagé.

## Dépannage

Consultez `/data/adb/bindhosts/proxy.log` :

| Ligne | Signification |
|---|---|
| `loaded N system roots` | Doit être non nul, sinon les requêtes upstream échouent |
| `signed leaf for <domaine>` | Un certificat a été émis pour ce domaine |
| `drop <domaine> (not in proxy rules)` | Un domaine bloqué a atteint le proxy |
| `daemon exited ... (fail=x/10)` | Le démon meurt en boucle ; après 10 démarrages courts le proxy se désactive |

Si proxy est actif mais que les requêtes ne sont pas interceptées, vérifiez que le
domaine a bien une ligne `127.0.0.1` dans `proxy/custom.txt`.
