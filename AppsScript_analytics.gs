/**
 * The Unspoken Gift — lightweight first-party analytics
 * ------------------------------------------------------
 * ONE web app does two jobs:
 *   • POST  (from the website)  → append a funnel event to the "Events" sheet
 *   • GET   (you, in a browser) → a live funnel dashboard at the same /exec URL
 *
 * The time-range buttons (近1天/近7天/近30天) switch client-side — no page reload,
 * no ?range in the URL. All three windows are computed up front and toggled with JS.
 *
 * Setup: create a Google Sheet → Extensions → Apps Script → paste this → Save →
 * Deploy → Web app → Execute as Me, Who has access: Anyone → Deploy. View = open the /exec URL.
 */

const A_TOKEN = 'tug-a-8f3';   // must match ANALYTICS_TOKEN on the website
const A_SHEET = 'Events';
const VIEW_KEY = '';           // optional: set a secret, then view with ?key=THAT (empty = open)

const FUNNEL = [
  ['page_view',      '进站'],
  ['scroll_deep',    '认真浏览（滚动过 60%）'],
  ['occasion_open',  '点开场合'],
  ['product_view',   '查看礼盒'],
  ['add_to_cart',    '加入购物车'],
  ['cart_open',      '打开购物车'],
  ['checkout_click', '点击下单'],
  ['order_submit',   '完成下单（跳 WhatsApp）']
];

// ── ingest ──────────────────────────────────────────────
function doPost(e) {
  try {
    const d = JSON.parse(e.postData.contents);
    if (d.token !== A_TOKEN) return _json({ ok: false });
    _sheet().appendRow([
      new Date(),
      String(d.name || '').slice(0, 40),
      String(d.label || '').slice(0, 80),
      String(d.sid || '').slice(0, 40),
      String(d.lang || '').slice(0, 6),
      String(d.dev || '').slice(0, 2),
      String(d.ref || '').slice(0, 160)
    ]);
    return _json({ ok: true });
  } catch (err) {
    return _json({ ok: false });
  }
}

// ── dashboard ───────────────────────────────────────────
function doGet(e) {
  const p = (e && e.parameter) || {};
  if (VIEW_KEY && p.key !== VIEW_KEY) {
    return HtmlService.createHtmlOutput('<p style="font-family:sans-serif">需要访问密钥。</p>');
  }
  const rows = _rows();
  const data = { 1: _agg(rows, 1), 7: _agg(rows, 7), 30: _agg(rows, 30) };
  return HtmlService.createHtmlOutput(_render(data))
    .setTitle('The Unspoken Gift — 访问漏斗')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1');
}

function _rows() {
  const sh = _sheet();
  const last = sh.getLastRow();
  return last > 1 ? sh.getRange(2, 1, last - 1, 7).getValues() : [];
}

function _agg(rows, days) {
  const cutoff = new Date().getTime() - days * 86400000;
  const stepSids = {};
  FUNNEL.forEach(f => stepSids[f[0]] = {});
  const occ = {}, prod = {}, ref = {}, dev = {}, allSids = {};
  let total = 0;
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    const t = r[0] instanceof Date ? r[0].getTime() : new Date(r[0]).getTime();
    if (!(t >= cutoff)) continue;
    const name = r[1], label = r[2], sid = r[3] || '?', device = r[5], referrer = r[6];
    total++;
    allSids[sid] = 1;
    if (stepSids[name]) stepSids[name][sid] = 1;
    if (name === 'occasion_open' && label) (occ[label] = occ[label] || {})[sid] = 1;
    if (name === 'product_view' && label) (prod[label] = prod[label] || {})[sid] = 1;
    if (name === 'page_view') {
      const rr = referrer ? _host(referrer) : '（直接进入 / 收藏）';
      (ref[rr] = ref[rr] || {})[sid] = 1;
      const dv = device === 'm' ? '手机' : (device === 'd' ? '电脑' : '未知');
      (dev[dv] = dev[dv] || {})[sid] = 1;
    }
  }
  const count = o => Object.keys(o).length;
  const topOf = (m, k) => Object.keys(m).map(x => ({ x: x, n: count(m[x]) }))
    .sort((a, b) => b.n - a.n).slice(0, k);
  return {
    steps: FUNNEL.map(f => ({ label: f[1], n: count(stepSids[f[0]]) })),
    sessions: count(allSids),
    events: total,
    devices: topOf(dev, 5),
    occ: topOf(occ, 6),
    prod: topOf(prod, 6),
    ref: topOf(ref, 6)
  };
}

