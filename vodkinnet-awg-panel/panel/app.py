#!/usr/bin/env python3
"""AWG Panel — панель выдачи клиентов AmneziaWG на виртуальных роутерах OpenWrt.

Работает на z1-mgmt, ходит на роутеры по SSH (ключом) и вызывает на них скрипт
awg-newpeer. Приватные ключи клиентов НЕ сохраняются: конфиг показывается один раз.
"""
import hmac
import io
import os
import re
import secrets
import shlex
import sqlite3
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from functools import wraps

import qrcode
import qrcode.image.svg
from flask import (Flask, abort, jsonify, redirect, render_template, request,
                   session, url_for)
from werkzeug.security import check_password_hash

VERSION = "0.2.0"
DATA = os.environ.get("AWG_PANEL_DATA", "/var/lib/awg-panel")
APPDIR = os.path.dirname(os.path.abspath(__file__))
SSH_BIN = os.environ.get("AWG_SSH_BIN", "ssh")
SSH_KEY = os.environ.get("AWG_SSH_KEY", os.path.join(DATA, "id_ed25519"))
PW_HASH = os.environ.get("AWG_PANEL_PASSWORD_HASH", "")
BIND = os.environ.get("AWG_PANEL_BIND", "127.0.0.1:8080")
POLL_SEC = int(os.environ.get("AWG_PANEL_POLL_SEC", "60"))
EXPIRY_SEC = int(os.environ.get("AWG_PANEL_EXPIRY_SEC", "300"))
ROUTER_SCRIPT = os.environ.get("AWG_ROUTER_SCRIPT") or next(
    (p for p in (os.path.join(APPDIR, "awg-newpeer"), os.path.join(APPDIR, "..", "router", "awg-newpeer"))
     if os.path.exists(p)), os.path.join(APPDIR, "awg-newpeer"))
ONLINE_SEC = 180

NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")
IP_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]{1,253}(:\d{1,5})?$")
KEY_RE = re.compile(r"^[A-Za-z0-9+/]{43}=$")

os.makedirs(DATA, exist_ok=True)
app = Flask(__name__, static_folder=os.path.join(APPDIR, "static"), static_url_path="/static",
            template_folder=os.path.join(APPDIR, "templates"))
_secret_path = os.path.join(DATA, "secret_key")
if not os.path.exists(_secret_path):
    with open(_secret_path, "w") as f:
        f.write(secrets.token_hex(32))
    os.chmod(_secret_path, 0o600)
app.secret_key = open(_secret_path).read().strip()
app.config.update(SESSION_COOKIE_SAMESITE="Strict", SESSION_COOKIE_HTTPONLY=True)


# ───────────────────────── БД ─────────────────────────
def connect():
    c = sqlite3.connect(os.path.join(DATA, "panel.db"), timeout=15)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    c = connect()
    c.executescript("""
    CREATE TABLE IF NOT EXISTS routers(
        id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, ip TEXT NOT NULL,
        endpoint TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '');
    CREATE TABLE IF NOT EXISTS clients(
        id INTEGER PRIMARY KEY, router_id INTEGER NOT NULL, name TEXT NOT NULL,
        created INTEGER NOT NULL, expires INTEGER, note TEXT NOT NULL DEFAULT '',
        UNIQUE(router_id, name));
    CREATE TABLE IF NOT EXISTS events(ts INTEGER, text TEXT);
    CREATE TABLE IF NOT EXISTS samples(
        ts INTEGER NOT NULL, router_id INTEGER NOT NULL,
        online INTEGER NOT NULL, total INTEGER NOT NULL, rx INTEGER NOT NULL, tx INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
    """)
    c.commit()
    c.close()


def log_event(text):
    c = connect()
    c.execute("INSERT INTO events VALUES(?,?)", (int(time.time()), text))
    c.commit()
    c.close()


def q(sql, args=(), one=False):
    c = connect()
    try:
        cur = c.execute(sql, args)
        rows = cur.fetchone() if one else cur.fetchall()
        c.commit()
        return rows
    finally:
        c.close()


