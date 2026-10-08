# Conch

Bash ve socat ile yazılmış küçük bir web framework'ü: router, controller, view, model ve JSON API. Hobi projesi.

## Gereksinimler

- **bash ≥ 4.3.** `server.sh` sürümü kontrol ediyor, daha eskisinde hata verip çıkıyor.
- **socat**
- Dosya başlarında `#!/bin/bash` var ve öyle kalacak. macOS'ta `/bin/bash` 3.2 olduğu ve SIP yüzünden değiştirilemediği için sunucu **PATH'teki yeni bash ile** başlatılır:

```sh
# macOS (MacPorts: port install bash socat)
bash server.sh            # port: .env/ortamdaki PORT, yoksa 3000
bash server.sh 8080       # başka port (PORT'un önüne geçer)
PORT=8080 bash server.sh  # aynısı, ortamdan
bash server.sh --debug    # ayrıntılı log

# Linux
./server.sh
```

`server.sh`, `bootstrap/app.sh`'yi kendisini çalıştıran bash ile (`$BASH`) başlatır. Böylece bütün zincir aynı bash sürümüyle çalışır.

## Klasör yapısı

```
server.sh                 socat'ı başlatır; locale ve ROOT bir kez burada hesaplanır
bootstrap/app.sh          her istek için çalışır: OPTIONS → /public → rota grupları
app/controllers/*.sh      controller'lar (istek sürecinde `source` edilir); alt klasör olabilir: Api/Users.sh
config/routes.sh          rota grupları: hangi prefix hangi rota dosyasını kullanır
routes/*.sh               rota tanımları (web.sh, api.sh...)
resources/views/*.html    view'lar, {{ anahtar }} yer tutucularıyla
public/                   statik dosyalar, /public/... adresinden sunulur
app/helpers.sh            log(), log_debug(); app/globals.sh ve app/helpers/*.sh'yi yükler
app/globals.sh            tepe seviye `declare -g` durumu (rota tabloları, REQUEST_FULL_STRING)
app/helpers/*.sh          request (istek okuma), response, files, url, html, router, render, json
config/database.sh        veritabanı ayarları (varsayılanlar; ortam ve `.env` üstüne yazar)
app/database/             bağlantı (connection.sh), sürücüler (drivers/), redis.sh, model.sh
app/models/*.sh           model tanımları (`model User users id name email`)
database/migrations/*.sql migrasyonlar; `bash scripts/migrate.sh` ile uygulanır
```

## Rota grupları

`config/routes.sh` hangi prefix'in hangi rota dosyasını kullandığını söyler:

```bash
route_group ''        'routes/web.sh'      # prefix yok
route_group '/api'    'routes/api.sh'
route_group '/api/v2' 'routes/apiv2.sh'    # dosyayı oluşturup satırı eklemek yeterli
```

- Dosyadaki her `route`'un yoluna grubun prefix'i eklenir: `routes/api.sh` içinde
  `route GET '/users' ...` → `/api/users`.
- Bir dosya yalnızca istek yolu o prefix'le başlıyorsa yüklenir: `/about` isteği
  `routes/api.sh`'yi hiç okumaz.
- Sıra önemsiz, **en uzun prefix önce** denenir: `/api/v2/users` önce `apiv2.sh`'de, sonra
  `api.sh`'de, en son `web.sh`'de aranır.
- `{isim}` içeren bir prefix her istekte yüklenir.
- Listede olmayan bir dosya 500 verir ve loglanır.

## Rota tanımlamak

`routes/web.sh`:

```bash
route GET  '/'             'Home' 'index'
route GET  '/hello/{name}' 'Home' 'hello'
route POST '/users'        'Users' 'store'
```

- Rotalar yazıldıkları sırayla denenir, ilk eşleşen kazanır.
- `{isim}` tek bir yol parçasıyla eşleşir, değeri `ROUTE_PARAMETERS[isim]` içinde gelir.
- Sondaki `/` önemsizdir.
- `GET` rotası `HEAD` isteklerine de cevap verir.
- Yol eşleşip metot uymazsa **405** döner (`Allow` başlığıyla), hiçbir rota eşleşmezse **404**.
- Yalnızca burada tanımlı adreslere erişilebilir.

## Controller

`app/controllers/Home.sh`:

```bash
function hello()
{
	local name
	name=$(html_escape "${ROUTE_PARAMETERS[name]}")
	render 'hello' 'title=Merhaba' "name=$name"
}
```

