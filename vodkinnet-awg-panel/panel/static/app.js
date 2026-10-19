/* AWG Panel — интерфейс. Чистый JS без зависимостей и без CDN. */
(() => {
'use strict';

const CSRF = document.querySelector('meta[name=csrf]').content;
const view = document.getElementById('view');
const modalRoot = document.getElementById('modal-root');
const toasts = document.getElementById('toasts');

/* ───────── утилиты ───────── */
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'style') el.style.cssText = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  const add = (x) => {
    if (x == null || x === false) return;
    if (Array.isArray(x)) x.forEach(add);
    else el.append(x instanceof Node ? x : document.createTextNode(String(x)));
  };
  kids.forEach(add);
  return el;
}

async function api(method, url, body) {
  const opt = { method, headers: { 'X-CSRF': CSRF } };
  if (body !== undefined) { opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(body); }
  let r;
  try { r = await fetch(url, opt); } catch (e) { throw new Error('Нет связи с панелью'); }
  if (r.status === 401) { location.href = '/login'; throw new Error('нужен вход'); }
  let data = {};
  try { data = await r.json(); } catch (e) { /* пусто */ }
  if (!r.ok) throw new Error(data.error || ('Ошибка ' + r.status));
  return data;
}

function toast(msg, isErr) {
  const t = h('div', { class: 'toast' + (isErr ? ' err' : ''), text: msg });
  toasts.append(t);
  setTimeout(() => t.remove(), isErr ? 7000 : 3500);
}

const UNITS = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
function bytes(n) {
  n = Number(n) || 0;
  let i = 0;
  while (n >= 1024 && i < UNITS.length - 1) { n /= 1024; i++; }
  return (i === 0 ? n.toFixed(0) : n.toFixed(n >= 100 ? 0 : 1)) + ' ' + UNITS[i];
}
function dur(s) {
  s = Math.floor(Number(s) || 0);
  const d = Math.floor(s / 86400), hh = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (d) return d + ' д ' + hh + ' ч';
  if (hh) return hh + ' ч ' + m + ' мин';
  return m + ' мин';
}
function ago(ts) {
  if (!ts) return 'никогда';
  const d = Math.floor(Date.now() / 1000) - ts;
  if (d < 60) return d + ' с назад';
  if (d < 3600) return Math.floor(d / 60) + ' мин назад';
  if (d < 86400) return Math.floor(d / 3600) + ' ч назад';
  return Math.floor(d / 86400) + ' дн назад';
}
const MONTHS = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
function dshort(ts) { const d = new Date(ts * 1000); return d.getDate() + ' ' + MONTHS[d.getMonth()]; }
function dfull(ts) {
  const d = new Date(ts * 1000), p = (x) => String(x).padStart(2, '0');
  return p(d.getDate()) + '.' + p(d.getMonth() + 1) + '.' + d.getFullYear() + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}
function hm(ts) { const d = new Date(ts * 1000), p = (x) => String(x).padStart(2, '0'); return p(d.getHours()) + ':' + p(d.getMinutes()); }

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); return true; } catch (e) { /* запасной путь */ }
  const ta = h('textarea', { style: 'position:fixed;opacity:0' }); ta.value = text; document.body.append(ta); ta.select();
  let ok = false; try { ok = document.execCommand('copy'); } catch (e) { /* нет */ }
  ta.remove(); return ok;
}
function download(name, text) {
  const a = h('a', { href: URL.createObjectURL(new Blob([text], { type: 'text/plain' })), download: name });
  document.body.append(a); a.click(); a.remove();
}

/* ───────── модальные окна и меню ───────── */
const stack = [];
function openModal(content, opts = {}) {
  const box = h('div', { class: 'modal' + (opts.wide ? ' wide' : '') }, content);
  const ov = h('div', { class: 'overlay' }, box);
  let down = false;
  ov.addEventListener('mousedown', (e) => { down = e.target === ov; });
  ov.addEventListener('mouseup', (e) => { if (down && e.target === ov) api_close(); down = false; });
  const api_close = () => { const i = stack.indexOf(handle); if (i >= 0) stack.splice(i, 1); ov.remove(); if (opts.onClose) opts.onClose(); };
  const handle = { close: api_close, el: box };
  stack.push(handle);
  modalRoot.append(ov);
  return handle;
}
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && stack.length) stack[stack.length - 1].close(); });

