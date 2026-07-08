# vodkinnet-quick-extroot-openwrt

> Часть экосистемы [VodkinNET](https://vodkin.net) — сетевые решения на базе OpenWrt

Скрипт для быстрой настройки extroot на OpenWrt — переносит overlay на внешний USB-накопитель (флешка/SSD), чтобы разгрузить внутреннюю flash-память роутера. Поддерживает как `opkg` (OpenWrt 23.x), так и `apk` (OpenWrt 24.10+/25.x).

## Требования

- Подключённый USB-накопитель (флешка, USB-SSD)
- OpenWrt с поддержкой USB (kmod-usb-storage и т.д. ставятся автоматически)
- Доступ в интернет с роутера для установки пакетов

## Установка

```sh
sh <(wget -O - https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-quick-extroot-openwrt/install.sh?$(date +%s))
```

`?$(date +%s)` добавлен, чтобы обойти кэш `raw.githubusercontent.com` (5–10 минут после пуша).

## Что делает скрипт

1. Определяет пакетный менеджер (`apk`/`opkg`) и ставит зависимости (`block-mount`, `kmod-fs-ext4`, `e2fsprogs`, `parted`, `kmod-usb-storage`).
2. Ждёт появления USB-устройства, показывает список `/dev/sd*`.
3. Просит указать диск (например `/dev/sda`) — **все данные на нём будут стёрты**.
4. Партиционирует диск (GPT) и форматирует в ext4.
5. Генерирует `/etc/config/fstab` через `block detect`, настраивает точки монтирования `extroot` и `rwm` (бэкап оригинального overlay).
6. Переносит текущие данные overlay на новый диск.
7. Проверяет конфигурацию (сверка UUID) и уходит в перезагрузку через 5 секунд.

После перезагрузки проверь:

```sh
df -h            # overlay должен показывать размер внешнего диска
block info && mount | grep overlay
```

## Важно

Скрипт запрашивает ввод (номер диска, подтверждение `yes/no`) через `/dev/tty`, поэтому нормально работает даже при запуске через `sh <(wget -O - ...)` — ввод не потеряется в пайпе.
