# bs-remnanode-openwrt

Native [Remnawave](https://docs.rw) node for OpenWrt routers. **No Docker required.**

Написан на Go — один статический бинарник, никаких зависимостей. Работает напрямую на роутере как init.d-сервис.

## Поддерживаемые роутеры

| Устройство | Архитектура | Бинарник |
|---|---|---|
| Cudy WBR3000AX, WE3000AX (MediaTek Filogic) | aarch64 | `bs-remnanode_aarch64` |
| Устаревшие ARM-роутеры | armv7 | `bs-remnanode_armv7` |
| x86 OpenWrt | x86_64 | `bs-remnanode_x86_64` |

## Быстрая установка

На роутере с OpenWrt 23.05+:

```sh
curl -fsSL https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/bs-remnanode-openwrt/scripts/install.sh | sh
```

## Ручная установка

**1. Скачать бинарник:**
```sh
curl -fsSL https://github.com/beverlypillzz-collab/Vodkinnet-RT/releases/latest/download/bs-remnanode_aarch64 -o /usr/bin/bs-remnanode
chmod +x /usr/bin/bs-remnanode
```

**2. Скачать xray-core:**
```sh
curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o /tmp/xray.zip
unzip /tmp/xray.zip xray -d /tmp/
mv /tmp/xray /usr/bin/xray
chmod +x /usr/bin/xray
```

**3. Настроить:**
```sh
uci set bs-remnanode.main.node_port='2222'
uci set bs-remnanode.main.secret_key='ВАШ_SECRET_KEY_ИЗ_ПАНЕЛИ'
uci commit bs-remnanode
```

**4. Запустить:**
```sh
/etc/init.d/bs-remnanode enable
/etc/init.d/bs-remnanode start
```

**5. Открыть порт в файрволе:**

LuCI → Network → Firewall → Traffic Rules → Add:
- Source zone: `wan`
- Destination port: `2222` (или ваш NODE_PORT)
- Action: `accept`

**6. Добавить ноду в Remnawave:**

Nodes → Management → `+` → укажи WAN IP роутера и NODE_PORT.

## Архитектура

```
Remnawave Panel
      ↓ HTTPS (NODE_PORT)
 bs-remnanode (Go, init.d)
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

## Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| `NODE_PORT` | `2222` | Порт для подключения панели |
| `SECRET_KEY` | — | Ключ авторизации из панели (обязателен) |
| `XTLS_API_PORT` | `61000` | Внутренний gRPC-порт xray |
| `XRAY_BIN` | `/usr/bin/xray` | Путь к бинарнику xray |
| `XRAY_CONFIG` | `/etc/bs-remnanode/xray.json` | Путь к конфигу xray |

## Сборка

```sh
cd bs-remnanode-openwrt
GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o bs-remnanode_aarch64 ./cmd/remnanode/
```