let openMenu = null;
document.addEventListener('click', (e) => { if (openMenu && !openMenu.contains(e.target)) { openMenu.querySelector('.menu-list')?.remove(); openMenu = null; } });
function menu(label, items, cls = 'btn') {
  const wrap = h('span', { class: 'menu' });
  const btn = h('button', { class: cls, type: 'button', text: label });
  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    if (openMenu) { const was = openMenu === wrap; openMenu.querySelector('.menu-list')?.remove(); openMenu = null; if (was) return; }
    const list = h('div', { class: 'menu-list' }, items.filter(Boolean).map((it) =>
      h('button', { class: it.danger ? 'danger' : '', type: 'button', text: it.label, onclick: () => { list.remove(); openMenu = null; it.run(); } })));
    wrap.append(list); openMenu = wrap;
  });
  wrap.append(btn);
  return wrap;
}

function confirmBox(title, text, okLabel, onOk, danger = true) {
  const m = openModal([
    h('div', { class: 'mhead' }, h('h2', { text: title })),
    h('p', { text }),
    h('div', { class: 'mfoot' },
      h('button', { class: 'btn', text: 'Отмена', onclick: () => m.close() }),
      h('button', { class: 'btn ' + (danger ? 'danger' : 'primary'), text: okLabel, onclick: async () => { m.close(); await onOk(); } })),
  ]);
}

