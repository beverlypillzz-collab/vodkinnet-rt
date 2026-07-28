#!/usr/bin/env python3
"""
netcraze-remote Hub — отдельная панель для флота Keenetic/KNDMS-роутеров.

v2: произвольный список "сервисов" на роутер вместо жёсткой пары
admin+ssh. Причина: KNDMS — не OpenWrt, и SSH-поверхностей там может быть
ДВЕ РАЗНЫЕ вещи (SSH самой NDMS, и отдельный SSH-демон, поставленный через
opkg внутри Entware) — плюс со временем может понадобиться туннель к
чему угодно ещё. Жёстко зашитые "admin_port"/"ssh_port" такого не позволяли.

Права: процесс НЕ должен работать от root (см. install-vps.sh — создаёт
отдельного системного пользователя, доступ к перезапуску Xray — через
узкое sudoers-правило на один конкретный systemctl-вызов, не через полный
root для самого Hub-процесса).
"""
import argparse
import base64
import hashlib
import html
import http.server
import json
import os
import secrets
import socketserver
import sqlite3
import subprocess
import sys
import threading
import time
import uuid as uuid_mod
from pathlib import Path
from urllib.parse import parse_qs, urlparse

APP_NAME = "netcraze-remote Hub"

STATE_DIR = Path(os.environ.get("NETCRAZE_REMOTE_STATE_DIR", "/var/lib/netcraze-remote"))
DB_PATH = Path(os.environ.get("NETCRAZE_REMOTE_DB", str(STATE_DIR / "hub.db")))
AUTH_FILE = STATE_DIR / "hub-auth.json"
SESSIONS_FILE = STATE_DIR / "hub-sessions.json"

XRAY_CONFIG_PATH = Path(os.environ.get("NETCRAZE_REMOTE_XRAY_CONFIG", "/etc/netcraze-remote/xray.json"))
XRAY_SERVICE_NAME = os.environ.get("NETCRAZE_REMOTE_XRAY_SERVICE", "netcraze-remote-xray")
# Если процесс не root — перезапуск сервиса идёт через узкое sudoers-правило
# (см. vps/install-vps.sh, vps/netcraze-remote.sudoers). SUDO_RESTART=0 —
# аварийный клапан для сред, где Hub всё же запущен от root напрямую.
USE_SUDO_FOR_RESTART = os.environ.get("NETCRAZE_REMOTE_SUDO_RESTART", "1") != "0"

BIND_HOST = os.environ.get("NETCRAZE_REMOTE_BIND", "127.0.0.1")
BIND_PORT = int(os.environ.get("NETCRAZE_REMOTE_PORT", "8099"))

DEFAULT_VLESS_PORT = int(os.environ.get("NETCRAZE_REMOTE_VLESS_PORT", "8444"))
REVERSE_TLS_CERT = os.environ.get("NETCRAZE_REMOTE_TLS_CERT", "").strip()
REVERSE_TLS_KEY = os.environ.get("NETCRAZE_REMOTE_TLS_KEY", "").strip()
REVERSE_TLS_SNI = os.environ.get("NETCRAZE_REMOTE_TLS_SNI", "").strip()

ENTRY_PORT_BASE = int(os.environ.get("NETCRAZE_REMOTE_ENTRY_BASE", "20000"))

ONLINE_AFTER_SECONDS = int(os.environ.get("NETCRAZE_REMOTE_ONLINE_AFTER", "75"))
SESSION_TTL_SECONDS = 30 * 24 * 60 * 60
PBKDF2_ITERATIONS = 240000
SESSION_COOKIE = "netcraze_remote_session"

LOGIN_MAX_ATTEMPTS = 5
LOGIN_WINDOW_SECONDS = 300
LOGIN_LOCKOUT_SECONDS = 300

SERVICE_KINDS = ("http", "ssh", "tcp")

BRAND_ORANGE = "#ff6a00"
BRAND_RED = "#e01e1e"
BRAND_BG = "#0a0603"

_sessions_lock = threading.Lock()
_login_lock = threading.Lock()
_login_attempts = {}  # ip -> {"count": n, "first_ts": t, "locked_until": t}


# --------------------------------------------------------------------------
# storage helpers
# --------------------------------------------------------------------------

def now_ts():
    return int(time.time())


def _secure_mkdir(path: Path, mode=0o700):
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, mode)
    except Exception:
        pass


def db_connect():
    _secure_mkdir(STATE_DIR)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        os.chmod(DB_PATH, 0o600)
    except Exception:
        pass
    return conn


def db_init():
    with db_connect() as conn:
        conn.execute(
            """
            create table if not exists routers (
                id text primary key,
                name text not null default '',
                token text not null,
                created_at integer not null,
                last_seen integer not null default 0,
                last_info text not null default '{}'
            )
            """
        )
        conn.execute(
            """
            create table if not exists services (
                id integer primary key autoincrement,
                router_id text not null references routers(id) on delete cascade,
                slug text not null,
                label text not null,
                kind text not null default 'tcp',
                target_host text not null default '127.0.0.1',
                target_port integer not null,
                vless_uuid text not null,
                reverse_tag text not null,
                entry_port integer not null,
                created_at integer not null,
                unique(router_id, slug)
            )
            """
        )
        conn.commit()


