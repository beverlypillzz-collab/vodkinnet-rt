# Совместимость с podkop

## Как работает podkop

podkop использует sing-box с режимом FakeIP:

```
Клиент → dnsmasq (192.168.1.1:53)
           └─→ sing-box FakeIP (127.0.0.42:53)
                  ├─ заблокированный домен → fake IP → tproxy → VPN туннель
                  └─ разрешённый домен    → upstream DNS → прямой маршрут
```

При старте podkop:
- Модифицирует `/etc/config/dhcp` (dnsmasq)
- Создаёт собственные цепочки в nftables (`podkop`, `mangle`, `mangle_output`, `proxy`)
- Добавляет маршруты для tproxy

## Где возникает конфликт

adblock в режиме **nftset** создаёт свои nftables-сеты и правила:
```
table inet fw4 {
    set adblock_v4 { ... }
    chain dstnat { ... }   # ← конфликт с цепочками podkop
}
```

Если оба пишут в nftables одновременно — порядок применения правил нарушается,
трафик уходит не туда, FakeIP перестаёт работать корректно.

## Как мы это решаем

Используем adblock в режиме **plain dnsmasq** — блокировка идёт через записи вида:
```
address=/ads.example.com/#
```

Эти записи добавляются в conf-dir dnsmasq и возвращают NXDOMAIN для рекламных доменов.
Это происходит **до** того, как запрос доходит до sing-box FakeIP — т.е. рекламные домены
просто не резолвятся, не попадая ни в VPN, ни в прямой маршрут.

```
Клиент → dnsmasq
           ├─ ads.example.com → NXDOMAIN (adblock)  ✓
           └─ blocked.ru      → sing-box FakeIP      ✓ (podkop работает штатно)
```

## Параметры и что они делают

### `adb_dns = dnsmasq`
Использует dnsmasq как единственный DNS backend. Без nftables.

### `adb_dnsvariant = dnsmasq`
Plain режим: только `address=` записи в conf-dir. Альтернативы — `nftset` и `ipset`,
оба потенциально конфликтуют с podkop.

### `adb_nftcnt = 0`
Отключает сбор статистики через nftables-счётчики. Экономит ресурсы, не трогает firewall.

### `adb_dns_report = 0`
DNS reporting делает периодические запросы для проверки блокировок. Эти запросы
идут напрямую, минуя FakeIP sing-box — могут создавать DNS-утечки и мешать
логике маршрутизации podkop.

### `adb_bootdelay = 30`
Даём 30 секунд после загрузки системы перед стартом adblock. За это время:
- dnsmasq полностью инициализируется
- podkop поднимает sing-box и патчит dnsmasq конфиг
- Только после этого adblock добавляет свои записи

Без этой задержки adblock может добавить записи в dnsmasq раньше, чем podkop
их перехватит, что приводит к рассинхронизации конфигов.

## Что не мешает

- Сами `address=` записи dnsmasq — podkop их не трогает, они живут в отдельном conf-dir
- LuCI интерфейс adblock — чисто UI, на kernel/network не влияет
- Автообновление блоклистов — делает `dnsmasq --reload`, что podkop обрабатывает штатно

## Проверка после установки

```sh
# Проверить что nftset не используется
uci get adblock.global.adb_dnsvariant
# Должно быть: dnsmasq

# Проверить что podkop жив
/etc/init.d/podkop status

# Проверить что adblock работает
/etc/init.d/adblock status

# Проверить что заблокированный домен не резолвится
nslookup ads.google.com

# Проверить что podkop маршрутизация работает
curl -s https://ifconfig.me  # должен вернуть IP VPN-сервера (если настроено)
```