/* ───────── роутер/маршрутизация ───────── */
let timer = null;
function route() {
  clearInterval(timer); timer = null;
  const name = (location.hash.replace(/^#\//, '') || 'routers').split('/')[0];
  document.querySelectorAll('#nav a').forEach((a) => a.classList.toggle('active', a.dataset.route === name));
  ({ routers: viewRouters, overview: viewOverview, log: viewLog }[name] || viewRouters)();
}
window.addEventListener('hashchange', route);

const themeBtn = document.getElementById('theme');
const themeIcon = () => { themeBtn.textContent = document.documentElement.dataset.theme === 'dark' ? '☀' : '☾'; };
themeIcon();
themeBtn.addEventListener('click', () => {
  const t = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = t; themeIcon();
  try { localStorage.setItem('awg-theme', t); } catch (e) { /* без сохранения */ }
});

/* ───────── вид «Роутеры» ───────── */
function pctChip(label, pct, extra) {
  const cls = pct >= 90 ? 'bad' : pct >= 75 ? 'warn' : '';
  return h('span', { class: 'chip ' + cls }, label + ' ', h('b', { text: pct + '%' }), extra ? ' ' + extra : '');
}

function routerCard(r, reload) {
  const dot = r.state === 'online' ? 'on' : r.state === 'offline' ? 'off' : r.state === 'no_script' ? 'warn' : '';
  const actions = h('div', { class: 'row1', style: 'margin-left:auto;gap:8px' },
    h('button', { class: 'btn accent', text: 'Клиенты', onclick: () => openClients(r) }),
    menu('Ещё ▾', [
      { label: 'Проверить связь', run: async () => { try { const x = await api('POST', `/api/routers/${r.id}/check`); toast(x.message); } catch (e) { toast(e.message, true); } reload(); } },
      { label: 'Установить / обновить скрипт', run: async () => { try { const x = await api('POST', `/api/routers/${r.id}/install`); toast(x.message); } catch (e) { toast(e.message, true); } reload(); } },
      { label: 'Забыть SSH-ключ роутера', run: async () => { try { const x = await api('POST', `/api/routers/${r.id}/forget`); toast(x.message); } catch (e) { toast(e.message, true); } } },
      { label: 'Изменить', run: () => routerForm(r, reload) },
      { label: 'Удалить из панели', danger: true, run: () => confirmBox('Удалить роутер «' + r.name + '»?', 'Роутер исчезнет из панели вместе с записями о сроках. На самом роутере ничего не изменится.', 'Удалить', async () => { try { await api('DELETE', `/api/routers/${r.id}`); toast('Удалено'); } catch (e) { toast(e.message, true); } reload(); }) },
    ]));

  const online = r.state === 'online';
  const memPct = online && r.mem_total ? Math.round(100 * (r.mem_total - r.mem_avail) / r.mem_total) : 0;
  const diskPct = online && r.disk_total ? Math.round(100 * r.disk_used / r.disk_total) : 0;
  const loadPct = online ? Math.min(100, Math.round(100 * r.load / r.cores)) : 0;

  return h('div', { class: 'card rcard' },
    h('div', { class: 'row1' }, h('h3', { text: r.name }), h('span', { class: 'dot ' + dot, title: r.state }), actions),
    h('div', { class: 'row2' },
      h('span', { class: 'mono', text: r.ip }),
      online && h('span', { class: 'pill ok', text: 'AmneziaWG' }),
      online && r.addr && h('span', { class: 'pill mono', text: r.addr }),
      r.endpoint && h('span', { class: 'pill mono', title: 'Внешний адрес для клиентов', text: r.endpoint }),
      r.state === 'no_script' && h('span', { class: 'pill warn', text: 'нет скрипта' }),
      r.state === 'offline' && h('span', { class: 'pill bad', text: 'нет связи' })),
    r.note && h('div', { class: 'note muted small', text: r.note }),
    r.error && !online && h('div', { class: 'errline', text: r.error }),
    h('hr'),
    h('div', { class: 'row3' },
      online ? h('span', { class: 'muted' }, '⏱ ', h('b', { class: 'mono', style: 'color:var(--tx)', text: dur(r.uptime) })) : h('span', { class: 'muted', text: r.state === 'unknown' ? 'опрос…' : '—' }),
      online && h('span', { class: 'chip' }, 'клиентов в сети ', h('b', { text: r.clients_online + ' / ' + r.clients_total })),
      online && h('div', { class: 'chips' },
        pctChip('CPU', loadPct, r.load.toFixed(2) + '/' + r.cores),
        pctChip('RAM', memPct, bytes((r.mem_total - r.mem_avail) * 1024) + ' / ' + bytes(r.mem_total * 1024)),
        pctChip('DISK', diskPct, bytes(r.disk_used * 1024) + ' / ' + bytes(r.disk_total * 1024)))));
}

async function viewRouters() {
  const list = h('div');
  const head = h('div', { class: 'page-head' }, h('h1', { class: 'page', text: 'Роутеры' }), h('span', { class: 'spacer' }),
    h('button', { class: 'btn primary', text: 'Добавить роутер', onclick: () => routerForm(null, load) }));
  view.replaceChildren(head, list);
  async function load() {
    try {
      const { routers } = await api('GET', '/api/routers');
      list.replaceChildren(...(routers.length ? routers.map((r) => routerCard(r, load))
        : [h('div', { class: 'card empty', text: 'Роутеров пока нет. Нажми «Добавить роутер».' })]));
    } catch (e) { list.replaceChildren(h('div', { class: 'alert err', text: e.message })); }
  }
  await load();
  timer = setInterval(load, 20000);
}

function routerForm(r, done) {
  const f = {
    name: h('input', { value: r?.name || '', placeholder: 'z1-rt01', required: true }),
    ip: h('input', { value: r?.ip || '', placeholder: '10.10.0.3', required: true }),
    endpoint: h('input', { value: r?.endpoint || '', placeholder: 'vpn.example.com:51001' }),
    note: h('input', { value: r?.note || '', placeholder: 'необязательно' }),
  };
  const errBox = h('div');
  const m = openModal([
    h('div', { class: 'mhead' }, h('h2', { text: r ? 'Изменить роутер' : 'Добавить роутер' })),
    errBox,
    h('div', { class: 'grid2' },
      h('label', { class: 'field' }, h('span', { text: 'Имя' }), f.name),
      h('label', { class: 'field' }, h('span', { text: 'IP в зоне' }), f.ip)),
    h('label', { class: 'field' }, h('span', { text: 'Внешний адрес:порт (что клиент вписывает как Endpoint)' }), f.endpoint),
    h('label', { class: 'field' }, h('span', { text: 'Заметка' }), f.note),
    h('div', { class: 'mfoot' },
      h('button', { class: 'btn', text: 'Отмена', onclick: () => m.close() }),
      h('button', { class: 'btn primary', text: r ? 'Сохранить' : 'Добавить', onclick: async () => {
        try {
          const body = Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v.value]));
          await api(r ? 'PUT' : 'POST', r ? `/api/routers/${r.id}` : '/api/routers', body);
          m.close(); toast(r ? 'Сохранено' : 'Роутер добавлен'); done();
        } catch (e) { errBox.replaceChildren(h('div', { class: 'alert err', text: e.message })); }
      } })),
  ]);
  f.name.focus();
}