def load_auth():
    if not AUTH_FILE.exists():
        return None
    return json.loads(AUTH_FILE.read_text())


def save_auth(username, password):
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ITERATIONS)
    _secure_mkdir(STATE_DIR)
    AUTH_FILE.write_text(json.dumps({
        "username": username,
        "salt": base64.b64encode(salt).decode(),
        "hash": base64.b64encode(digest).decode(),
        "iterations": PBKDF2_ITERATIONS,
        "changed_at": now_ts(),
    }))
    os.chmod(AUTH_FILE, 0o600)
    # VodkinNET: смена пароля обязана убивать все старые сессии — иначе
    # украденная cookie переживает смену пароля админом сколько угодно.
    save_sessions({})


def verify_password(username, password):
    auth = load_auth()
    if not auth or auth.get("username") != username:
        return False
    salt = base64.b64decode(auth["salt"])
    expected = base64.b64decode(auth["hash"])
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, auth.get("iterations", PBKDF2_ITERATIONS))
    return secrets.compare_digest(digest, expected)


def load_sessions():
    if not SESSIONS_FILE.exists():
        return {}
    try:
        return json.loads(SESSIONS_FILE.read_text())
    except Exception:
        return {}


def save_sessions(sessions):
    _secure_mkdir(STATE_DIR)
    SESSIONS_FILE.write_text(json.dumps(sessions))
    os.chmod(SESSIONS_FILE, 0o600)


def create_session(username):
    with _sessions_lock:
        sessions = load_sessions()
        token = secrets.token_hex(32)
        sessions[token] = {
            "username": username,
            "created": now_ts(),
            "expires": now_ts() + SESSION_TTL_SECONDS,
            "csrf": secrets.token_hex(24),
        }
        save_sessions(sessions)
        return token


def check_session(token):
    if not token:
        return None
    with _sessions_lock:
        sessions = load_sessions()
        entry = sessions.get(token)
        if not entry:
            return None
        if entry["expires"] < now_ts():
            sessions.pop(token, None)
            save_sessions(sessions)
            return None
        return entry


# --- rate limiting on /login (простая in-memory защита от брутфорса) ------

def login_rate_check(ip):
    """Возвращает None если можно пробовать логиниться, иначе — секунды до разблокировки."""
    with _login_lock:
        entry = _login_attempts.get(ip)
        if not entry:
            return None
        if entry.get("locked_until", 0) > now_ts():
            return entry["locked_until"] - now_ts()
        if now_ts() - entry.get("first_ts", 0) > LOGIN_WINDOW_SECONDS:
            _login_attempts.pop(ip, None)
            return None
        return None


def login_rate_fail(ip):
    with _login_lock:
        entry = _login_attempts.get(ip)
        if not entry or now_ts() - entry.get("first_ts", 0) > LOGIN_WINDOW_SECONDS:
            entry = {"count": 0, "first_ts": now_ts(), "locked_until": 0}
        entry["count"] += 1
        if entry["count"] >= LOGIN_MAX_ATTEMPTS:
            entry["locked_until"] = now_ts() + LOGIN_LOCKOUT_SECONDS
        _login_attempts[ip] = entry


def login_rate_reset(ip):
    with _login_lock:
        _login_attempts.pop(ip, None)


# --------------------------------------------------------------------------
# text sanitizing helpers (defense in depth: значения идут и в shell-конфиг
# на роутере, и в HTML/JSON — санитизируем один раз в общем месте)
# --------------------------------------------------------------------------

def shq(value):
    """Безопасно для вставки внутрь двойных кавычек в shell key="value" файле."""
    return str(value).replace("\\", "").replace("\"", "").replace("`", "").replace("$", "").replace("\r", "").replace("\n", " ")


def clean_id(raw, maxlen=48):
    ascii_raw = raw.strip().lower().encode("ascii", "ignore").decode("ascii")
    cleaned = "".join(c if c.isalnum() or c in "-_" else "-" for c in ascii_raw)
    cleaned = "-".join(filter(None, cleaned.split("-")))
    return cleaned[:maxlen]


# --------------------------------------------------------------------------
# xray config generation (server / "portal" side)
# --------------------------------------------------------------------------

def reverse_stream_settings():
    if REVERSE_TLS_CERT and REVERSE_TLS_KEY:
        return {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
                "minVersion": "1.2",
                "alpn": ["h2", "http/1.1"],
                "certificates": [{"certificateFile": REVERSE_TLS_CERT, "keyFile": REVERSE_TLS_KEY}],
            },
        }
    return {"network": "tcp", "security": "none"}


