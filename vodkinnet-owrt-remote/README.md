# owrt-remote

Удалённый доступ к OpenWrt-роутерам (Cudy и т.п.) через свой VPS —
реверс-туннель, без проброса портов, работает даже за CGNAT.

Часть семьи `vodkinnet-rt` — сосед `vodkinnet-keenetic/netcraze-remote`
(тот же принцип для Keenetic/Entware-флота) на одном VPS `panel-vodkinnet`.

## Архитектура

```
OpenWrt (за CGNAT)                        VPS
  procd: xray + heartbeat-loop инстансы      owrt-remote-hub (Python)
  xray (reverse VLESS, admin+ssh каналы) ←→  owrt-remote-xray (Xray)
  локальная LuCI-панель (Службы → OpenWrt    nginx → панель Hub
  Remote)
  owrt-remote-watchdog (cron)
```

- **Модель доступа**: фиксированные admin (LuCI веб-морда) + ssh каналы
  на роутер. Не произвольный список сервисов.
- **Reverse-tag** детерминирован (`reverse-{router_id}` /
  `reverse-{router_id}-ssh`), не хранится отдельной колонкой БД.
- **Rollback после обновления агента**: `heartbeat-loop` (под `procd`,
  с автоматическим respawn) сам проверяет живость туннеля после апдейта
  и откатывает бинарник на `.bak`, если туннель не поднялся за
  `rollback_grace_seconds` (uci, по умолчанию 30с). Плюс независимый
  `owrt-remote-watchdog` на cron — откатывает, даже если сам агент
  настолько сломан, что не может себя спасти.
- Локальная LuCI-панель на самом роутере — то, чего нет у Keenetic-версии
  (там нет готового веб-фреймворка на устройстве).

## Установка панели (VPS)

```sh
curl -fsSL "https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-owrt-remote/vps/install-vps.sh?v=$(date +%s)" | sudo sh
```

Ставит Hub + Xray, включает HTTPS автоматически, печатает URL/логин/пароль
один раз в конце.

## Установка / обновление агента (роутер)

Один и тот же скрипт ставит агент с нуля и обновляет уже развёрнутый —
сам определяет, что перед ним, по наличию текущего `owrt-remote`.

```sh
wget -O - "https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-owrt-remote/install.sh?v=$(date +%s)" | sh
```

При обновлении: проверяет синтаксис (`sh -n`) до установки, бэкапит
агент и `init.d` (`.bak`), ставит атомарно (`mv`), настраивает
`owrt-remote-watchdog` на cron. `/etc/config/owrtremote` не трогается.

Точечное обновление одного файла и ручной rollback:

```sh
owrt-remote update /path/to/new/owrt-remote
owrt-remote rollback
owrt-remote tunnel-check
```

## Удаление

```sh
wget -O - "https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-owrt-remote/uninstall.sh?v=$(date +%s)" | sh
```

Останавливает агент, убирает watchdog из cron, удаляет бинарь/`init.d`/
`.bak`/лог/маркер, LuCI-пункт меню. Конфиг и `web.key` оставляет —
`PURGE=1 sh uninstall.sh` удалит и их.

VPS: `.../vps/uninstall-vps.sh` (тот же принцип, `PURGE=1` для полной очистки).

## Шпаргалка команд

| Где | Команда | Что делает |
|---|---|---|
| OpenWrt | `owrt-remote status` | статус агента |
| OpenWrt | `owrt-remote doctor` | диагностика (xray/heartbeat/config) |
| OpenWrt | `owrt-remote update /path` | обновить агент, бэкап + авто-rollback |
| OpenWrt | `owrt-remote rollback` | немедленный ручной откат на `.bak` |
| OpenWrt | `owrt-remote tunnel-check` | реальная проверка ESTABLISHED-туннеля |
| OpenWrt | `/etc/init.d/owrt-remote start\|stop\|restart` | управление сервисом (procd) |
| OpenWrt | `cat /etc/owrt-remote-rollback.log` | история автооткатов |
| OpenWrt | `grep owrt-remote-watchdog /etc/crontabs/root` | проверка cron-записи watchdog |
| OpenWrt | LuCI → Службы → OpenWrt Remote | локальная веб-панель на роутере |
| VPS | `systemctl status owrt-remote` | статус панели |
| VPS | `systemctl restart owrt-remote-xray` | рестарт реверс-Xray (после смены списка роутеров) |
| Панель | "Обновить Xray CFG" → "Рестарт Xray VPS" | применить изменения списка роутеров (не автоматически) |

## Дальше: регистрация роутера в Hub

1. В панели Hub → "+ Добавить роутер": id, название, роль, VPS-хост,
   ENTRY PORT (свободный порт на этом VPS, например 18080 — панель
   подскажет, если порт занят другим роутером).
2. Нажми "Обновить Xray CFG", затем "Рестарт Xray VPS" (не происходит
   автоматически при добавлении роутера — нужно руками после каждого
   изменения списка роутеров).
3. Открой "Конфиг" в карточке роутера → вставь текст целиком в
   `/etc/config/owrtremote` на этом роутере.
4. `/etc/init.d/owrt-remote restart`
5. `owrt-remote doctor`

## Changelog

### 2026-08-23 — rollback/watchdog-механизм после обновления агента

Три живых бага, найденных на канарейке (`VodkinR1_Router`) при разработке:
1. Кастомный `stop_service()` в `init.d` останавливал только `xray`,
   оставляя `heartbeat`-инстанс не перезапущенным при `restart` — убран,
   `procd` сам знает PID обоих инстансов.
2. Self-overwrite: `cp` поверх работающего скрипта — переписывал inode,
   из которого читал себя сам исполняемый процесс. Фикс — запись во
   временный файл + атомарный `mv`.
3. Архитектурная проблема — rollback-логика жила внутри обновляемого
   файла. Решение — `owrt-remote-watchdog`, полностью отдельный файл на
   cron, не исполняет код агента вообще.

`install.sh` стал одновременно install- и update-скриптом: бэкап,
`sh -n` до установки, автоустановка watchdog+cron.

### Дубль-purpose TLS-переменные (см. полную историю в git log)

`OWRT_REMOTE_TLS_CERT/KEY` управляли одновременно TLS панели и TLS
реверс-туннеля — обнуление для миграции на nginx тихо отключило TLS
туннеля для всего флота (7 роутеров). Переменные задокументированы,
добавлены защитные предупреждения.
