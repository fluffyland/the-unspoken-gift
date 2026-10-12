// ===========================================================================
// LEAVE CHECK — every place a remaining balance appears must come from one
// source, and must be refreshed by every action that changes it.
//
// Reported: "I notice some will not reflected and update even leave credited ...
// let's list down all the place that will show their remaining leave and we have to
// make sure everytime people edited leave (apply, taken, cancel, credit by hr) the
// leave will updated in all the places."
//
// Two separate failures hide behind one symptom, and only the second was real:
//
//   1. A screen computing the balance its own way, so it drifts from the others.
//      That is what v40/v41 were: the carry-forward days were counted twice on
//      the Balances tab and again on My details. The guard against it recurring
//      is below -- one change to the ledger, and EVERY site must move by the
//      same amount, because they all call bal().
//
//   2. Nothing refreshes a screen somebody else is looking at. Every one of the
//      app's 51 write paths does refetch -- that was audited -- so within your
//      own session the numbers are right. But when HR credits off-in-lieu, the
//      employee's open tab keeps showing the old figure until they reload the
//      whole page by hand. There was no focus refresh, no polling, no realtime,
//      and no refresh button. THAT is what was being seen.
// ===========================================================================
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
let pass = 0, fail = 0, failed = [], errs = [];
const ok = (n, c, extra = '') => { if (c) { pass++; console.log('  ✓', n); } else { fail++; failed.push(n); console.log('  ✗', n, extra); } };
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const pg = await b.newPage({ viewport: { width: 1340, height: 980 } });
pg.on('pageerror', e => errs.push(e.message));
await pg.goto('file://' + HERE + '../app.html');
await pg.waitForFunction(() => typeof render === 'function');
await pg.addScriptTag({ content: fs.readFileSync(HERE + 'seed.js', 'utf8') });

// Barbie (e2) holds `days` of sick leave out of 14. Sick leave is used rather than
// annual on purpose: no carry-forward to complicate the arithmetic, so a drift
// between two screens can only be a drift.
// Captured BEFORE section 5 replaces loadAll with a counter: reading it afterwards
// would be reading the stub, which is how the first version of section 8 managed to
// fail against correct code and pass against the mutant.
const loadAllSrc = await pg.evaluate(() => loadAll.toString());

const setup = (taken, asHr) => pg.evaluate(([t, hr]) => {
  __seed({ asHr: hr, view: hr ? 'hr' : 'dashboard', hrTab: hr ? 'balances' : undefined });
  db.applications = []; db.ledgerTagged = true;
  db.ledger = [
    { id: 1, empId: 'e2', type: 'sick', delta: 14, reason: '2026 annual allowance',
      ts: Date.parse('2026-01-02'), year: 2026, kind: 'grant' }
  ];
  if (t) db.ledger.push({ id: 2, empId: 'e2', type: 'sick', delta: -t, refApp: 'x',
      reason: 'Leave taken', ts: Date.parse('2026-03-02'), year: 2026, kind: 'taken' });
  render();
}, [taken, asHr]);

// Read the sick-leave figure off each screen, as the employee sees it.
async function employeeSites() {
  const out = {};
  await pg.evaluate(() => { view = 'dashboard'; render(); });
  out.overviewTile = await pg.evaluate(() => {
    const el = [...document.querySelectorAll('.bal')].find(x => /Sick Leave/.test(x.textContent));
    return el ? Number((el.innerText.match(/([\d.]+)\s*days left/) || [])[1]) : null; });
  await pg.evaluate(() => { view = 'profile'; render(); });
  out.myDetails = await pg.evaluate(() => {
    const tr = [...document.querySelectorAll('table tr')].find(r => r.querySelector('td') && /^Sick Leave/.test(r.querySelector('td').textContent.trim()));
    return tr ? Number([...tr.querySelectorAll('td')].pop().textContent.trim()) : null; });
  await pg.evaluate(() => { view = 'apply'; vp.form = { type: 'sick', start: '', end: '', half: {} }; render(); });
  out.applyScreen = await pg.evaluate(() => {
    const m = document.body.innerText.match(/Available Balance:\s*([\d.]+)/); return m ? Number(m[1]) : null; });
  out.balFunction = await pg.evaluate(() => bal('e2', 'sick').avail);
  return out;
}

console.log('\n§1 the employee-facing screens all agree, with nothing taken');
await setup(0, false);
let s = await employeeSites();
ok('Overview tile, My details, Apply and bal() all say 14',
   new Set(Object.values(s)).size === 1 && s.balFunction === 14, JSON.stringify(s));

console.log('\n§2 three days taken: every screen moves by three, together');
await setup(3, false);
s = await employeeSites();
ok('all four now say 11', new Set(Object.values(s)).size === 1 && s.balFunction === 11, JSON.stringify(s));