def make_server_xray_config(all_services):
    """all_services: список sqlite3.Row из таблицы services (все роутеры сразу)."""
    clients = []
    inbounds = [
        {
            "tag": "netcraze-remote-vless",
            "listen": "0.0.0.0",
            "port": DEFAULT_VLESS_PORT,
            "protocol": "vless",
            "settings": {"clients": clients, "decryption": "none"},
            "streamSettings": reverse_stream_settings(),
        }
    ]
    rules = []

    for svc in all_services:
        entry_tag = f"entry-{svc['router_id']}-{svc['slug']}"

        clients.append({
            "id": svc["vless_uuid"],
            "email": f"{svc['router_id']}-{svc['slug']}@netcraze-remote",
            "reverse": {"tag": svc["reverse_tag"]},
        })
        inbounds.append({
            "tag": entry_tag,
            "listen": "127.0.0.1",
            "port": svc["entry_port"],
            "protocol": "tunnel",
            "settings": {
                "allowedNetwork": "tcp",
                "rewriteAddress": svc["target_host"] or "127.0.0.1",
                "rewritePort": svc["target_port"],
            },
        })
        rules.append({"type": "field", "inboundTag": [entry_tag], "outboundTag": svc["reverse_tag"]})

    return {
        "log": {"loglevel": "warning"},
        "inbounds": inbounds,
        "outbounds": [{"tag": "direct", "protocol": "freedom"}],
        "routing": {"rules": rules},
        "remarks": "netcraze-remote Hub server config",
    }