/* ───────── окно «Клиенты» ───────── */
function expiryBadge(c) {
  if (!c.expires) return h('span', { class: 'pill', text: 'бессрочно' });
  const left = (c.expires - Date.now() / 1000) / 86400;
  if (left <= 0) return h('span', { class: 'pill bad', text: 'истёк' });
  return h('span', { class: 'pill ' + (left <= 14 ? 'warn' : 'ok'), title: dfull(c.expires), text: 'до ' + dshort(c.expires) });
}

async function openClients(r) {
  const body = h('div', {}, h('div', { class: 'empty', text: 'Загрузка…' }));
  const chips = h('div', { class: 'kvrow' });
  const search = h('input', { placeholder: 'Поиск клиента…' });
  let data = null;
  const m = openModal([
    h('div', { class: 'mhead' }, h('h2', { text: 'Клиенты · ' + r.name }), h('span', { class: 'spacer', style: 'flex:1' }),
      h('button', { class: 'btn', text: 'Закрыть', onclick: () => m.close() })),
    chips,
    h('div', { class: 'toolbar' }, search,
      h('button', { class: 'btn', text: 'Обновить', onclick: load }),
      h('button', { class: 'btn primary', text: 'Добавить клиента', onclick: () => clientForm(r, load) })),
    body,
  ], { wide: true });

  function draw() {
    if (!data) return;
    const qs = search.value.trim().toLowerCase();
    const rows = data.clients.filter((c) => !qs || c.name.toLowerCase().includes(qs) || (c.note || '').toLowerCase().includes(qs))
      .sort((a, b) => (b.rx + b.tx) - (a.rx + a.tx));
    if (!rows.length) { body.replaceChildren(h('div', { class: 'empty', text: data.clients.length ? 'Ничего не найдено' : 'Клиентов пока нет' })); return; }
    body.replaceChildren(h('table', { class: 't resp' },
      h('thead', {}, h('tr', {}, h('th', { text: 'Клиент' }), h('th', { text: 'Адрес' }), h('th', { text: 'Статус' }), h('th', { text: 'Трафик' }), h('th', { text: 'Срок' }), h('th'))),
      h('tbody', {}, rows.map((c) => h('tr', {},
        h('td', { 'data-l': 'Клиент' }, h('div', { text: c.name }), c.note && h('div', { class: 'sub', text: c.note }), c.foreign && h('div', { class: 'sub', text: 'создан не в панели' })),
        h('td', { 'data-l': 'Адрес', class: 'mono', text: c.ip }),
        h('td', { 'data-l': 'Статус' }, c.paused ? h('span', { class: 'pill warn', text: 'пауза' })
          : h('span', { style: 'display:inline-flex;gap:7px;align-items:center' }, h('span', { class: 'dot ' + (c.online ? 'on' : '') }), h('span', { class: 'sub', text: c.online ? 'в сети' : ago(c.handshake) }))),
        h('td', { 'data-l': 'Трафик', class: 'mono sub', text: '↓ ' + bytes(c.rx) + ' · ↑ ' + bytes(c.tx) }),
        h('td', { 'data-l': 'Срок' }, expiryBadge(c)),
        h('td', { class: 'r' }, menu('⋯', [
          c.paused ? { label: 'Включить', run: () => act(c, 'resume') } : { label: 'Поставить на паузу', run: () => act(c, 'pause') },
          { label: 'Срок действия…', run: () => expiryForm(r, c, load) },
          { label: 'Удалить', danger: true, run: () => confirmBox('Удалить клиента «' + c.name + '»?', 'Клиент перестанет подключаться. Его конфиг на устройстве станет бесполезным.', 'Удалить', () => act(c, 'delete')) },
        ], 'btn sm')))))));
  }
  async function act(c, action) {
    try { await api('POST', `/api/routers/${r.id}/clients/${encodeURIComponent(c.name)}/${action}`); toast('Готово'); } catch (e) { toast(e.message, true); }
    load();
  }
  async function load() {
    try {
      data = await api('GET', `/api/routers/${r.id}/clients`);
      chips.replaceChildren(
        h('span', { class: 'chip' }, 'INTERFACE ', h('b', { class: 'mono', text: data.iface })),
        h('span', { class: 'chip' }, 'ENDPOINT ', h('b', { class: 'mono', text: data.endpoint || 'не задан' })),
        h('span', { class: 'chip' }, 'SUBNET ', h('b', { class: 'mono', text: data.subnet || '?' })),
        h('span', { class: 'chip' }, 'PORT ', h('b', { class: 'mono', text: data.port || '?' })));
      draw();
    } catch (e) { body.replaceChildren(h('div', { class: 'alert err', text: e.message })); }
  }
  search.addEventListener('input', draw);
  load();
}

