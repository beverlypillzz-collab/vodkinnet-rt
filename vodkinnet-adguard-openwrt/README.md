# vodkinnet-adguard-openwrt

> Часть экосистемы [VodkinNET](https://vodkin.net) — сетевые решения на базе OpenWrt

Установщик [adblock (dibdot)](https://github.com/dibdot/luci-app-adblock) с преднастроенным конфигом, безопасным для **podkop** (sing-box FakeIP).

## Почему не конфликтует с podkop

podkop при старте перехватывает DNS через sing-box FakeIP и модифицирует конфиг dnsmasq. Стандартная adblock с включённым `nftset` добавляет собственные правила в nftables — это создаёт конфликт с nftables-правилами podkop.

Данная конфигурация:

| Параметр | Значение | Причина |
|---|---|---|
| `adb_dns` | `dnsmasq` | plain DNS-блокировка через `address=` записи |
| `adb_dnsvariant` | `dnsmasq` | без nftset, без ipset |
| `adb_nftcnt` | `0` | не трогаем nftables |
| `adb_dns_report` | `0` | нет лишних DNS-запросов мимо FakeIP |
| `adb_bootdelay` | `30` | podkop и dnsmasq стартуют первыми |

## Требования

- OpenWrt 24.10 (opkg) или 25.12 (apk) — определяется автоматически
- RAM ≥ 128 МБ (рекомендуется 256 МБ)
- Доступ в интернет с роутера

## Установка

```sh
sh <(wget -O - https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-adguard-openwrt/install.sh)
```

Скрипт:
1. Определяет пакетный менеджер (apk на 25.12, opkg на 24.10)
2. Проверяет наличие podkop и выводит предупреждение если найден
3. Устанавливает `adblock` + `luci-app-adblock`
4. Применяет podkop-safe конфиг
5. Запускает сервис
6. Переименовывает раздел в LuCI: Adblock → VodkinNet Adguard

## Удаление

```sh
sh <(wget -O - https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-adguard-openwrt/uninstall.sh)
```

## Управление

После установки доступно через **LuCI → Services → VodkinNet Adguard**.

Из командной строки:
```sh
# Статус
/etc/init.d/adblock status

# Обновить блоклисты вручную
/etc/init.d/adblock reload

# Остановить
/etc/init.d/adblock stop
```

## Блоклисты по умолчанию

| Лист | Размер | Описание |
|---|---|---|
| `adguard` | ~L | Общая реклама
| `adguard_tracking` | ~L | Трекеры и CNAME-трекинг |
| `oisd_small` | ~50k доменов | Только самые агрессивные рекламные домены |

Дополнительные листы можно добавить через LuCI или вручную:
```sh
uci add_list adblock.global.adb_sources='hagezi_pro'
uci commit adblock
/etc/init.d/adblock reload
```

## Структура репозитория

```
vodkinnet-adguard-openwrt/
├── install.sh       # установщик
├── uninstall.sh     # деинсталлятор
├── config/
│   └── adblock      # эталонный UCI конфиг
└── docs/
    └── podkop-compatibility.md
```

## Связанные проекты в Vodkinnet-RT

- [`vodkinnet-bs-remnanode-openwrt`](../vodkinnet-bs-remnanode-openwrt/) — Remnawave Node для OpenWrt без Docker
- [`vodkinnet-quick-extroot-openwrt.sh`](../vodkinnet-quick-extroot-openwrt.sh) — быстрая настройка extroot

---

[VodkinNET](https://vodkin.net) · [Telegram](https://t.me/BeFolaGaBot)