# ───────────────────────── SSH ─────────────────────────
def ssh(router_ip, *args, input_text=None, timeout=30):
    remote = " ".join(shlex.quote(a) for a in args)
    cmd = [SSH_BIN, "-i", SSH_KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
           "-o", "StrictHostKeyChecking=accept-new",
           "-o", "UserKnownHostsFile=" + os.path.join(DATA, "known_hosts"),
           "root@" + router_ip, remote]
    try:
        p = subprocess.run(cmd, input=input_text, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 255, "", "таймаут SSH"
    return p.returncode, p.stdout, p.stderr.strip()


def awg(router_ip, *args, **kw):
    return ssh(router_ip, "/usr/bin/awg-newpeer", *args, **kw)


# ───────────────────────── разбор ответов роутера ─────────────────────────
def kv(line):
    out = {}
    for part in line.split()[1:]:
        k, _, v = part.partition("=")
        out[k] = v
    return out


def parse_status(text):
    sysinfo, awginfo, clients = {}, {}, []
    for line in text.splitlines():
        if line.startswith("#sys "):
            sysinfo = kv(line)
        elif line.startswith("#awg "):
            awginfo = kv(line)
        else:
            p = line.split("\t")
            if len(p) >= 7 and p[0]:
                clients.append(dict(name=p[0], ip=p[1], paused=p[2] == "1", pubkey=p[3],
                                    handshake=int(p[4] or 0), rx=int(p[5] or 0), tx=int(p[6] or 0)))
    return sysinfo, awginfo, clients


def to_int(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def subnet_of(addr):
    m = IP_RE.match((addr or "").split("/")[0])
    return f"{m.group(1)}.{m.group(2)}.{m.group(3)}.0/24" if m else ""


def is_online(c, now=None):
    now = now or time.time()
    return (not c["paused"]) and c["handshake"] > 0 and now - c["handshake"] < ONLINE_SEC


# ───────────────────────── опрос роутеров ─────────────────────────
STATUS = {}            # router_id -> словарь состояния
STATUS_LOCK = threading.Lock()


def poll_router(r):
    now = int(time.time())
    st = dict(ts=now, reachable=False, script=False, error=None, clients=[])
    rc, out, err = awg(r["ip"], "status", timeout=25)
    if rc == 0:
        sysinfo, awginfo, clients = parse_status(out)
        st.update(reachable=True, script=True, sys=sysinfo, awg=awginfo, clients=clients)
    elif rc == 127 or "not found" in (err + out):
        st.update(reachable=True, script=False, error="скрипт awg-newpeer не установлен на роутере")
    else:
        st["error"] = err or out or f"код {rc}"
    with STATUS_LOCK:
        STATUS[r["id"]] = st
    if st["script"]:
        online = sum(1 for c in st["clients"] if is_online(c, now))
        rx = sum(c["rx"] for c in st["clients"])
        tx = sum(c["tx"] for c in st["clients"])
        q("INSERT INTO samples VALUES(?,?,?,?,?,?)", (now, r["id"], online, len(st["clients"]), rx, tx))
    return st


def poll_all():
    routers = q("SELECT * FROM routers")
    if routers:
        with ThreadPoolExecutor(max_workers=8) as ex:
            list(ex.map(lambda r: poll_router(dict(r)), routers))
    q("DELETE FROM samples WHERE ts < ?", (int(time.time()) - 90 * 86400,))


def poll_worker():
    time.sleep(1)
    while True:
        try:
            poll_all()
        except Exception as e:
            print("poll_worker:", e, flush=True)
        time.sleep(POLL_SEC)


def expiry_worker():
    while True:
        time.sleep(EXPIRY_SEC)
        try:
            rows = q("""SELECT c.id,c.name,r.name rname,r.ip FROM clients c JOIN routers r ON r.id=c.router_id
                        WHERE c.expires IS NOT NULL AND c.expires < ?""", (int(time.time()),))
            for row in rows:
                rc, out, err = awg(row["ip"], "del", row["name"])
                if rc == 0 or "не найден" in (out + err):
                    q("DELETE FROM clients WHERE id=?", (row["id"],))
                    log_event(f"{row['rname']}: срок клиента {row['name']} истёк, клиент удалён")
        except Exception as e:
            print("expiry_worker:", e, flush=True)


# ───────────────────────── авторизация / CSRF ─────────────────────────
def csrf_token():
    if "csrf" not in session:
        session["csrf"] = secrets.token_hex(16)
    return session["csrf"]


def api(f):
    @wraps(f)
    def w(*a, **kw):
        if not session.get("ok"):
            return jsonify(error="нужен вход"), 401
        if request.method != "GET":
            if not hmac.compare_digest(request.headers.get("X-CSRF", ""), session.get("csrf", "x")):
                return jsonify(error="CSRF"), 400
        return f(*a, **kw)
    return w


def err(msg, code=400):
    return jsonify(error=msg), code


def qr_svg(text):
    img = qrcode.make(text, image_factory=qrcode.image.svg.SvgPathImage,
                      error_correction=qrcode.constants.ERROR_CORRECT_L, border=2)
    buf = io.BytesIO()
    img.save(buf)
    svg = buf.getvalue().decode()
    return svg[svg.find("<svg"):]


def get_router(rid):
    r = q("SELECT * FROM routers WHERE id=?", (rid,), one=True)
    if not r:
        abort(404)
    return dict(r)


# ───────────────────────── страницы ─────────────────────────
@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        time.sleep(0.5)
        if PW_HASH and check_password_hash(PW_HASH, request.form.get("password", "")):
            session.clear()
            session["ok"] = True
            return redirect(url_for("index"))
        error = "Неверный пароль"
    return render_template("login.html", error=error, version=VERSION)


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
def index():
    if not session.get("ok"):
        return redirect(url_for("login"))
    return render_template("index.html", csrf=csrf_token(), version=VERSION)


# ───────────────────────── API: роутеры ─────────────────────────
def router_card(r):
    with STATUS_LOCK:
        st = STATUS.get(r["id"])
    d = dict(id=r["id"], name=r["name"], ip=r["ip"], endpoint=r["endpoint"], note=r["note"], state="unknown")
    if st:
        now = time.time()
        d.update(error=st["error"], ts=st["ts"])
        if st["script"]:
            s, a, cl = st["sys"], st["awg"], st["clients"]
            d.update(state="online", uptime=to_int(s.get("uptime")), load=float(s.get("load") or 0),
                     cores=max(1, to_int(s.get("cores"), 1)),
                     mem_total=to_int(s.get("mem_total")), mem_avail=to_int(s.get("mem_avail")),
                     disk_total=to_int(s.get("disk_total")), disk_used=to_int(s.get("disk_used")),
                     iface=a.get("iface", "awg0"), addr=a.get("addr", ""), port=a.get("port", ""),
                     subnet=subnet_of(a.get("addr")),
                     clients_total=len(cl), clients_online=sum(1 for c in cl if is_online(c, now)),
                     rx=sum(c["rx"] for c in cl), tx=sum(c["tx"] for c in cl))
        else:
            d["state"] = "no_script" if st["reachable"] else "offline"
    return d


@app.route("/api/routers", methods=["GET"])
@api
def api_routers():
    return jsonify(routers=[router_card(dict(r)) for r in q("SELECT * FROM routers ORDER BY name")])


def validate_router(form):
    name, ip = (form.get("name") or "").strip(), (form.get("ip") or "").strip()
    ep, note = (form.get("endpoint") or "").strip(), (form.get("note") or "").strip()[:200]
    m = IP_RE.match(ip)
    if not NAME_RE.match(name):
        return None, "Имя: латиница, цифры, . _ - (до 32 символов)"
    if not m or any(int(x) > 255 for x in m.groups()):
        return None, "Некорректный IP"
    if ep and not HOST_RE.match(ep):
        return None, "Некорректный внешний адрес (ожидается хост или хост:порт)"
    return (name, ip, ep, note), None


@app.route("/api/routers", methods=["POST"])
@api
def api_router_add():
    vals, e = validate_router(request.get_json(silent=True) or {})
    if e:
        return err(e)
    try:
        q("INSERT INTO routers(name,ip,endpoint,note) VALUES(?,?,?,?)", vals)
    except sqlite3.IntegrityError:
        return err("Роутер с таким именем уже есть")
    log_event(f"роутер {vals[0]} ({vals[1]}) добавлен")
    r = q("SELECT * FROM routers WHERE name=?", (vals[0],), one=True)
    threading.Thread(target=poll_router, args=(dict(r),), daemon=True).start()
    return jsonify(ok=True, id=r["id"])


@app.route("/api/routers/<int:rid>", methods=["PUT"])
@api
def api_router_edit(rid):
    get_router(rid)
    vals, e = validate_router(request.get_json(silent=True) or {})
    if e:
        return err(e)
    try:
        q("UPDATE routers SET name=?, ip=?, endpoint=?, note=? WHERE id=?", vals + (rid,))
    except sqlite3.IntegrityError:
        return err("Роутер с таким именем уже есть")
    log_event(f"роутер {vals[0]} изменён")
    threading.Thread(target=poll_router, args=(get_router(rid),), daemon=True).start()
    return jsonify(ok=True)


@app.route("/api/routers/<int:rid>", methods=["DELETE"])
@api
def api_router_delete(rid):
    r = get_router(rid)
    q("DELETE FROM clients WHERE router_id=?", (rid,))
    q("DELETE FROM samples WHERE router_id=?", (rid,))
    q("DELETE FROM routers WHERE id=?", (rid,))
    with STATUS_LOCK:
        STATUS.pop(rid, None)
    log_event(f"роутер {r['name']} удалён из панели (на самом роутере ничего не менялось)")
    return jsonify(ok=True)


@app.route("/api/routers/<int:rid>/refresh", methods=["POST"])
@api
def api_router_refresh(rid):
    r = get_router(rid)
    poll_router(r)
    return jsonify(router=router_card(r))


@app.route("/api/routers/<int:rid>/check", methods=["POST"])
@api
def api_router_check(rid):
    r = get_router(rid)
    st = poll_router(r)
    if st["script"]:
        return jsonify(ok=True, message="Связь есть, скрипт на месте")
    if st["reachable"]:
        return err("Роутер доступен, но скрипта нет — нажми «Установить скрипт»")
    return err("Нет связи по SSH: " + (st["error"] or "?"))


@app.route("/api/routers/<int:rid>/install", methods=["POST"])
@api
def api_router_install(rid):
    r = get_router(rid)
    with open(ROUTER_SCRIPT, encoding="utf-8") as f:
        script = f.read()
    rc, out, e = ssh(r["ip"], "sh", "-c", "cat > /usr/bin/awg-newpeer && chmod +x /usr/bin/awg-newpeer", input_text=script)
    if rc != 0:
        return err(f"Не удалось: {e or out}")
    log_event(f"на {r['name']} установлен скрипт awg-newpeer")
    poll_router(r)
    return jsonify(ok=True, message="Скрипт установлен")


@app.route("/api/routers/<int:rid>/forget", methods=["POST"])
@api
def api_router_forget(rid):
    r = get_router(rid)
    subprocess.run(["ssh-keygen", "-R", r["ip"], "-f", os.path.join(DATA, "known_hosts")], capture_output=True)
    return jsonify(ok=True, message="SSH-ключ роутера забыт; при следующем подключении будет принят заново")


# ───────────────────────── API: клиенты ─────────────────────────
@app.route("/api/routers/<int:rid>/clients", methods=["GET"])
@api
def api_clients(rid):
    r = get_router(rid)
    st = poll_router(r)
    if not st["script"]:
        return err(st["error"] or "роутер недоступен", 502)
    meta = {c["name"]: c for c in q("SELECT * FROM clients WHERE router_id=?", (rid,))}
    now = time.time()
    out = []
    for c in st["clients"]:
        m = meta.get(c["name"])
        out.append(dict(name=c["name"], ip=c["ip"], paused=c["paused"], online=is_online(c, now),
                        handshake=c["handshake"], rx=c["rx"], tx=c["tx"],
                        expires=m["expires"] if m else None, note=m["note"] if m else "",
                        foreign=m is None))
    a = st["awg"]
    return jsonify(router=router_card(r), iface=a.get("iface", "awg0"), addr=a.get("addr", ""),
                   port=a.get("port", ""), subnet=subnet_of(a.get("addr")), pub=a.get("pub", ""),
                   endpoint=r["endpoint"], clients=out)


@app.route("/api/routers/<int:rid>/clients", methods=["POST"])
@api
def api_client_add(rid):
    r = get_router(rid)
    d = request.get_json(silent=True) or {}
    name = (d.get("name") or "").strip()
    pub = (d.get("pubkey") or "").strip()
    note = (d.get("note") or "").strip()[:200]
    days = d.get("days")
    if not NAME_RE.match(name):
        return err("Имя: латиница, цифры, . _ - (до 32 символов)")
    if pub and not KEY_RE.match(pub):
        return err("Публичный ключ выглядит неверно (44 символа base64 с «=» на конце)")
    args = ["add", name]
    if pub:
        args += ["-k", pub]
    if r["endpoint"]:
        args += ["-e", r["endpoint"]]
    rc, out, e = awg(r["ip"], *args)
    if rc != 0:
        return err(f"Роутер ответил ошибкой: {e or out}", 502)
    exp = None
    try:
        if days and int(days) > 0:
            exp = int(time.time()) + int(days) * 86400
    except (TypeError, ValueError):
        pass
    q("INSERT OR REPLACE INTO clients(router_id,name,created,expires,note) VALUES(?,?,?,?,?)",
      (rid, name, int(time.time()), exp, note))
    log_event(f"{r['name']}: выдан клиент {name}" + (f" на {days} дн" if exp else ""))
    threading.Thread(target=poll_router, args=(r,), daemon=True).start()
    conf = out.strip() if out.lstrip().startswith("[Interface]") else None
    return jsonify(ok=True, name=name, conf=conf, info=None if conf else out.strip(),
                   qr=qr_svg(conf) if conf else None)


@app.route("/api/routers/<int:rid>/clients/<name>/<action>", methods=["POST"])
@api
def api_client_action(rid, name, action):
    r = get_router(rid)
    if not NAME_RE.match(name) or action not in ("pause", "resume", "delete", "expiry"):
        return err("Некорректный запрос")
    if action == "expiry":
        d = request.get_json(silent=True) or {}
        days = d.get("days")
        row = q("SELECT * FROM clients WHERE router_id=? AND name=?", (rid, name), one=True)
        if not days:
            exp = None
        else:
            base = max((row["expires"] or 0) if row and d.get("extend") else 0, int(time.time()))
            exp = base + int(days) * 86400
        if row:
            q("UPDATE clients SET expires=? WHERE id=?", (exp, row["id"]))
        else:
            q("INSERT INTO clients(router_id,name,created,expires) VALUES(?,?,?,?)", (rid, name, int(time.time()), exp))
        log_event(f"{r['name']}: срок клиента {name} → " + (datetime.fromtimestamp(exp).strftime("%d.%m.%Y") if exp else "бессрочно"))
        return jsonify(ok=True)
    cmd = {"pause": "pause", "resume": "resume", "delete": "del"}[action]
    rc, out, e = awg(r["ip"], cmd, name)
    if rc != 0:
        return err(f"Ошибка: {e or out}", 502)
    if action == "delete":
        q("DELETE FROM clients WHERE router_id=? AND name=?", (rid, name))
    ru = {"pause": "поставлен на паузу", "resume": "снова включён", "delete": "удалён"}[action]
    log_event(f"{r['name']}: клиент {name} {ru}")
    threading.Thread(target=poll_router, args=(r,), daemon=True).start()
    return jsonify(ok=True, message=out.strip())


# ───────────────────────── API: обзор, статистика, журнал ─────────────────────────
RANGES = {"3h": 3 * 3600, "6h": 6 * 3600, "12h": 12 * 3600, "24h": 86400,
          "7d": 7 * 86400, "30d": 30 * 86400, "90d": 90 * 86400}


@app.route("/api/overview", methods=["GET"])
@api
def api_overview():
    cards = [router_card(dict(r)) for r in q("SELECT * FROM routers ORDER BY name")]
    now = time.time()
    top = []
    with STATUS_LOCK:
        for r in cards:
            st = STATUS.get(r["id"])
            if st and st["script"]:
                for c in st["clients"]:
                    top.append(dict(name=c["name"], router=r["name"], rx=c["rx"], tx=c["tx"],
                                    total=c["rx"] + c["tx"], online=is_online(c, now), paused=c["paused"]))
    top.sort(key=lambda c: c["total"], reverse=True)
    return jsonify(
        routers=cards,
        routers_online=sum(1 for r in cards if r["state"] == "online"), routers_total=len(cards),
        clients_online=sum(r.get("clients_online", 0) for r in cards),
        clients_total=sum(r.get("clients_total", 0) for r in cards),
        rx=sum(r.get("rx", 0) for r in cards), tx=sum(r.get("tx", 0) for r in cards),
        top=top[:10])


@app.route("/api/stats", methods=["GET"])
@api
def api_stats():
    rng = request.args.get("range", "24h")
    span = RANGES.get(rng, 86400)
    now = int(time.time())
    since = now - span
    bucket = max(60, span // 96)
    rows = q("SELECT * FROM samples WHERE ts >= ? ORDER BY router_id, ts", (since - bucket,))
    traffic, online_last = {}, {}
    prev = {}
    for s in rows:
        rid, key = s["router_id"], s["ts"] // bucket
        tot = s["rx"] + s["tx"]
        if rid in prev:
            delta = tot - prev[rid]
            if delta < 0:      # счётчики сбросились (перезапуск интерфейса)
                delta = tot
            if s["ts"] >= since:
                traffic[key] = traffic.get(key, 0) + delta
        prev[rid] = tot
        if s["ts"] >= since:
            online_last.setdefault(key, {})[rid] = s["online"]
    keys = range(since // bucket, now // bucket + 1)
    pts = [dict(t=k * bucket, bytes=traffic.get(k, 0), online=sum(online_last.get(k, {}).values())) for k in keys]
    return jsonify(range=rng, bucket=bucket, points=pts)


@app.route("/api/events", methods=["GET"])
@api
def api_events():
    rows = q("SELECT * FROM events ORDER BY ts DESC LIMIT 300")
    return jsonify(events=[dict(ts=e["ts"], text=e["text"]) for e in rows])


init_db()

if __name__ == "__main__":
    threading.Thread(target=poll_worker, daemon=True).start()
    threading.Thread(target=expiry_worker, daemon=True).start()
    host, _, port = BIND.partition(":")
    app.run(host=host, port=int(port or 8080), threaded=True)