function expiryForm(r, c, done) {
  const sel = h('select', {}, [['30', '+30 дней'], ['90', '+90 дней'], ['180', '+180 дней'], ['365', '+365 дней'], ['0', 'бессрочно']].map(([v, t]) => h('option', { value: v, text: t })));
  const from = h('input', { type: 'checkbox', checked: !!c.expires, style: 'width:auto' });
  const m = openModal([
    h('div', { class: 'mhead' }, h('h2', { text: 'Срок · ' + c.name })),
    h('p', { class: 'muted', text: c.expires ? 'Сейчас: до ' + dfull(c.expires) : 'Сейчас: бессрочно' }),
    h('label', { class: 'field' }, h('span', { text: 'Срок' }), sel),
    h('label', { style: 'display:flex;gap:8px;align-items:center;margin-bottom:6px' }, from, h('span', { text: 'Считать от текущей даты окончания (иначе — от сегодня)' })),
    h('div', { class: 'mfoot' }, h('button', { class: 'btn', text: 'Отмена', onclick: () => m.close() }),
      h('button', { class: 'btn primary', text: 'Применить', onclick: async () => {
        try { await api('POST', `/api/routers/${r.id}/clients/${encodeURIComponent(c.name)}/expiry`, { days: Number(sel.value), extend: from.checked }); m.close(); toast('Срок обновлён'); done(); } catch (e) { toast(e.message, true); }
      } })),
  ]);
}

function clientForm(r, done) {
  const f = {
    name: h('input', { placeholder: 'ivanov-phone', maxlength: 32, required: true }),
    note: h('input', { placeholder: 'необязательно (например, устройство)' }),
    days: h('select', {}, [['', 'бессрочно'], ['30', '30 дней'], ['90', '90 дней'], ['180', '180 дней'], ['365', '365 дней']].map(([v, t]) => h('option', { value: v, text: t }))),
    pub: h('input', { placeholder: 'публичный ключ клиента (44 символа, оканчивается на =)', class: 'mono' }),
  };
  const own = h('input', { type: 'checkbox', style: 'width:auto' });
  const pubWrap = h('label', { class: 'field', style: 'display:none' }, h('span', { text: 'Публичный ключ клиента' }), f.pub);
  own.addEventListener('change', () => { pubWrap.style.display = own.checked ? '' : 'none'; });
  const errBox = h('div');
  const m = openModal([
    h('div', { class: 'mhead' }, h('h2', { text: 'Новый клиент · ' + r.name })),
    errBox,
    h('div', { class: 'grid2' },
      h('label', { class: 'field' }, h('span', { text: 'Имя (латиница, цифры, . _ -)' }), f.name),
      h('label', { class: 'field' }, h('span', { text: 'Срок' }), f.days)),
    h('label', { class: 'field' }, h('span', { text: 'Заметка' }), f.note),
    h('label', { style: 'display:flex;gap:8px;align-items:center;margin:4px 0 12px' }, own,
      h('span', { text: 'Ключ создаёт сам клиент (любой роутер или устройство с AmneziaWG) — вставлю только его публичный ключ' })),
    pubWrap,
    h('div', { class: 'mfoot' }, h('button', { class: 'btn', text: 'Отмена', onclick: () => m.close() }),
      h('button', { class: 'btn primary', text: 'Создать', onclick: async (ev) => {
        const btn = ev.currentTarget; btn.disabled = true;
        try {
          const x = await api('POST', `/api/routers/${r.id}/clients`, { name: f.name.value, note: f.note.value, days: f.days.value ? Number(f.days.value) : null, pubkey: own.checked ? f.pub.value : '' });
          m.close(); configModal(x, done);
        } catch (e) { errBox.replaceChildren(h('div', { class: 'alert err', text: e.message })); btn.disabled = false; }
      } })),
  ]);
  f.name.focus();
}

