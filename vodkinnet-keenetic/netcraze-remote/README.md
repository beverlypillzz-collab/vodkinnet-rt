# netcraze-remote

Удалённый доступ к Keenetic/KNDMS-роутерам (Netcraze GIGA и клоны) через
свой VPS — реверс-туннель, без проброса портов, работает даже за CGNAT.

Часть семьи `vodkinnet-rt` — сосед `vodkinnet-owrt-remote` (тот же
принцип для OpenWrt-флота) на одном VPS `panel-vodkinnet`.

## Архитектура

```
Keenetic/KNDMS (за CGNAT)                 VPS
  Entware: /opt/sbin/netcraze-remote         netcraze-remote-hub (Python)
  xray (reverse VLESS, admin+ssh каналы) ←→  netcraze-remote-xray (Xray)
  heartbeat-loop (self-heal xray)            nginx → панель Hub
  netcraze-remote-watchdog (cron)
```

- **Модель доступа**: фиксированные admin (веб-морда NDMS, опционально)
  + ssh каналы на роутер. Не произвольный список сервисов.
- **Reverse-tag** детерминирован (`reverse-{router_id}` /
  `reverse-{router_id}-ssh`), не хранится отдельной колонкой БД.
- **Rollback после обновления агента**: `heartbeat-loop` сам проверяет
  живость туннеля после апдейта и откатывает бинарник на `.bak`, если
  туннель не поднялся за `ROLLBACK_GRACE_SECONDS` (по умолчанию 30с).
  Плюс независимый `netcraze-remote-watchdog` на cron — откатывает,
  даже если сам агент настолько сломан, что не может себя спасти.
- **entry_port/ssh_entry_port** независимо опциональны — можно
  зарегистрировать роутер только по SSH, без веб-морды NDMS.

## Установка панели (VPS)

```sh
curl -fsSL "https://raw.githubusercontent.com/beverlypillzz-collab/vodkinnet-rt/main/vodkinnet-keenetic/netcraze-remote/vps/install-vps.sh?v=$(date +%s)" | sudo sh
```

Ставит Hub + Xray от отдельного системного пользователя (не root),
включает HTTPS автоматически, печатает URL/логин/пароль один раз в конце.

## Установка / обновление агента (роутер)

Один и тот же скрипт ставит агент с нуля и обновляет уже развёрнутый —
сам определяет, что перед ним, по наличию текущего `netcraze-remote`.
Сначала должен быть настроен Entware (см. `netcraze_vpn_setup_summary.md`
в базе знаний).

```sh
curl -fsSL "https://raw.githubusercontent.com/beverlypillzz-collab/vodkinnet-rt/main/vodkinnet-keenetic/netcraze-remote/install.sh?v=$(date +%s)" | sh
```

При обновлении: проверяет синтаксис (`sh -n`) до установки, бэкапит
агент и init-скрипт (`.bak`), ставит атомарно (`mv`), настраивает
`netcraze-remote-watchdog` на cron. `/opt/etc/netcraze-remote/netcraze-remote.conf`
не трогается.

Точечное обновление одного файла и ручной rollback:

```sh
netcraze-remote update /path/to/new/netcraze-remote
netcraze-remote rollback
netcraze-remote tunnel-check
```

## Удаление

```sh
curl -fsSL "https://raw.githubusercontent.com/beverlypillzz-collab/vodkinnet-rt/main/vodkinnet-keenetic/netcraze-remote/uninstall.sh?v=$(date +%s)" | sh
```

Останавливает агент, убирает watchdog из cron, удаляет бинарь/init-скрипт/
`.bak`/лог/маркер. Конфиг с секретами оставляет — `PURGE=1 sh uninstall.sh`
удалит и его.

VPS: `.../vps/uninstall-vps.sh` (тот же принцип, `PURGE=1` для полной очистки).

## Шпаргалка команд

| Где | Команда | Что делает |
|---|---|---|
| Keenetic | `netcraze-remote status` | статус агента |
| Keenetic | `netcraze-remote doctor` | диагностика (entware/xray/heartbeat) |
| Keenetic | `netcraze-remote pull-config` | перетянуть конфиг с Hub по `HUB_TOKEN` |
| Keenetic | `netcraze-remote update /path` | обновить агент, бэкап + авто-rollback |
| Keenetic | `netcraze-remote rollback` | немедленный ручной откат на `.bak` |
| Keenetic | `netcraze-remote tunnel-check` | реальная проверка ESTABLISHED-туннеля |
| Keenetic | `/opt/etc/init.d/S99netcraze-remote start\|stop\|restart` | управление сервисом |
| Keenetic | `cat /opt/var/log/netcraze-remote-rollback.log` | история автооткатов |
| Keenetic | `grep netcraze-remote-watchdog /opt/etc/crontabs/root` | проверка cron-записи watchdog |
| VPS | `systemctl status netcraze-remote-hub` | статус панели |
| VPS | `systemctl restart netcraze-remote-xray` | рестарт реверс-Xray (после смены списка роутеров) |
| Панель | "Обновить Xray CFG" → "Рестарт Xray VPS" | применить изменения списка роутеров (не автоматически) |

## Дальше: регистрация роутера в Hub

1. В панели Hub → "Добавить роутер": id, название, роль, VPS-хост,
   entry_port (обязательное поле формы, но это формальность — подойдёт
   любой свободный порт, даже если веб-морды NDMS на устройстве нет и
   пользоваться ей не будешь).
2. Скопируй блок конфига целиком (кнопка "Копировать") и вставь в
   `/opt/etc/netcraze-remote/netcraze-remote.conf` на Keenetic.
3. **Требует внимания — `SSH_PORT`.** Если Entware слушает SSH не на
   дефолтном порту (см. список слушающих портов, который показал
   `install.sh`) — поправь `SSH_PORT` прямо в этом файле на реальный.
   В панели ничего трогать не нужно: агент сам репортит
   `admin_host`/`admin_port`/`ssh_host`/`ssh_port` в каждом heartbeat,
   Hub подхватывает актуальные значения автоматически.
4. `/opt/etc/init.d/S99netcraze-remote start`
5. `netcraze-remote doctor`

Если веб-морды NDMS физически нет — `ADMIN_HOST`/`ADMIN_PORT` в
конфиге всё равно будут проставлены, просто не используй этот канал.

## Changelog

### 2026-08-23 — rollback/watchdog-механизм, порт из owrt-remote

Полный перенос механизма из `vodkinnet-owrt-remote` (см. его changelog),
адаптированный под Entware. По пути найден и исправлен живой баг: `stop`/
`restart` могли быть убиты `SIGHUP` на середине последовательности, если
команда выполнялась через сам туннель (тот же приём `trap '' HUP`, что
уже использовался для heartbeat-процесса). Проверено вживую на канарейке
(Netcraze GIGA): реальный сломанный апдейт → туннель упал → `heartbeat-loop`
сам обнаружил и откатил.

### 2026-07-31 — секретный путь в URL панели

`install-vps.sh` генерирует случайный 16-символьный сегмент пути при
установке, голый `/` отдаёт 404 (защита от сканеров).

### Начало проекта — перенос owrt-remote-hub.py

`netcraze-remote-hub.py` — точный перенос `owrt-remote-hub.py` (дашборд,
метрики, SSH-терминал в браузере, авторизация) с заменой ОС-специфичного
места — хранения конфига (`uci` → обычный shell `KEY="value"` файл).
Reverse-tag mismatch баг (был у owrt-remote) исправлен сразу здесь —
tag вычисляется детерминированно на обеих сторонах, не хранится в БД.
