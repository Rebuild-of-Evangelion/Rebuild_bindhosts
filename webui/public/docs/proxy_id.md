# Aturan proxy

bindhosts dapat menjalankan proxy TLS lokal yang mencegat permintaan ke domain yang
kamu daftarkan dan menulis ulang atau memblokirnya per jalur URL. Ia bekerja terpisah
dari aturan hosts: hosts menentukan apa yang diblokir dengan `0.0.0.0`, proxy
menentukan apa yang dijawab secara lokal.

## Mengaktifkan

1. Beralih ke tampilan **Proxy** di halaman aturan.
2. Nyalakan sakelar di sebelah tab.
3. Tambahkan setidaknya satu domain dan satu aturan.
4. Tekan tombol action.

Saat pertama diaktifkan, CA lokal dibuat di `/data/adb/bindhosts/proxy/certs/` dan
dipasang ke penyimpanan kepercayaan sistem. Kunci privat tidak pernah keluar dari
perangkat dan bukan bagian dari modul.

## Mendeklarasikan domain

Proxy hanya menandatangani sertifikat untuk domain yang diberitahukan. Tambahkan
baris hosts di `proxy/custom.txt`:

```
127.0.0.1 api.example.com
```

Alamat itu ditulis ke file hosts sistem, sehingga permintaan ke domain tersebut
sampai ke proxy lokal alih-alih internet. Satu baris per domain; CA bisa menandatangani
sebanyak apa pun.

## Aturan

Satu aturan per baris. `<path>` dicocokkan dengan jalur permintaan; `*` di akhir
membuatnya cocok sebagai prefiks.

```
mock    <path> [body]     jawab secara lokal dengan body
forward <path>            teruskan permintaan ke server asli
block   <path>            tutup koneksi
```

Contoh:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
forward /api/*
block   /ads/*
```

Aturan dievaluasi sesuai urutan file dan yang pertama cocok menang. Jalur tanpa
aturan akan diteruskan.

## Kumpulan aturan

`proxy/sources.txt` menerima satu URL per baris. Unduhan disimpan di `proxy/cache/`
dan dipakai ulang saat semua unduhan gagal, jadi proses offline tetap menghasilkan
kumpulan aturan terakhir.

## Whitelist dan blacklist

Keduanya adalah tampilan dari `proxy/custom.txt`:

- **Whitelist** menampilkan aturan `forward`
- **Blacklist** menampilkan aturan `block`

Mengedit salah satunya berarti mengedit `proxy/custom.txt`. Keduanya bukan file terpisah.

## Menonaktifkan

Mematikan proxy menghentikan daemon, melepas `127.0.0.1:443`, dan menghapus entri
proxy dari file hosts. File aturan dan CA tetap disimpan, jadi mengaktifkannya lagi
tidak perlu konfigurasi.

CA tetap di penyimpanan kepercayaan sampai reboot berikutnya. Tidak bisa dilepas saat
berjalan karena titik mount berada di grup propagasi bersama.

## Pemecahan masalah

Periksa `/data/adb/bindhosts/proxy.log`:

| Baris | Arti |
|---|---|
| `loaded N system roots` | Harus bukan nol, jika tidak permintaan ke server akan gagal |
| `signed leaf for <domain>` | Sertifikat diterbitkan untuk domain tersebut |
| `drop <domain> (not in proxy rules)` | Domain yang diblokir mencapai proxy |
| `daemon exited ... (fail=x/10)` | Daemon terus mati; setelah 10 kali start singkat proxy menonaktifkan dirinya |

Jika proxy aktif tetapi permintaan tidak dicegat, periksa apakah domain punya baris
`127.0.0.1` di `proxy/custom.txt`.