function configModal(x, done) {
  const finish = () => { m.close(); done(); };
  let content;
  if (x.conf) {
    content = [
      h('div', { class: 'mhead' }, h('h2', { text: 'Конфиг клиента «' + x.name + '»' })),
      h('div', { class: 'alert warn', text: 'Конфиг показан один раз: приватный ключ клиента нигде не сохраняется. Скопируй или скачай сейчас.' }),
      h('div', { class: 'qrbox', html: null }),
      h('pre', { class: 'conf', text: x.conf }),
      h('div', { class: 'mfoot' },
        h('button', { class: 'btn', text: 'Готово', onclick: finish }),
        h('button', { class: 'btn', text: 'Скачать .conf', onclick: () => download(x.name + '.conf', x.conf + '\n') }),
        h('button', { class: 'btn primary', text: 'Копировать', onclick: async () => toast((await copyText(x.conf)) ? 'Скопировано' : 'Не удалось скопировать', false) })),
    ];
    content[2].innerHTML = x.qr; // SVG строит сервер из нашего же конфига
  } else {
    content = [
      h('div', { class: 'mhead' }, h('h2', { text: 'Клиент «' + x.name + '» добавлен' })),
      h('p', { class: 'muted', text: 'Введи эти значения в настройках клиента:' }),
      h('pre', { class: 'conf', text: x.info || '' }),
      h('div', { class: 'mfoot' }, h('button', { class: 'btn primary', text: 'Готово', onclick: finish })),
    ];
  }
  const m = openModal(content, { onClose: done });
}