- Controller fonksiyonu **mutlaka bir cevap göndermeli** (`render`, `send_response`, `send_file`, `send_redirect`, `send_error`). Cevap göndermeden biterse 500 döner.
- Kullanılabilecek değişkenler: `REQUEST_METHOD`, `URL_BASE`, `URL_PARAMETERS[...]` (query string), `REQUEST_HEADERS[...]` (küçük harfli anahtarlarla), `REQUEST_BODY`, `REQUEST_BODY_PARAMETERS[...]` (form verisi), `ROUTE_PARAMETERS[...]`.
- Fonksiyon adları `helpers.sh`'deki fonksiyonlarla çakışmamalı (`log`, `render`, `route` gibi).
- `init_environment` controller'da **çağrılmaz**, `bootstrap/app.sh` zaten çağırıyor.
- Controller adı klasör içerebilir: `'Api/Users'` → `app/controllers/Api/Users.sh`. Örnek: JSON dönen `/api/users` (bkz. JSON).

## View

`resources/views/hello.html`:

```html
<h1>Merhaba, {{ name }}!</h1>
```

`render 'hello' 'anahtar=değer' ...` her `{{ anahtar }}` ifadesini verilen değerle değiştirir.

- Değerler **olduğu gibi** eklenir. İstekten gelen her şeyi önce `html_escape` ile kaçışlayın.
- Eşleşmeyen `{{ ... }}` sayfada olduğu gibi kalır.
- Şablondaki `$` ve `&` karakterlerine dokunulmaz, JavaScript güvenle yazılabilir.

## Veritabanı

Sürücü `DB_CONNECTION` ile seçilir: `sqlite` (varsayılan), `mysql`, `pgsql`. Ayarlar
`config/database.sh`'deki varsayılanlardır; ortam değişkeni ya da kökteki `.env` dosyası
(bkz. `.env.example`) üstüne yazar. Redis bundan bağımsızdır (`REDIS_HOST`, `REDIS_PORT`...).

```sh
bash scripts/migrate.sh                      # database/migrations/*.sql, sırayla, bir kez
DB_CONNECTION=pgsql bash scripts/migrate.sh
```

Migrasyonda `{{ id }}` yazılan yere sürücünün otomatik artan birincil anahtarı gelir
(`INTEGER PRIMARY KEY AUTOINCREMENT` / `INT AUTO_INCREMENT PRIMARY KEY` / `SERIAL PRIMARY KEY`).

**Bağlantı:** istek başına tek istemci süreci (`sqlite3`, `mysql` veya `psql`), ilk sorguda
coproc olarak açılır ve istek bitene kadar açık kalır. Kaç sorgu olursa olsun 1 fork; sonuçlar
`read` ile okunur, hiçbir yerde `$(...)` yok. Redis'e ise istemci programı olmadan, bash'in
`/dev/tcp`'si üzerinden RESP konuşulur: sıfır fork, komut başına ~0,5 ms.

### Ham sorgu

```bash
db_quote email "${URL_PARAMETERS[email]}"        # 'kaçışlanmış değer'
db_ident column "$col"                           # "ad" / `ad`; geçersiz ad → 1
db_query "SELECT * FROM users WHERE email = $email" || send_error 500
db_row 0 user                                    # DB_ROWS[0] → local -A user
```

`db_query` sonucu `DB_COLUMNS` ve `DB_ROWS`'a yazar; hata olursa `DB_ERROR`'a yazıp loglar ve
1 döner. `set -e` altında her çağrıya `|| ...` ekleyin. NULL boş string olarak gelir.

### Model

`app/models/User.sh`:

```bash
model User users id name email      # ad, tablo, [anahtar], [fillable sütunlar...]
```

```bash
local -A user; local -a users; local record n

find User "$id" user || send_error 404
all User users
query User; where status active; where age '>' 18; or_where name LIKE 'A%'
order_by name desc; limit 10; offset 20; get users
query User; where email "$email"; first user || ...
query User; count n

for record in "${users[@]}"; do row user "$record"; echo "${user[name]}"; done

new User user; user[name]='Ayşe'; save user       # INSERT, user[id] dolar
user[name]='Ayşe T.'; save user                   # UPDATE
create User user REQUEST_BODY_PARAMETERS          # new + fill (yalnız fillable) + save
delete user
```

- Kayıt = `[_model]` anahtarı da olan bir `declare -A`; koleksiyon = `get`'in doldurduğu
  `declare -a`, her öğesi `row` ile açılan bir string.
- `where` değeri istekten gelebilir (`db_quote`'tan geçer); sütun adı asla (`db_ident` sadece
  `[A-Za-z_][A-Za-z0-9_]*` kabul eder). `where_raw` ham SQL'dir, tırnaklama size aittir.
- Değer içinde `0x1F` (unit separator) baytı olamaz: alan ayırıcısı odur.
- Model fonksiyonları `find`, `all`, `first`, `get`, `count`, `new`, `fill`, `save`, `create`,
  `delete`, `row`, `query`, `where*`, `order_by`, `limit`, `offset` adlarını kullanır;
  `find` istek sürecinde `find` komutunu gölgeler (hiç çağrılmıyor).