console.log('\n§3 the HR-facing screens agree with the employee-facing ones');
await setup(3, true);
const hr = await pg.evaluate(() => {
  const out = {};
  const tr = [...document.querySelectorAll('table tr')].find(r => /Barbie Girl/.test(r.textContent));
  const cells = tr ? [...tr.querySelectorAll('td')].map(td => td.textContent.trim()) : [];
  out.balancesTab = Number((cells.find(c => /^\d+(\.\d+)? \/ 14$/.test(c)) || '').split(' / ')[0]);
  let csv = null; const real = window.csvDownload;
  window.csvDownload = (n, rows) => { csv = rows; }; runAction({ dataset: { act: 'balcsv' } }); window.csvDownload = real;
  const head = csv[0].indexOf('Sick Leave left');
  out.csvExport = Number(csv.find(r => r[0] === 'Barbie Girl')[head]);
  out.balFunction = bal('e2', 'sick').avail;
  return out;
});
ok('Balances tab, CSV export and bal() all say 11',
   new Set(Object.values(hr)).size === 1 && hr.balFunction === 11, JSON.stringify(hr));

console.log('\n§4 no screen invents its own arithmetic');
// Every site must read bal(). If one computed from db.ledger or db.applications
// directly it would survive this: bal() is replaced wholesale and every figure on
// screen has to follow it.
await setup(3, false);
const hijacked = await pg.evaluate(() => {
  const real = bal;
  // eslint-disable-next-line no-global-assign
  bal = (e, c) => Object.assign(real(e, c), { avail: 99 });
  const got = {};
  view = 'dashboard'; render();
  const el = [...document.querySelectorAll('.bal')].find(x => /Sick Leave/.test(x.textContent));
  got.tile = el ? (el.innerText.match(/([\d.]+)\s*days left/) || [])[1] : null;
  view = 'profile'; render();
  const tr = [...document.querySelectorAll('table tr')].find(r => r.querySelector('td') && /^Sick Leave/.test(r.querySelector('td').textContent.trim()));
  got.details = tr ? [...tr.querySelectorAll('td')].pop().textContent.trim() : null;
  view = 'apply'; vp.form = { type: 'sick', start: '', end: '', half: {} }; render();
  got.apply = (document.body.innerText.match(/Available Balance:\s*([\d.]+)/) || [])[1];
  bal = real;
  return got;
});
ok('all three follow bal() when it is replaced', hijacked.tile === '99' && hijacked.details === '99' && hijacked.apply === '99',
   JSON.stringify(hijacked));

console.log('\n§5 coming back to the tab refetches — the cross-session fix');
await setup(3, false);
let loads = await pg.evaluate(() => {
  window.__loads = 0;
  window.loadAll = async () => { window.__loads++; };
  // A tab just loaded needs nothing: refetching on every focus would fire a query
  // every time somebody alt-tabs, which is noise on a free-tier database.
  document.dispatchEvent(new Event('visibilitychange'));
  const whenFresh = window.__loads;
  // Now the tab has been sitting open — this is the reported case.
  lastLoadAt = Date.now() - 10 * 60 * 1000;
  document.dispatchEvent(new Event('visibilitychange'));
  return [whenFresh, window.__loads];
});
ok('a tab that just loaded does NOT refetch on focus', loads[0] === 0, 'calls: ' + loads[0]);
ok('a tab left open DOES refetch when looked at again', loads[1] > 0, 'calls: ' + loads[1]);

console.log('\n§6 but NOT while something is half-typed');
// A refresh rebuilds the page from server data. Doing that while HR is mid-way
// through a form throws their typing away, which is worse than a stale number.
const guarded = await pg.evaluate(() => {
  window.__loads = 0;
  window.loadAll = async () => { window.__loads++; };
  vp.draft = { org: { company: 'half typed' } };          // an unsaved edit
  document.dispatchEvent(new Event('visibilitychange'));
  window.dispatchEvent(new Event('focus'));
  const during = window.__loads;
  delete vp.draft;
  return during;
});
ok('an unsaved draft blocks the auto-refresh', guarded === 0, 'loadAll calls: ' + guarded);

console.log('\n§7 and there is a way to force it, with the data age on screen');
await setup(3, false);
const chrome = await pg.evaluate(() => ({
  hasButton: !!document.querySelector('[data-act="refreshnow"]'),
  saysWhen: /as of \d|Updated \d|just now/i.test(document.body.innerText)
}));
ok('a Refresh control exists', chrome.hasButton);
ok('and the page says how fresh the figures are', chrome.saysWhen,
   JSON.stringify((await pg.evaluate(() => document.body.innerText.slice(0, 200)))));

console.log('\n§8 the clock is actually wound by the real fetch');
// __seed() stamps lastLoadAt because it stands in for loadAll(), which means the
// stamp inside loadAll() itself is never exercised by the tests above -- a mutation
// run proved it: deleting it changed nothing here. Without it lastLoadAt stays 0
// forever, so the label never shows a time and every single focus refetches.
// Checked at the source, because the real loadAll() needs a Supabase to run.
const inLoadAll = /lastLoadAt\s*=\s*Date\.now\(\)/.test(loadAllSrc);
const atTheEnd = loadAllSrc.lastIndexOf('lastLoadAt') > loadAllSrc.length - 400;
ok('loadAll() stamps lastLoadAt', inLoadAll, loadAllSrc.slice(-160));
ok('and does it at the end, after the data has landed', inLoadAll && atTheEnd, loadAllSrc.slice(-160));

console.log(`\n${pass} passed, ${fail} failed` + (fail ? '\n  ' + failed.join('\n  ') : ''));
if (errs.length) console.log('page errors: ' + errs.join(' | '));
await b.close();
process.exit(fail || errs.length ? 1 : 0);
