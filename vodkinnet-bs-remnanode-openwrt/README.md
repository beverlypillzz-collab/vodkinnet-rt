# vodkinnet-bs-remnanode-openwrt

> Часть экосистемы [VodkinNET](https://vodkin.net) — сетевые решения на базе OpenWrt

Native [Remnawave](https://docs.remnawave.com) node для OpenWrt роутеров. **Без Docker.**

Написан на Go — один статический бинарник, никаких зависимостей. Работает напрямую на роутере как init.d-сервис с LuCI-интерфейсом.

## Поддерживаемые устройства

| Устройство | Архитектура | Бинарник |
|---|---|---|
| Cudy WBR3000AX / WE3000AX (MediaTek Filogic) | aarch64 | `bs-remnanode_aarch64` |
| Устаревшие ARM-роутеры | armv7 | `bs-remnanode_armv7` |
| x86 OpenWrt | x86_64 | `bs-remnanode_x86_64` |

## Требования

- OpenWrt 24.10 (opkg) или 25.12 (apk) — определяется автоматически
- xray-core установлен на роутере
- SECRET_KEY из панели Remnawave

## Установка

```sh
sh <(wget -O - https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-bs-remnanode-openwrt/scripts/install.sh)
```

После установки:
```sh
uci set bs-remnanode.main.secret_key='ВАШ_SECRET_KEY_ИЗ_ПАНЕЛИ'
uci commit bs-remnanode
/etc/init.d/bs-remnanode restart
```

Управление через **LuCI → Services → BS RemnaNode**.

## Архитектура

```
Remnawave Panel
      ↓ HTTPS (NODE_PORT 2222)
vodkinnet-bs-remnanode (Go, init.d)
      ↓ управляет процессом
   xray-core (бинарник)
      ↓ VPN-протоколы
   Клиент (Happ и др.)
```

## API endpoints

Реализует протокол `@remnawave/node-contract`:

| Метод | Путь | Описание |
|---|---|---|
| GET | `/api/node/health` | Проверка доступности |
| GET | `/api/node/info` | Информация о ноде |
| POST | `/api/node/start` | Запуск xray с новым конфигом |
| POST | `/api/node/stop` | Остановка xray |
| POST | `/api/node/restart` | Перезапуск xray |

Все запросы требуют заголовок `Authorization: Bearer <SECRET_KEY>`.

## UCI параметры

| Параметр | По умолчанию | Описание |
|---|---|---|
| `node_port` | `2222` | Порт для подключения панели |
| `secret_key` | — | Ключ авторизации из панели (обязателен) |
| `xray_bin` | `/usr/bin/xray` | Путь к бинарнику xray |
| `xray_config` | `/etc/bs-remnanode/xray.json` | Путь к конфигу xray |

## Связанные проекты в Vodkinnet-RT

- [`vodkinnet-adguard-openwrt`](../vodkinnet-adguard-openwrt/) — adblock podkop-safe
- [`vodkinnet-quick-extroot-openwrt.sh`](../vodkinnet-quick-extroot-openwrt.sh) — быстрая настройка extroot

---

[VodkinNET](https://vodkin.net) · [Telegram](https://t.me/BeFolaGaBot)
