# Regras de proxy

O bindhosts pode executar um proxy TLS local que intercepta requisições dos domínios
que você listar e as reescreve ou bloqueia por caminho de URL. Ele funciona
independentemente das regras hosts: hosts decide o que é bloqueado com `0.0.0.0`,
proxy decide o que é respondido localmente.

## Ativando

1. Mude para a visão **Proxy** na página de regras.
2. Ligue o interruptor ao lado da aba.
3. Adicione pelo menos um domínio e uma regra.
4. Pressione o botão de ação.

Na primeira ativação uma CA local é gerada em
`/data/adb/bindhosts/proxy/certs/` e instalada no armazenamento de confiança do
sistema. A chave privada nunca sai do dispositivo nem faz parte do módulo.

## Declarando um domínio

O proxy só assina certificados para domínios que lhe foram informados. Adicione uma
linha hosts em `proxy/custom.txt`:

```
127.0.0.1 api.example.com
```

Esse endereço é gravado no arquivo hosts do sistema, então requisições para o domínio
chegam ao proxy local em vez da internet. Uma linha por domínio; a CA pode assinar
quantos forem necessários.

## Regras

Uma regra por linha. `<path>` é comparado com o caminho da requisição; um `*` no final
torna a correspondência por prefixo.

```
mock    <path> [body]     responder localmente com body
forward <path>            repassar a requisição ao servidor real
block   <path>            fechar a conexão
```

Exemplo:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

As regras são avaliadas na ordem do arquivo e a primeira correspondência vence.
Caminhos sem regra são repassados.

## Conjuntos de regras

`proxy/sources.txt` aceita uma URL por linha. Os downloads são armazenados em
`proxy/cache/` e reutilizados quando todos falham, então uma execução offline ainda
produz o último conjunto conhecido.

## Conjuntos de regras baixados são somente leitura

As regras obtidas de `sources.txt` são mescladas no produto, mas não podem ser
editadas no WebUI. A página de consulta as marca com `SRC` e não oferece botão de
exclusão. Para desativar uma regra baixada, remova a URL dela de `sources.txt`.

A visão Hosts também não mostra botão nas linhas `SRC`: uma regra baixada não
pode ser removida pela página de consulta. Remova a URL dela de `sources.txt`.

## Lista branca e lista negra

Ambas são visões sobre `proxy/custom.txt`:

- **Lista branca** lista as regras `forward`
- **Lista negra** lista as regras `block`

Editar qualquer uma delas edita `proxy/custom.txt`. Não são arquivos separados.

## Desativando

Desligar o proxy para o daemon, libera `127.0.0.1:443` e remove as entradas proxy do
arquivo hosts. Os arquivos de regras e a CA são mantidos, então reativar não exige
configuração.

A CA permanece no armazenamento de confiança até a próxima reinicialização. Não é
possível desmontá-la em tempo de execução porque o ponto de montagem está em um grupo
de propagação compartilhado.

## Solução de problemas

Verifique `/data/adb/bindhosts/proxy.log`:

| Linha | Significado |
|---|---|
| `loaded N system roots` | Precisa ser diferente de zero, senão as requisições upstream falham |
| `signed leaf for <domínio>` | Um certificado foi emitido para esse domínio |
| `drop <domínio> (not in proxy rules)` | Um domínio bloqueado chegou ao proxy |
| `daemon exited ... (fail=x/10)` | O daemon morre repetidamente; após 10 inicializações curtas o proxy se desativa |

Se o proxy está ativo mas as requisições não são interceptadas, confira se o domínio
tem uma linha `127.0.0.1` em `proxy/custom.txt`.