/* ───────── графики ───────── */
function niceMax(v) {
  if (v <= 0) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v))); const n = v / p;
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * p;
}
function drawChart(el, pts, key, color, fmt, isInt) {
  const NS = 'http://www.w3.org/2000/svg';
  const W = Math.max(320, el.clientWidth), H = 210, pl = 54, pr = 12, pt = 14, pb = 26;
  const vals = pts.map((p) => p[key]);
  let max = niceMax(Math.max(...vals, 0));
  const steps = isInt ? (max <= 4 ? Math.max(1, Math.ceil(max)) : 3) : 3;
  if (isInt) max = Math.max(1, Math.ceil(max / steps) * steps);
  const X = (i) => pl + (pts.length > 1 ? (i * (W - pl - pr)) / (pts.length - 1) : 0);
  const Y = (v) => pt + (H - pt - pb) * (1 - v / max);
  const s = document.createElementNS(NS, 'svg'); s.setAttribute('viewBox', `0 0 ${W} ${H}`); s.setAttribute('width', W); s.setAttribute('height', H);
  const mk = (tag, attrs, text) => { const e = document.createElementNS(NS, tag); for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v); if (text != null) e.textContent = text; s.append(e); return e; };
  for (let i = 0; i <= steps; i++) {
    const y = pt + ((H - pt - pb) * i) / steps;
    mk('line', { x1: pl, x2: W - pr, y1: y, y2: y, stroke: 'var(--line)', 'stroke-width': 1 });
    mk('text', { x: pl - 8, y: y + 4, 'text-anchor': 'end', fill: 'var(--mut)', 'font-size': 11 }, fmt(max * (1 - i / steps)));
  }
  if (pts.length) {
    [0, Math.floor(pts.length / 2), pts.length - 1].forEach((i, n) => mk('text', { x: X(i), y: H - 7, 'text-anchor': n === 0 ? 'start' : n === 2 ? 'end' : 'middle', fill: 'var(--mut)', 'font-size': 11 }, hm(pts[i].t)));
    const line = pts.map((p, i) => (i ? 'L' : 'M') + X(i).toFixed(1) + ' ' + Y(p[key]).toFixed(1)).join(' ');
    const id = 'g' + key;
    const defs = mk('defs', {}); const g = document.createElementNS(NS, 'linearGradient'); g.setAttribute('id', id); g.setAttribute('x1', 0); g.setAttribute('x2', 0); g.setAttribute('y1', 0); g.setAttribute('y2', 1);
    g.innerHTML = `<stop offset="0" stop-color="${color}" stop-opacity=".35"/><stop offset="1" stop-color="${color}" stop-opacity="0"/>`; defs.append(g);
    mk('path', { d: line + ` L${X(pts.length - 1)} ${H - pb} L${X(0)} ${H - pb} Z`, fill: `url(#${id})` });
    mk('path', { d: line, fill: 'none', stroke: color, 'stroke-width': 2, 'stroke-linejoin': 'round' });
  }
  const vline = mk('line', { y1: pt, y2: H - pb, stroke: 'var(--mut)', 'stroke-dasharray': '3 3', visibility: 'hidden' });
  const dot = mk('circle', { r: 4, fill: color, visibility: 'hidden' });
  const tip = h('div', { class: 'tip', style: 'display:none' });
  el.replaceChildren(s, tip);
  s.addEventListener('mousemove', (e) => {
    if (!pts.length) return;
    const rect = s.getBoundingClientRect(); const x = (e.clientX - rect.left) * (W / rect.width);
    const i = Math.max(0, Math.min(pts.length - 1, Math.round(((x - pl) / (W - pl - pr)) * (pts.length - 1))));
    vline.setAttribute('x1', X(i)); vline.setAttribute('x2', X(i)); vline.setAttribute('visibility', 'visible');
    dot.setAttribute('cx', X(i)); dot.setAttribute('cy', Y(pts[i][key])); dot.setAttribute('visibility', 'visible');
    tip.style.display = ''; tip.style.left = X(i) * (rect.width / W) + 'px'; tip.style.top = Y(pts[i][key]) * (rect.height / H) + 'px';
    tip.textContent = dfull(pts[i].t) + ' · ' + fmt(pts[i][key]);
  });
  s.addEventListener('mouseleave', () => { vline.setAttribute('visibility', 'hidden'); dot.setAttribute('visibility', 'hidden'); tip.style.display = 'none'; });
}