def regenerate_xray_config_and_reload():
    with db_connect() as conn:
        services = conn.execute("select * from services").fetchall()
    config = make_server_xray_config(services)
    XRAY_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(XRAY_CONFIG_PATH.parent, 0o750)
    except Exception:
        pass
    XRAY_CONFIG_PATH.write_text(json.dumps(config, indent=2))
    os.chmod(XRAY_CONFIG_PATH, 0o600)

    cmd = ["systemctl", "restart", XRAY_SERVICE_NAME]
    if USE_SUDO_FOR_RESTART:
        cmd = ["sudo", "-n"] + cmd
    try:
        result = subprocess.run(cmd, check=False, timeout=15, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"[warn] {' '.join(cmd)} -> rc={result.returncode}: {result.stderr.strip()}", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        print(f"[warn] could not restart {XRAY_SERVICE_NAME}: {exc}", file=sys.stderr)


# --------------------------------------------------------------------------
# router / service CRUD
# --------------------------------------------------------------------------

def next_free_entry_port(conn):
    used = {row[0] for row in conn.execute("select entry_port from services").fetchall()}
    port = ENTRY_PORT_BASE
    while port in used:
        port += 1
    return port


DEFAULT_SERVICES = (
    # slug, label, kind, target_port
    ("ndms-admin", "NDMS веб-морда", "http", 80),
    ("ssh-ndms", "SSH (NDMS)", "ssh", 22),
)


def create_service(conn, router_id, slug, label, kind, target_host, target_port):
    slug = clean_id(slug, maxlen=32) or f"svc-{secrets.token_hex(3)}"
    n = 1
    base_slug = slug
    while conn.execute("select 1 from services where router_id=? and slug=?", (router_id, slug)).fetchone():
        n += 1
        slug = f"{base_slug}-{n}"

    entry_port = next_free_entry_port(conn)
    vless_uuid = str(uuid_mod.uuid4())
    reverse_tag = f"reverse-{router_id}-{slug}"

    conn.execute(
        """
        insert into services (
            router_id, slug, label, kind, target_host, target_port,
            vless_uuid, reverse_tag, entry_port, created_at
        ) values (?,?,?,?,?,?,?,?,?,?)
        """,
        (router_id, slug, label[:80] or slug, kind if kind in SERVICE_KINDS else "tcp",
         target_host or "127.0.0.1", int(target_port), vless_uuid, reverse_tag, entry_port, now_ts()),
    )
    return slug


def create_router(name):
    router_id_base = clean_id(name) or f"router-{secrets.token_hex(3)}"
    with db_connect() as conn:
        router_id = router_id_base
        n = 1
        while conn.execute("select 1 from routers where id=?", (router_id,)).fetchone():
            n += 1
            router_id = f"{router_id_base}-{n}"

        token = secrets.token_hex(24)
        conn.execute(
            "insert into routers (id, name, token, created_at, last_seen, last_info) values (?,?,?,?,0,'{}')",
            (router_id, name[:120], token, now_ts()),
        )
        for slug, label, kind, port in DEFAULT_SERVICES:
            create_service(conn, router_id, slug, label, kind, "127.0.0.1", port)
        conn.commit()
    regenerate_xray_config_and_reload()
    return router_id


def add_service_to_router(router_id, slug, label, kind, target_host, target_port):
    with db_connect() as conn:
        if not conn.execute("select 1 from routers where id=?", (router_id,)).fetchone():
            raise KeyError(router_id)
        create_service(conn, router_id, slug, label, kind, target_host, target_port)
        conn.commit()
    regenerate_xray_config_and_reload()


def delete_service(router_id, service_id):
    with db_connect() as conn:
        conn.execute("delete from services where id=? and router_id=?", (service_id, router_id))
        conn.commit()
    regenerate_xray_config_and_reload()


def rotate_service_secret(router_id, service_id):
    with db_connect() as conn:
        new_uuid = str(uuid_mod.uuid4())
        conn.execute(
            "update services set vless_uuid=? where id=? and router_id=?",
            (new_uuid, service_id, router_id),
        )
        conn.commit()
    regenerate_xray_config_and_reload()


def rotate_router_token(router_id):
    """Меняет только HUB_TOKEN (auth к heartbeat/render-client API) — VLESS
    UUID'ы сервисов не трогает, поэтому реверс-туннель НЕ рвётся, рестарт
    Xray не нужен. Полезно, если сам токен где-то засветился (лог, чат)."""
    new_token = secrets.token_hex(24)
    with db_connect() as conn:
        conn.execute("update routers set token=? where id=?", (new_token, router_id))
        conn.commit()
    return new_token


def delete_router(router_id):
    with db_connect() as conn:
        conn.execute("delete from routers where id=?", (router_id,))  # cascade удалит services
        conn.commit()
    regenerate_xray_config_and_reload()


def get_router_by_token(token):
    with db_connect() as conn:
        return conn.execute("select * from routers where token=?", (token,)).fetchone()


def get_router(router_id):
    with db_connect() as conn:
        return conn.execute("select * from routers where id=?", (router_id,)).fetchone()


def get_services(router_id):
    # ВАЖНО: created_at — секундная точность, у сервисов, созданных в одной
    # транзакции (дефолтные ndms-admin+ssh-ndms при create_router), метки
    # совпадают, и сортировка только по ней даёт недетерминированный
    # порядок между запросами. id — монотонный autoincrement, добавка
    # гарантирует порядок именно создания.
    with db_connect() as conn:
        return conn.execute(
            "select * from services where router_id=? order by created_at asc, id asc", (router_id,)
        ).fetchall()


def list_routers():
    with db_connect() as conn:
        return conn.execute("select * from routers order by created_at desc").fetchall()


def touch_heartbeat(router_id, info):
    with db_connect() as conn:
        conn.execute(
            "update routers set last_seen=?, last_info=? where id=?",
            (now_ts(), json.dumps(info)[:4000], router_id),
        )
        conn.commit()


# --------------------------------------------------------------------------
# render-client payload / conf block
# --------------------------------------------------------------------------

def public_host():
    return os.environ.get("NETCRAZE_REMOTE_PUBLIC_HOST", REVERSE_TLS_SNI or "REPLACE_ME")


def router_client_payload(row, services):
    tls_sni_for_client = REVERSE_TLS_SNI if (REVERSE_TLS_CERT and REVERSE_TLS_KEY) else ""
    return {
        "id": row["id"],
        "vps_host": public_host(),
        "vps_port": DEFAULT_VLESS_PORT,
        "vless_encryption": "none",
        "vless_flow": "",
        "tls_sni": tls_sni_for_client,
        "services": [
            {
                "slug": s["slug"],
                "label": s["label"],
                "kind": s["kind"],
                "host": s["target_host"],
                "port": s["target_port"],
                "uuid": s["vless_uuid"],
                "tag": s["reverse_tag"],
            }
            for s in services
        ],
    }


def router_conf_text(row, services):
    """Полный текст конфиг-файла для агента. Используется и веб-страницей
    (в <pre>, через html.escape), и /api/render-client-conf (как есть,
    text/plain) — единственный источник правды для формата конфига."""
    # ВАЖНО: TLS_SNI отдаём клиенту, только если TLS реально включён на
    # сервере (есть и cert, и key) — иначе клиент попробует security:tls,
    # а сервер откроет security:none, рукопожатие несовместимо и туннель
    # просто не поднимется без какой-либо понятной ошибки в логах агента.
    tls_sni_for_client = REVERSE_TLS_SNI if (REVERSE_TLS_CERT and REVERSE_TLS_KEY) else ""
    lines = [
        f'ROUTER_ID="{shq(row["id"])}"',
        f'ROUTER_NAME="{shq(row["name"] or row["id"])}"',
        'ENABLED="1"',
        f'HUB_URL="https://{shq(public_host())}"',
        f'HUB_TOKEN="{shq(row["token"])}"',
        f'VPS_HOST="{shq(public_host())}"',
        f'VPS_PORT="{DEFAULT_VLESS_PORT}"',
        'VLESS_ENCRYPTION="none"',
        'VLESS_FLOW=""',
        f'TLS_SNI="{shq(tls_sni_for_client)}"',
        'XRAY_BIN=""',
        'XRAY_CONFIG="/opt/etc/netcraze-remote/xray-client.json"',
        'HEARTBEAT_INTERVAL="30"',
        "",
        "# --- сервисы (каждый - отдельный реверс-туннель) ---",
        f'SERVICE_COUNT="{len(services)}"',
    ]
    for i, s in enumerate(services, start=1):
        lines += [
            f'SERVICE_{i}_SLUG="{shq(s["slug"])}"',
            f'SERVICE_{i}_LABEL="{shq(s["label"])}"',
            f'SERVICE_{i}_KIND="{shq(s["kind"])}"',
            f'SERVICE_{i}_HOST="{shq(s["target_host"])}"',
            f'SERVICE_{i}_PORT="{s["target_port"]}"',
            f'SERVICE_{i}_UUID="{shq(s["vless_uuid"])}"',
            f'SERVICE_{i}_TAG="{shq(s["reverse_tag"])}"',
        ]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# HTML
# --------------------------------------------------------------------------

PAGE_CSS = f"""
<style>
  :root {{ --bg:{BRAND_BG}; --accent:{BRAND_ORANGE}; --accent2:{BRAND_RED}; }}
  * {{ box-sizing: border-box; }}
  body {{ background:var(--bg); color:#f2ece4; font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin:0; padding:24px; }}
  a {{ color:var(--accent); }}
  h1 {{ font-size:20px; margin:0 0 18px; }}
  h3 {{ font-size:15px; }}
  .card {{ background:#15100c; border:1px solid #2a221a; border-radius:10px; padding:16px 18px; margin-bottom:14px; }}
  .row {{ display:flex; align-items:center; justify-content:space-between; gap:12px; flex-wrap:wrap; }}
  .dot {{ width:10px; height:10px; border-radius:50%; display:inline-block; margin-right:8px; }}
  .on {{ background:#22c55e; }}
  .off {{ background:#6b7280; }}
  .btn {{ background:var(--accent); color:#150c05; border:none; padding:8px 14px; border-radius:6px; cursor:pointer; font-weight:600; text-decoration:none; display:inline-block; font-size:13px; }}
  .btn.danger {{ background:var(--accent2); color:#fff; }}
  .btn.ghost {{ background:transparent; border:1px solid #3a2f22; color:#f2ece4; }}
  .btn.small {{ padding:4px 9px; font-size:12px; }}
  input[type=text], input[type=password], select {{ background:#0f0b08; border:1px solid #3a2f22; color:#fff; padding:8px 10px; border-radius:6px; }}
  pre {{ background:#0f0b08; border:1px solid #3a2f22; border-radius:8px; padding:12px; overflow-x:auto; font-size:12.5px; position:relative; }}
  .copybtn {{ position:absolute; top:8px; right:8px; }}
  form {{ margin:0; }}
  .muted {{ color:#a89a86; font-size:13px; }}
  code {{ color:var(--accent); }}
  .kindtag {{ font-size:11px; padding:2px 6px; border-radius:4px; background:#241a10; color:#e0a26a; margin-left:6px; }}
  .svc-grid {{ display:grid; gap:10px; }}
</style>
<script>
function ncrCopy(id) {{
  var el = document.getElementById(id);
  if (!el) return;
  navigator.clipboard.writeText(el.innerText).then(function() {{
    var btn = document.getElementById('copy-' + id);
    if (btn) {{ var old = btn.innerText; btn.innerText = 'Скопировано'; setTimeout(function(){{ btn.innerText = old; }}, 1500); }}
  }});
}}
</script>
"""

SECURITY_HEADERS = {
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'",
    "Cache-Control": "no-store",
}


def page(title, body, back=True):
    back_link = '<p><a href="/">&larr; к списку роутеров</a></p>' if back else ""
    return f"""<!doctype html><html><head><meta charset="utf-8">
<title>{html.escape(title)} — netcraze-remote</title>{PAGE_CSS}</head>
<body><h1>netcraze-remote — {html.escape(title)}</h1>{back_link}{body}</body></html>"""


def login_page(error=""):
    err_html = f'<p style="color:{BRAND_RED}">{html.escape(error)}</p>' if error else ""
    body = f"""
    <div class="card" style="max-width:360px">
      {err_html}
      <form method="post" action="/login">
        <p><input type="text" name="username" placeholder="логин" required></p>
        <p><input type="password" name="password" placeholder="пароль" required></p>
        <button class="btn" type="submit">Войти</button>
      </form>
    </div>
    """
    return page("вход", body, back=False)


def dashboard_page(rows, csrf):
    cards = []
    for row in rows:
        online = (now_ts() - row["last_seen"]) < ONLINE_AFTER_SECONDS if row["last_seen"] else False
        dot = "on" if online else "off"
        status_text = "online" if online else ("никогда не выходил на связь" if not row["last_seen"] else "offline")
        cards.append(f"""
        <div class="card">
          <div class="row">
            <div><span class="dot {dot}"></span><b>{html.escape(row["name"] or row["id"])}</b>
              <span class="muted">({html.escape(row["id"])}) — {status_text}</span></div>
            <div><a class="btn" href="/routers/{html.escape(row["id"])}">Открыть</a></div>
          </div>
        </div>
        """)
    cards_html = "\n".join(cards) if cards else '<p class="muted">Пока нет роутеров.</p>'

    body = f"""
    <div class="card">
      <form method="post" action="/routers">
        <input type="hidden" name="csrf" value="{html.escape(csrf)}">
        <div class="row">
          <input type="text" name="name" placeholder="Название роутера, например: Netcraze GIGA (офис)" required style="flex:1; min-width:240px">
          <button class="btn" type="submit">+ Добавить роутер</button>
        </div>
      </form>
    </div>
    {cards_html}
    <p class="muted"><a href="/logout">Выйти</a></p>
    """
    return page("роутеры", body, back=False)


def service_commands_html(row_id, svc, ssh_hint_user, ssh_hint_port, vps_host):
    local_port = 9000 + (svc["entry_port"] - ENTRY_PORT_BASE) % 900
    fwd = f"ssh -L {local_port}:127.0.0.1:{svc['entry_port']} {ssh_hint_user}@{vps_host} -p {ssh_hint_port}"
    if svc["kind"] == "http":
        follow = f"# затем открой в браузере:\nhttp://127.0.0.1:{local_port}"
    elif svc["kind"] == "ssh":
        follow = (f"# в другом окне после проброса:\nssh -p {local_port} root@127.0.0.1\n"
                  f"# или сразу с VPS, без проброса:\nssh -p {svc['entry_port']} root@127.0.0.1")
    else:
        follow = f"# подключай свой инструмент к:\n127.0.0.1:{local_port}"
    text = f"{fwd}\n{follow}"
    block_id = f"svc-{svc['id']}"
    return f"""
    <div class="card">
      <div class="row">
        <h3 style="margin:0">{html.escape(svc['label'])}<span class="kindtag">{html.escape(svc['kind'])}</span></h3>
        <div>
          <form method="post" action="/routers/{html.escape(row_id)}/services/{svc['id']}/rotate" style="display:inline" onsubmit="return confirm('Перевыпустить секрет для {html.escape(svc['label'])}? Понадобится обновить конфиг на роутере.');">
            <input type="hidden" name="csrf" value="{{csrf}}">
            <button class="btn ghost small" type="submit">Перевыпустить секрет</button>
          </form>
          <form method="post" action="/routers/{html.escape(row_id)}/services/{svc['id']}/delete" style="display:inline" onsubmit="return confirm('Удалить сервис {html.escape(svc['label'])}?');">
            <input type="hidden" name="csrf" value="{{csrf}}">
            <button class="btn danger small" type="submit">Удалить</button>
          </form>
        </div>
      </div>
      <p class="muted">цель на роутере: {html.escape(svc['target_host'])}:{svc['target_port']}</p>
      <pre id="{block_id}">{html.escape(text)}</pre>
      <button class="btn small copybtn" id="copy-{block_id}" onclick="ncrCopy('{block_id}')">Копировать</button>
    </div>
    """


def add_service_form_html(row_id, csrf):
    options = "".join(f'<option value="{k}">{k}</option>' for k in SERVICE_KINDS)
    return f"""
    <div class="card">
      <h3 style="margin-top:0">+ Добавить сервис</h3>
      <p class="muted">Например: второй SSH, если внутри Entware стоит свой sshd/dropbear
        отдельно от SSH самой NDMS — просто другой порт, свой независимый туннель.</p>
      <form method="post" action="/routers/{html.escape(row_id)}/services">
        <input type="hidden" name="csrf" value="{html.escape(csrf)}">
        <div class="row" style="gap:8px">
          <input type="text" name="label" placeholder="Название, напр. SSH (Entware)" required style="flex:2; min-width:180px">
          <input type="text" name="host" placeholder="127.0.0.1" value="127.0.0.1" style="flex:1; min-width:110px">
          <input type="text" name="port" placeholder="порт, напр. 2222" required style="flex:1; min-width:90px">
          <select name="kind">{options}</select>
          <button class="btn" type="submit">Добавить</button>
        </div>
      </form>
    </div>
    """


def router_detail_page(row, services, vps_public_host, ssh_hint_user, ssh_hint_port, csrf):
    online = (now_ts() - row["last_seen"]) < ONLINE_AFTER_SECONDS if row["last_seen"] else False
    dot = "on" if online else "off"
    conf_text = router_conf_text(row, services)

    last_info = {}
    try:
        last_info = json.loads(row["last_info"] or "{}")
    except Exception:
        pass

    svc_html = "\n".join(
        service_commands_html(row["id"], s, ssh_hint_user, ssh_hint_port, vps_public_host).replace("{csrf}", html.escape(csrf))
        for s in services
    ) or '<p class="muted">Сервисов нет.</p>'

    body = f"""
    <div class="card">
      <p><span class="dot {dot}"></span><b>{html.escape(row["name"] or row["id"])}</b>
        <span class="muted">id: {html.escape(row["id"])}</span></p>
      <p class="muted">последний heartbeat: {row["last_seen"] and time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(row["last_seen"])) or "никогда"}</p>
      {"<p class='muted'>" + html.escape(json.dumps(last_info, ensure_ascii=False)) + "</p>" if last_info else ""}
      <form method="post" action="/routers/{html.escape(row['id'])}/rotate-token" onsubmit="return confirm('Перевыпустить HUB_TOKEN? Реверс-туннель не порвётся, но конфиг на роутере надо будет обновить.');" style="display:inline">
        <input type="hidden" name="csrf" value="{html.escape(csrf)}">
        <button class="btn ghost small" type="submit">Перевыпустить HUB_TOKEN</button>
      </form>
    </div>

    <div class="card">
      <h3 style="margin-top:0">Конфиг для роутера</h3>
      <p class="muted">Вставь целиком в <code>/opt/etc/netcraze-remote/netcraze-remote.conf</code>
        на самом Keenetic (через SMB-шару Entware или vi по SSH), затем:</p>
      <pre>/opt/etc/init.d/S99netcraze-remote start</pre>
      <pre id="conf-block">{html.escape(conf_text)}</pre>
      <button class="btn small copybtn" id="copy-conf-block" onclick="ncrCopy('conf-block')">Копировать</button>
    </div>

    <div class="svc-grid">
    {svc_html}
    </div>

    {add_service_form_html(row['id'], csrf)}

    <div class="card">
      <form method="post" action="/routers/{html.escape(row['id'])}/delete" onsubmit="return confirm('Удалить роутер {html.escape(row['id'])} со всеми его сервисами?');">
        <input type="hidden" name="csrf" value="{html.escape(csrf)}">
        <button class="btn danger" type="submit">Удалить роутер целиком</button>
      </form>
    </div>
    """
    return page(f"роутер {row['id']}", body)


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "netcraze-remote-hub/2.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _client_ip(self):
        xff = self.headers.get("X-Forwarded-For")
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0]

    def _cookies(self):
        raw = self.headers.get("Cookie", "")
        out = {}
        for part in raw.split(";"):
            part = part.strip()
            if "=" in part:
                k, v = part.split("=", 1)
                out[k] = v
        return out

    def _session(self):
        token = self._cookies().get(SESSION_COOKIE)
        return check_session(token)

    def _bearer_token(self):
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            return auth[len("Bearer "):].strip()
        return None

    def _send_html(self, html_body, code=200):
        data = html_body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _send_json(self, obj, code=200):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _send_text(self, text, code=200):
        data = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, location, set_cookie=None, clear_cookie=False):
        self.send_response(302)
        self.send_header("Location", location)
        if set_cookie:
            self.send_header(
                "Set-Cookie",
                f"{SESSION_COOKIE}={set_cookie}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age={SESSION_TTL_SECONDS}",
            )
        if clear_cookie:
            self.send_header("Set-Cookie", f"{SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0")
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()

    def _read_body(self, limit=1024 * 1024):
        length = int(self.headers.get("Content-Length", "0") or "0")
        length = min(length, limit)
        return self.rfile.read(length) if length else b""

    def _read_form(self):
        body = self._read_body().decode("utf-8", "replace")
        return {k: v[0] for k, v in parse_qs(body).items()}

    def _vps_public_host(self):
        return public_host() if public_host() != "REPLACE_ME" else self.headers.get("Host", "127.0.0.1")

    def _ssh_hint(self):
        user = os.environ.get("NETCRAZE_REMOTE_VPS_SSH_USER", "root")
        port = os.environ.get("NETCRAZE_REMOTE_VPS_SSH_PORT", "22")
        return user, port

    def _require_session_or_redirect(self):
        session = self._session()
        if not session:
            self._redirect("/login")
            return None
        return session

    def _csrf_ok(self, session, form):
        return secrets.compare_digest(form.get("csrf", ""), session.get("csrf", "!"))

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/health":
            self._send_json({"ok": True, "app": APP_NAME})
            return

        if path == "/api/render-client":
            token = self._bearer_token()
            row = get_router_by_token(token) if token else None
            if not row:
                self._send_json({"error": "unauthorized"}, code=401)
                return
            self._send_json(router_client_payload(row, get_services(row["id"])))
            return

        if path == "/api/render-client-conf":
            token = self._bearer_token()
            row = get_router_by_token(token) if token else None
            if not row:
                self._send_text("unauthorized", code=401)
                return
            self._send_text(router_conf_text(row, get_services(row["id"])))
            return

        if path == "/login":
            self._send_html(login_page())
            return

        if path == "/logout":
            self._redirect("/login", clear_cookie=True)
            return

        session = self._require_session_or_redirect()
        if not session:
            return

        if path in ("/", ""):
            self._send_html(dashboard_page(list_routers(), session["csrf"]))
            return

        if path.startswith("/routers/"):
            router_id = path[len("/routers/"):].strip("/")
            row = get_router(router_id)
            if not row:
                self._send_html(page("не найдено", "<p>Роутер не найден.</p>"), code=404)
                return
            user, port = self._ssh_hint()
            services = get_services(router_id)
            self._send_html(router_detail_page(row, services, self._vps_public_host(), user, port, session["csrf"]))
            return

        self._send_html(page("404", "<p>Не найдено.</p>"), code=404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/heartbeat":
            token = self._bearer_token()
            row = get_router_by_token(token) if token else None
            if not row:
                self._send_json({"error": "unauthorized"}, code=401)
                return
            try:
                info = json.loads(self._read_body().decode("utf-8", "replace") or "{}")
            except Exception:
                info = {}
            touch_heartbeat(row["id"], info)
            self._send_json({"ok": True})
            return

        if path == "/login":
            ip = self._client_ip()
            wait = login_rate_check(ip)
            if wait:
                self._send_html(login_page(f"Слишком много попыток, попробуй через {wait} сек."), code=429)
                return
            form = self._read_form()
            username = form.get("username", "")
            password = form.get("password", "")
            if verify_password(username, password):
                login_rate_reset(ip)
                token = create_session(username)
                self._redirect("/", set_cookie=token)
            else:
                login_rate_fail(ip)
                print(f"[auth] неудачный вход username={username!r} ip={ip}", file=sys.stderr)
                self._send_html(login_page("Неверный логин или пароль"))
            return

        session = self._require_session_or_redirect()
        if not session:
            return

        form = self._read_form()
        if not self._csrf_ok(session, form):
            self._send_html(page("403", "<p>CSRF-проверка не пройдена, обнови страницу и попробуй снова.</p>"), code=403)
            return

        if path == "/routers":
            name = form.get("name", "").strip()
            if name:
                create_router(name)
            self._redirect("/")
            return

        if path.startswith("/routers/"):
            rest = path[len("/routers/"):].strip("/")
            parts = rest.split("/")
            router_id = parts[0]

            if len(parts) == 2 and parts[1] == "delete":
                delete_router(router_id)
                self._redirect("/")
                return

            if len(parts) == 2 and parts[1] == "rotate-token":
                rotate_router_token(router_id)
                self._redirect(f"/routers/{router_id}")
                return

            if len(parts) == 2 and parts[1] == "services":
                label = form.get("label", "").strip() or "сервис"
                host = form.get("host", "127.0.0.1").strip() or "127.0.0.1"
                port_raw = form.get("port", "").strip()
                kind = form.get("kind", "tcp").strip()
                if kind not in SERVICE_KINDS:
                    kind = "tcp"
                try:
                    port = int(port_raw)
                    if not (1 <= port <= 65535):
                        raise ValueError
                except ValueError:
                    self._send_html(page("ошибка", "<p>Некорректный порт.</p>"), code=400)
                    return
                try:
                    add_service_to_router(router_id, label, label, kind, host, port)
                except KeyError:
                    self._send_html(page("не найдено", "<p>Роутер не найден.</p>"), code=404)
                    return
                self._redirect(f"/routers/{router_id}")
                return

            if len(parts) == 4 and parts[1] == "services" and parts[3] == "delete":
                delete_service(router_id, int(parts[2]))
                self._redirect(f"/routers/{router_id}")
                return

            if len(parts) == 4 and parts[1] == "services" and parts[3] == "rotate":
                rotate_service_secret(router_id, int(parts[2]))
                self._redirect(f"/routers/{router_id}")
                return

        self._send_html(page("404", "<p>Не найдено.</p>"), code=404)


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def cmd_serve(_args):
    db_init()
    if not load_auth():
        print("Нет учётки администратора — запусти сначала: netcraze-remote-hub.py set-admin-password", file=sys.stderr)
    if not (REVERSE_TLS_CERT and REVERSE_TLS_KEY):
        print("[ВНИМАНИЕ] TLS на реверс-канале не настроен (NETCRAZE_REMOTE_TLS_CERT/KEY пусты) - "
              "VLESS-туннель идёт БЕЗ шифрования (security:none). Обычно эти переменные ставит install-vps.sh.",
              file=sys.stderr)
    server = ThreadingServer((BIND_HOST, BIND_PORT), Handler)
    print(f"{APP_NAME} слушает {BIND_HOST}:{BIND_PORT}")
    server.serve_forever()


def cmd_set_admin_password(args):
    db_init()
    password = args.password
    if password is None:
        password = os.environ.get("NETCRAZE_REMOTE_ADMIN_PASSWORD")
    if password is None:
        import getpass
        password = getpass.getpass("Пароль администратора: ")
    save_auth(args.username, password)
    print(f"Пароль для {args.username} сохранён в {AUTH_FILE}")


def cmd_regen_xray(_args):
    db_init()
    regenerate_xray_config_and_reload()
    print(f"Xray-конфиг перезаписан: {XRAY_CONFIG_PATH}, сервис {XRAY_SERVICE_NAME} перезапущен")


def main():
    parser = argparse.ArgumentParser(description=APP_NAME)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("serve").set_defaults(func=cmd_serve)

    p_pw = sub.add_parser("set-admin-password")
    p_pw.add_argument("username")
    p_pw.add_argument("password", nargs="?", default=None,
                       help="если не задан — берётся из NETCRAZE_REMOTE_ADMIN_PASSWORD или спрашивается интерактивно")
    p_pw.set_defaults(func=cmd_set_admin_password)

    sub.add_parser("regen-xray").set_defaults(func=cmd_regen_xray)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
