# Proxy kuralları

bindhosts, listelediğin alan adlarına gelen istekleri yakalayan ve URL yoluna göre
yeniden yazan veya engelleyen yerel bir TLS proxy çalıştırabilir. hosts kurallarından
bağımsız çalışır: hosts `0.0.0.0` ile neyin engelleneceğine, proxy ise neyin yerel
olarak yanıtlanacağına karar verir.

## Etkinleştirme

1. Kurallar sayfasında **Proxy** görünümüne geç.
2. Sekmenin yanındaki anahtarı aç.
3. En az bir alan adı ve bir kural ekle.
4. Action düğmesine bas.

İlk etkinleştirmede `/data/adb/bindhosts/proxy/certs/` altında yerel bir CA üretilir
ve sistem güven deposuna kurulur. Özel anahtar cihazdan çıkmaz ve modüle dahil değildir.

## Alan adı tanımlama

Proxy yalnızca kendisine bildirilen alan adları için sertifika imzalar.
`proxy/custom.txt` dosyasına bir hosts satırı ekle:

```
127.0.0.1 api.example.com
```

Bu adres sistem hosts dosyasına yazılır, böylece alan adına giden istekler internet
yerine yerel proxy'ye ulaşır. Her alan adı için bir satır; CA istediği kadarını imzalayabilir.

## Kurallar

Her satıra bir kural. `<path>` istek yoluyla karşılaştırılır; sondaki `*` önek
eşleşmesi yapar.

```
mock    <path> [body]     body ile yerel yanıt ver
patch   <path> <json>     anahtar değerlerini değiştirip ilet
forward <path>            isteği gerçek sunucuya ilet
block   <path>            bağlantıyı kapat
```

Örnek:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
patch   /api/* {"appVersion":"9.9.9"}
forward /api/*
block   /ads/*
```

`patch` yalnızca aynı adlı anahtarların değerini değiştirir, gövdenin diğer
baytları olduğu gibi kalır — alan sırası, sayı biçimi ve boşluklar korunur.
`patch` kuralı aynı zamanda iletir, aynı yol için ayrıca `forward` eklemeyin.

Kurallar dosya sırasına göre değerlendirilir, ilk eşleşen kazanır. Kuralı olmayan
yollar iletilir.

## Kural kümeleri

`proxy/sources.txt` her satıra bir URL alır. İndirilenler `proxy/cache/` altında
önbelleğe alınır ve tüm indirmeler başarısız olduğunda yeniden kullanılır, böylece
çevrimdışı bir çalıştırma son bilinen kural kümesini yine üretir.

## İndirilen kural kümeleri salt okunur

`sources.txt` dosyasından alınan kurallar ürüne birleştirilir ancak WebUI'de
düzenlenemez. Sorgu sayfası bunları `SRC` etiketiyle listeler ve silme düğmesi
sunmaz. İndirilen bir kuralı devre dışı bırakmak için URL'sini `sources.txt`
dosyasından çıkar.

Hosts görünümünde de `SRC` satırlarında düğme yok: indirilen bir kural sorgu
sayfasından kaldırılamaz. URL'sini `sources.txt` dosyasından çıkar.

## Beyaz liste ve kara liste

İkisi de `proxy/custom.txt` üzerinde birer görünümdür:

- **Beyaz liste** `forward` kurallarını listeler
- **Kara liste** `block` kurallarını listeler

Herhangi birini düzenlemek `proxy/custom.txt` dosyasını düzenler. Ayrı dosyalar değildir.

## Devre dışı bırakma

Proxy'yi kapatmak daemon'u durdurur, `127.0.0.1:443` portunu serbest bırakır ve
hosts dosyasından proxy girdilerini kaldırır. Kural dosyaları ve CA korunur, bu yüzden
tekrar açmak yapılandırma gerektirmez.

CA bir sonraki yeniden başlatmaya kadar güven deposunda kalır. Bağlama noktası
paylaşılan bir yayılım grubunda olduğu için çalışma anında çözülemez.

## Sorun giderme

`/data/adb/bindhosts/proxy.log` dosyasına bak:

| Satır | Anlamı |
|---|---|
| `loaded N system roots` | Sıfırdan farklı olmalı, aksi halde üst sunucu istekleri başarısız olur |
| `signed leaf for <alan adı>` | O alan adı için sertifika üretildi |
| `drop <alan adı> (not in proxy rules)` | Engellenen bir alan adı proxy'ye ulaştı |
| `daemon exited ... (fail=x/10)` | Daemon sürekli ölüyor; 10 kısa başlatmadan sonra proxy kendini devre dışı bırakır |

Proxy açık ama istekler yakalanmıyorsa, alan adının `proxy/custom.txt` içinde
`127.0.0.1` satırı olduğundan emin ol.