/* ───────── вид «Обзор» ───────── */
let range = '24h';
async function viewOverview() {
  const stats = h('div', { class: 'stats' });
  const c1 = h('div', { class: 'chart' }), c2 = h('div', { class: 'chart' });
  const tR = h('div'), tC = h('div');
  const rangeBtns = h('div', { class: 'ranges' }, ['3h', '6h', '12h', '24h', '7d', '30d', '90d'].map((r) =>
    h('button', { class: 'btn sm' + (r === range ? ' on' : ''), text: r.replace('h', ' ч').replace('d', ' д'), onclick: () => { range = r; rangeBtns.querySelectorAll('button').forEach((b, i) => b.classList.toggle('on', ['3h', '6h', '12h', '24h', '7d', '30d', '90d'][i] === r)); loadStats(); } })));
  view.replaceChildren(
    h('div', { class: 'page-head' }, h('h1', { class: 'page', text: 'Обзор' }), h('span', { class: 'spacer' }), rangeBtns, h('button', { class: 'btn sm', text: 'Обновить', onclick: loadAll })),
    stats,
    h('div', { class: 'card' }, h('h2', { text: 'Трафик за период' }), c1),
    h('div', { class: 'card' }, h('h2', { text: 'Клиенты в сети' }), c2),
    h('div', { class: 'card' }, h('h2', { text: 'Роутеры' }), tR),
    h('div', { class: 'card' }, h('h2', { text: 'Топ клиентов по трафику' }), tC));
  let pts = [];
  async function loadStats() {
    try { pts = (await api('GET', '/api/stats?range=' + range)).points; } catch (e) { toast(e.message, true); return; }
    drawChart(c1, pts, 'bytes', '#3d66f5', bytes);
    drawChart(c2, pts, 'online', '#2fd488', (v) => String(Math.round(v)), true);
  }
  async function loadAll() {
    try {
      const o = await api('GET', '/api/overview');
      stats.replaceChildren(
        h('div', { class: 'stat' }, h('div', { class: 'big' }, o.routers_online, h('small', { text: ' / ' + o.routers_total })), h('div', { class: 'lbl', text: 'роутеров в сети' })),
        h('div', { class: 'stat' }, h('div', { class: 'big' }, o.clients_online, h('small', { text: ' / ' + o.clients_total })), h('div', { class: 'lbl', text: 'клиентов в сети' })),
        h('div', { class: 'stat' }, h('div', { class: 'big mono', style: 'font-size:22px' }, '↓ ' + bytes(o.rx), h('br'), '↑ ' + bytes(o.tx)), h('div', { class: 'lbl', text: 'трафик с момента запуска интерфейсов' })));
      tR.replaceChildren(o.routers.length ? h('table', { class: 't resp' },
        h('thead', {}, h('tr', {}, h('th', { text: 'Роутер' }), h('th', { text: 'Статус' }), h('th', { text: 'Клиенты' }), h('th', { text: 'Трафик (↓ / ↑)' }))),
        h('tbody', {}, o.routers.map((r) => h('tr', {},
          h('td', { 'data-l': 'Роутер' }, h('a', { href: '#/routers', text: r.name })),
          h('td', { 'data-l': 'Статус' }, h('span', { style: 'display:inline-flex;gap:7px;align-items:center' }, h('span', { class: 'dot ' + (r.state === 'online' ? 'on' : r.state === 'offline' ? 'off' : 'warn') }), r.state === 'online' ? 'в сети' : r.state === 'no_script' ? 'нет скрипта' : r.state === 'offline' ? 'нет связи' : '…')),
          h('td', { 'data-l': 'Клиенты', class: 'mono', text: r.state === 'online' ? r.clients_online + ' / ' + r.clients_total : '—' }),
          h('td', { 'data-l': 'Трафик', class: 'mono sub', text: r.state === 'online' ? bytes(r.rx) + ' / ' + bytes(r.tx) : '—' }))))) : h('div', { class: 'empty', text: 'Нет роутеров' }));
      tC.replaceChildren(o.top.length ? h('table', { class: 't resp' },
        h('thead', {}, h('tr', {}, h('th', { text: 'Клиент' }), h('th', { text: 'Роутер' }), h('th', { text: 'Трафик (↓ / ↑)' }), h('th', { class: 'r', text: 'Всего' }))),
        h('tbody', {}, o.top.map((c) => h('tr', {},
          h('td', { 'data-l': 'Клиент', text: c.name }), h('td', { 'data-l': 'Роутер', class: 'sub', text: c.router }),
          h('td', { 'data-l': 'Трафик', class: 'mono sub', text: '↓ ' + bytes(c.rx) + ' · ↑ ' + bytes(c.tx) }),
          h('td', { 'data-l': 'Всего', class: 'r mono', text: bytes(c.total) }))))) : h('div', { class: 'empty', text: 'Пока нет данных' }));
    } catch (e) { toast(e.message, true); }
    loadStats();
  }
  await loadAll();
  timer = setInterval(loadAll, 60000);
  window.onresize = () => { if (pts.length) { drawChart(c1, pts, 'bytes', '#3d66f5', bytes); drawChart(c2, pts, 'online', '#2fd488', (v) => String(Math.round(v)), true); } };
}

/* ───────── вид «Журнал» ───────── */
async function viewLog() {
  const card = h('div', { class: 'card' }, h('div', { class: 'empty', text: 'Загрузка…' }));
  view.replaceChildren(h('div', { class: 'page-head' }, h('h1', { class: 'page', text: 'Журнал' })), card);
  try {
    const { events } = await api('GET', '/api/events');
    card.replaceChildren(events.length ? h('table', { class: 't' },
      h('thead', {}, h('tr', {}, h('th', { text: 'Время' }), h('th', { text: 'Событие' }))),
      h('tbody', {}, events.map((e) => h('tr', {}, h('td', { class: 'sub mono', style: 'white-space:nowrap', text: dfull(e.ts) }), h('td', { text: e.text }))))) : h('div', { class: 'empty', text: 'Записей пока нет' }));
  } catch (e) { card.replaceChildren(h('div', { class: 'alert err', text: e.message })); }
}

route();
})();
