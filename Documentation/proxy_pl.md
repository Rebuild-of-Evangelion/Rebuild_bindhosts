# Reguły proxy

bindhosts może uruchomić lokalny proxy TLS, który przechwytuje żądania do
wymienionych domen i przepisuje lub blokuje je według ścieżki URL. Działa niezależnie
od reguł hosts: hosts decyduje, co jest blokowane przez `0.0.0.0`, proxy decyduje,
co jest odpowiadane lokalnie.

## Włączanie

1. Przełącz się na widok **Proxy** na stronie reguł.
2. Włącz przełącznik obok zakładki.
3. Dodaj co najmniej jedną domenę i jedną regułę.
4. Naciśnij przycisk action.

Przy pierwszym włączeniu lokalny CA jest generowany w
`/data/adb/bindhosts/proxy/certs/` i instalowany w systemowym magazynie zaufania.
Klucz prywatny nie opuszcza urządzenia i nie jest częścią modułu.

## Deklarowanie domeny

Proxy podpisuje certyfikaty tylko dla domen, o których zostało poinformowane. Dodaj
wiersz hosts w `proxy/custom.txt`:

```
127.0.0.1 api.example.com
```

Ten adres trafia do systemowego pliku hosts, więc żądania do tej domeny docierają do
lokalnego proxy zamiast do internetu. Jeden wiersz na domenę; CA może podpisać ich
dowolnie wiele.

## Reguły

Jedna reguła na wiersz. `<path>` jest porównywana ze ścieżką żądania; końcowa `*`
czyni dopasowanie prefiksowym.

```
mock    <path> [body]     odpowiedz lokalnie treścią body
patch   <path> <json>     podmienia wartości kluczy i przekazuje dalej
forward <path>            przekaż żądanie do prawdziwego serwera
block   <path>            zamknij połączenie
```

Przykład:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
patch   /api/* {"appVersion":"9.9.9"}
forward /api/*
block   /ads/*
```

`patch` podmienia tylko wartość kluczy o tej samej nazwie, reszta bajtów treści
pozostaje nietknięta — kolejność pól, format liczb i odstępy się nie zmieniają.
Reguła `patch` sama przekazuje żądanie, nie dodawaj `forward` dla tej samej
ścieżki.

Reguły są sprawdzane w kolejności pliku, wygrywa pierwsze dopasowanie. Ścieżki bez
reguły są przekazywane dalej.

## Zestawy reguł

`proxy/sources.txt` przyjmuje jeden URL na wiersz. Pobrane treści są buforowane w
`proxy/cache/` i używane, gdy wszystkie pobrania zawiodą, więc uruchomienie offline
nadal daje ostatni znany zestaw reguł.

## Pobrane zestawy reguł są tylko do odczytu

Reguły pobrane z `sources.txt` trafiają do produktu, ale nie można ich edytować w
WebUI. Strona zapytań oznacza je tagiem `SRC` i nie oferuje przycisku usuwania.
Aby wyłączyć pobraną regułę, usuń jej URL z `sources.txt`.

W widoku Hosts wiersze `SRC` też nie mają przycisku: pobranej reguły nie da się
usunąć ze strony zapytań. Usuń jej URL z `sources.txt`.

## Biała i czarna lista

Obie są widokami na `proxy/custom.txt`:

- **Biała lista** pokazuje reguły `forward`
- **Czarna lista** pokazuje reguły `block`

Edycja którejkolwiek zmienia `proxy/custom.txt`. To nie są osobne pliki.

## Wyłączanie

Wyłączenie proxy zatrzymuje demona, zwalnia `127.0.0.1:443` i usuwa wpisy proxy z
pliku hosts. Pliki reguł i CA zostają, więc ponowne włączenie nie wymaga konfiguracji.

CA pozostaje w magazynie zaufania do następnego restartu. Nie da się jej odmontować
w czasie działania, bo punkt montowania leży we wspólnej grupie propagacji.

## Rozwiązywanie problemów

Sprawdź `/data/adb/bindhosts/proxy.log`:

| Wiersz | Znaczenie |
|---|---|
| `loaded N system roots` | Musi być różne od zera, inaczej żądania do serwera zawiodą |
| `signed leaf for <domena>` | Wystawiono certyfikat dla tej domeny |
| `drop <domena> (not in proxy rules)` | Zablokowana domena dotarła do proxy |
| `daemon exited ... (fail=x/10)` | Demon ciągle pada; po 10 krótkich startach proxy wyłącza się samo |

Jeśli proxy jest włączone, ale żądania nie są przechwytywane, sprawdź, czy domena ma
wiersz `127.0.0.1` w `proxy/custom.txt`.