- Örnek: `app/controllers/Users.sh`, `/users` rotaları. Örnek salt okunurdur: kayıtlar
  `0002_seed_users.sql` migrasyonundan gelir, sitede kayıt ekleyen bir form ya da `POST` rotası yoktur.

### Redis

```bash
redis SET "user:$id" "$name"
redis GET "user:$id" && name="$REDIS_REPLY"      # tip REDIS_TYPE: status|int|bulk|nil|array
redis LRANGE liste 0 -1 && printf '%s\n' "${REDIS_ARRAY[@]}"
```

Hata cevabı (`-ERR`) veya bağlantı sorunu loglanır, 1 döner.

Ölçüm (8 Ekim 2026, sqlite + Redis): `GET /users` **~48 ms** (`GET /` 26 ms): sqlite3
fork'u ~13 ms, Redis bağlantısı ~6 ms, gerisi sorgular. mysql sürücüsü canlı sunucuya karşı
test edilmedi (ayrıştırıcı örnek çıktıyla test edildi); sqlite ve pgsql uçtan uca test edildi.

## JSON

`render`'ın API karşılığı `json`. Değerler `printf -v` ile değişkene yazılır, alt kabuk açılmaz.

```bash
find User "$id" user || json_error 404 'user not found'   # {"error":"user not found"}
json_record body user 'id:=' name email                  # {"id":7,"name":"...","email":"..."}
json "$body"                                              # 200, application/json

all User users
json_collection body users 'id:=' name email             # [{...},{...}]
json "$body"

json_object body 'ok:=true' "name=$name" 'count:=3'      # key=değer string, key:=ham JSON
json_array  list '1' '"iki"' "$body"
json_string s "$metin"                                    # tırnaklı, kaçışlanmış
json "$body" 201
```

- `col:=` sütunu ham yazar (sayı için). Boş ham değer `null` olur, veritabanından NULL gelirse.
- Sütun verilmezse kaydın tüm sütunları string olarak yazılır, sıra belirsizdir.
- `json_error KOD [mesaj]`: API rotalarında `send_error`'ın HTML sayfası yerine. Mesaj
  verilmezse durum kodunun açıklaması kullanılır.
- Örnek: `app/controllers/Api/Users.sh`.

## Statik dosyalar

`public/` içine koyulan dosyalar `/public/...` adresinden sunulur. Örnek: `<img src="/public/venise.webp">`.
ETag/304 ve Range/206 desteklenir. `public/` dışına (`../`) çıkılamaz.

## Performans kuralları

Bu makinede (Intel MacBook, macOS) **her yeni süreç ~13 ms** sürüyor. Bir isteğin süresini neredeyse tamamen açılan süreç sayısı belirler.

- Bir istek = bir bash süreci. O süreç içinde yeni süreç açmamaya çalışın.
- `$(...)`, `| grep`, `cat`, `realpath`, `envsubst` ve harici komutların her biri bir süreç demek.
- Sabit değerleri `server.sh`'de bir kez hesaplayıp export edin.
- Ölçmek için: `curl -s -o /dev/null -w '%{time_total}\n' http://localhost:3000/`
- Adım adım zamanlama için: `env PS4='+${EPOCHREALTIME} ${BASH_SOURCE##*/}:${LINENO} ' SHELLOPTS=xtrace bash bootstrap/app.sh < istek.txt`

Ölçüm (7 Ekim 2026): `GET /` **~25 ms**. Router'dan önce 90–155 ms'ydi.

## Yapılacaklar / notlar

- [x] Kullanılmayanlar silindi: `app/index.sh`, `resources/views/template.html`, `run_script`
- [x] `html_escape_to var value`: `printf -v` ile, alt kabuk açmadan
- [ ] mysql sürücüsünü canlı sunucuda test et
- [ ] Builder'a `update_all` / `delete_all`: `where` koşuluna uyan bütün satırları tek sorguda güncelle ya da sil
- [ ] İlişkiler (`has_many`, `belongs_to`)
- [ ] Layout / ortak şablon (header ve footer tekrarı olmasın)
- [ ] `favicon.ico` → `public/` + `<link rel="icon" href="/public/favicon.ico">`
- [ ] Bozuk istekler (ör. tarayıcının HTTPS ile denemesi) logu ikili veriyle dolduruyor. Log'a yazmadan önce temizlenebilir.
- [ ] HTTPS: `server.sh` içindeki `OPENSSL-LISTEN` satırları ve `certs/`
- [x] Git deposu: github.com/erkinduran/conch
- Tarayıcı `https://localhost:3000` adresine giderse logda anlamsız karakterler ve 400 görülür. Bu bir hata değil, adresi `http://` ile yazın.