// one window's body (tiles + funnel + lists)
function _pane(a) {
  const top = a.steps.length ? Math.max(1, a.steps[0].n) : 1;
  const pv = a.steps[0] ? a.steps[0].n : 0;
  let funnel = '';
  a.steps.forEach((s, i) => {
    const w = Math.round((s.n / top) * 100);
    const pct = pv ? Math.round((s.n / pv) * 100) : 0;
    const prev = i > 0 ? a.steps[i - 1].n : s.n;
    const drop = (i > 0 && prev > 0) ? Math.round(((prev - s.n) / prev) * 100) : 0;
    funnel +=
      '<div class="row"><div class="lab">' + s.label + '</div>' +
      '<div class="barwrap"><div class="bar" style="width:' + Math.max(w, 2) + '%"></div>' +
      '<span class="num">' + s.n + '</span></div>' +
      '<div class="pct">' + pct + '%' + (i > 0 ? ' <span class="drop">▼' + drop + '%</span>' : '') + '</div></div>';
  });
  const list = (title, arr) => {
    if (!arr.length) return '';
    let h = '<div class="card"><h3>' + title + '</h3><table>';
    arr.forEach(r => h += '<tr><td>' + _esc(r.x) + '</td><td class="n">' + r.n + '</td></tr>');
    return h + '</table></div>';
  };
  return '<div class="tiles">' +
    '<div class="tile"><div class="big">' + a.sessions + '</div><div class="cap">独立访客</div></div>' +
    '<div class="tile"><div class="big">' + (a.steps[7] ? a.steps[7].n : 0) + '</div><div class="cap">完成下单</div></div>' +
    '<div class="tile"><div class="big">' + a.events + '</div><div class="cap">总事件数</div></div></div>' +
    '<div class="card"><h3>转化漏斗（百分比 = 占「进站」比例）</h3>' +
    (pv ? funnel : '<p style="color:#8a7a68;font-size:.85rem">这个时间段还没有数据。</p>') + '</div>' +
    list('最受关注的场合', a.occ) + list('最受关注的礼盒', a.prod) +
    list('访客来源', a.ref) + list('设备', a.devices);
}

function _render(data) {
  const btn = (n, on) => '<button class="rl' + (on ? ' on' : '') + '" data-r="' + n + '" onclick="showR(' + n + ')">近 ' + n + ' 天</button>';
  return '<!doctype html><meta charset="utf-8"><style>' +
    ':root{--gold:#6E4F31;--deep:#2A2017;--blush:#FAF5EF;--line:#EADFD2}' +
    'body{margin:0;background:var(--blush);color:var(--deep);font-family:-apple-system,"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif;padding:20px 14px 60px}' +
    '.wrap{max-width:720px;margin:0 auto}h1{font-size:1.25rem;margin:0 0 2px}.sub{color:#8a7a68;font-size:.82rem;margin:0 0 16px}' +
    '.ranges{margin:0 0 18px}.rl{font:inherit;background:#fff;cursor:pointer;padding:6px 14px;border:1px solid var(--line);border-radius:100px;margin-right:8px;color:var(--gold);font-size:.82rem}.rl.on{background:var(--gold);color:#fff;border-color:var(--gold)}' +
    '.tiles{display:flex;gap:10px;margin:0 0 20px;flex-wrap:wrap}.tile{flex:1;min-width:130px;background:#fff;border:1px solid var(--line);border-radius:14px;padding:14px 16px}.tile .big{font-size:1.6rem;font-weight:700}.tile .cap{font-size:.75rem;color:#8a7a68}' +
    '.card{background:#fff;border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin:0 0 16px}h3{font-size:.92rem;margin:0 0 10px}' +
    '.row{display:flex;align-items:center;gap:10px;margin:7px 0}.lab{width:34%;font-size:.8rem}.barwrap{flex:1;background:#F1E9DF;border-radius:8px;position:relative;height:26px}' +
    '.bar{background:linear-gradient(90deg,#C79A5B,#6E4F31);height:100%;border-radius:8px;min-width:2%}' +
    '.num{position:absolute;right:8px;top:4px;font-size:.8rem;font-weight:700;color:var(--deep)}' +
    '.pct{width:74px;text-align:right;font-size:.8rem}.drop{color:#b4553e;font-size:.72rem}' +
    'table{width:100%;border-collapse:collapse;font-size:.82rem}td{padding:5px 0;border-bottom:1px solid #f0e8dd}td.n{text-align:right;font-weight:700;width:50px}' +
    '.foot{color:#a99b89;font-size:.72rem;text-align:center;margin-top:10px}' +
    '</style><div class="wrap">' +
    '<h1>The Unspoken Gift · 访问漏斗</h1><p class="sub">数据来自你自己的表 · 每次刷新即时统计</p>' +
    '<div class="ranges">' + btn(1, false) + btn(7, true) + btn(30, false) + '</div>' +
    '<div class="pane" id="p1" style="display:none">' + _pane(data[1]) + '</div>' +
    '<div class="pane" id="p7">' + _pane(data[7]) + '</div>' +
    '<div class="pane" id="p30" style="display:none">' + _pane(data[30]) + '</div>' +
    '<p class="foot">© The Unspoken Gift · 无 cookie · 数据仅存于你的 Google 表</p>' +
    '</div>' +
    '<script>function showR(n){[1,7,30].forEach(function(x){document.getElementById("p"+x).style.display=(x===n?"":"none");});' +
    'var bs=document.getElementsByClassName("rl");for(var i=0;i<bs.length;i++){var on=(parseInt(bs[i].getAttribute("data-r"),10)===n);bs[i].className=on?"rl on":"rl";}}<\/script>';
}

// ── helpers ─────────────────────────────────────────────
function _sheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(A_SHEET);
  if (!sh) {
    sh = ss.insertSheet(A_SHEET);
    sh.getRange(1, 1, 1, 7).setValues([['时间 Time', '事件 Event', '标签 Label', '会话 Session', '语言 Lang', '设备 Device', '来源 Referrer']]).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  return sh;
}
function _host(u) { try { return String(u).replace(/^https?:\/\//, '').split('/')[0]; } catch (e) { return u; } }
function _esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function _json(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
