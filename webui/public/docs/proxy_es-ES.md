# Reglas de proxy

bindhosts puede ejecutar un proxy TLS local que intercepta las peticiones de los
dominios que indiques y las reescribe o bloquea por ruta de URL. Funciona de forma
independiente de las reglas hosts: hosts decide qué se bloquea con `0.0.0.0`, proxy
decide qué se responde localmente.

## Activar

1. Cambia a la vista **Proxy** en la página de reglas.
2. Activa el interruptor junto a la pestaña.
3. Añade al menos un dominio y una regla.
4. Pulsa el botón de acción.

En la primera activación se genera una CA local en
`/data/adb/bindhosts/proxy/certs/` y se instala en el almacén de confianza del
sistema. La clave privada nunca sale del dispositivo ni forma parte del módulo.

## Declarar un dominio

El proxy solo firma certificados para los dominios que se le indican. Añade una
línea hosts en `proxy/custom.txt`:

```
127.0.0.1 api.example.com
```

Esa dirección se escribe en el archivo hosts del sistema, así que las peticiones de
ese dominio llegan al proxy local en vez de a Internet. Una línea por dominio; la CA
puede firmar tantos como quieras.

## Reglas

Una regla por línea. `<path>` se compara con la ruta de la petición; un `*` final la
convierte en coincidencia por prefijo.

```
mock    <path> [body]     responder localmente con body
forward <path>            pasar la petición al servidor real
block   <path>            cerrar la conexión
```

Ejemplo:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

Las reglas se evalúan en orden del archivo y gana la primera coincidencia. Las rutas
sin regla se reenvían.

## Conjuntos de reglas

`proxy/sources.txt` acepta una URL por línea. Las descargas se guardan en
`proxy/cache/` y se reutilizan cuando todas fallan, así que una ejecución sin conexión
sigue produciendo el último conjunto conocido.

## Los conjuntos de reglas descargados son de solo lectura

Las reglas obtenidas de `sources.txt` se fusionan en el producto pero no se pueden
editar en el WebUI. La página de consulta las marca con `SRC` y no ofrece botón de
borrado. Para dejar de usar una regla descargada, quita su URL de `sources.txt`.

La vista Hosts tampoco muestra botón en las filas `SRC`: una regla descargada no
se puede quitar desde la página de consulta. Quita su URL de `sources.txt`.

## Lista blanca y lista negra

Ambas son vistas sobre `proxy/custom.txt`:

- **Lista blanca** muestra las reglas `forward`
- **Lista negra** muestra las reglas `block`

Editar cualquiera de las dos edita `proxy/custom.txt`. No son archivos separados.

## Desactivar

Apagar proxy detiene el demonio, libera `127.0.0.1:443` y elimina las entradas proxy
del archivo hosts. Los archivos de reglas y la CA se conservan, así que volver a
activarlo no requiere configuración.

La CA permanece en el almacén de confianza hasta el próximo reinicio. No se puede
desmontar en caliente porque el montaje vive en un grupo de propagación compartido.

## Solución de problemas

Revisa `/data/adb/bindhosts/proxy.log`:

| Línea | Significado |
|---|---|
| `loaded N system roots` | Debe ser distinto de cero, si no las peticiones upstream fallan |
| `signed leaf for <dominio>` | Se emitió un certificado para ese dominio |
| `drop <dominio> (not in proxy rules)` | Un dominio bloqueado llegó al proxy |
| `daemon exited ... (fail=x/10)` | El demonio muere repetidamente; tras 10 arranques cortos el proxy se desactiva solo |

Si proxy está activo pero las peticiones no se interceptan, comprueba que el dominio
tenga una línea `127.0.0.1` en `proxy/custom.txt`.
