// v47 — off-in-lieu must say when it dies, wherever it is shown.
//
// Asked for: "the off in lieu expiry date for all emp should check the company offin
// liew expiry setting ... it will expired yearly at a specific date, but the date is
// changable under the company setting. and it must always be updated."
//
// Before this, the off-in-lieu expiry date existed ONLY on HR's Company settings tab.
// Nobody saw it next to their own balance -- while carry-forward annual leave has said
// "Expiry Date: 31 Dec 2026" on three screens since v24. So off-in-lieu could be
// forfeited in full, on a date nobody had been shown.
//
// The date is DERIVED from the company setting on every render, never stored per
// employee. That is what makes "it must always be updated" true by construction:
// there is no second copy to go stale.
//
// The rule, confirmed: the forfeit itself looks BACKWARD (a date already gone this
// year forfeits now, as of that date) and that is unchanged. What is shown is the NEXT
// occurrence, because that is the date an employee needs in order to use the days in
// time.
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
let pass = 0, fail = 0, failed = [], errs = [];
const ok = (n, c, extra = '') => { if (c) { pass++; console.log('  ✓', n); } else { fail++; failed.push(n); console.log('  ✗', n, extra); } };
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const pg = await b.newPage({ viewport: { width: 1300, height: 950 } });
pg.on('pageerror', e => errs.push(e.message));
await pg.goto('file://' + HERE + '../app.html');
await pg.waitForFunction(() => typeof render === 'function');
await pg.addScriptTag({ content: fs.readFileSync(HERE + 'seed.js', 'utf8') });
const seed = o => pg.evaluate(x => __seed(x), o);

// 4 off-in-lieu days earned, and a company expiry date of [month, day].
const scenario = (md, view) => pg.evaluate(([m, v]) => {
  __seed({ view: v, oilMD: m });
  db.applications = []; db.ledgerTagged = true;
  db.ledger = [{ id: 1, empId: 'e2', type: 'oil', delta: 4, reason: 'Off-in-lieu earned',
                 ts: Date.parse('2026-02-01'), year: 2026, kind: 'adjust' }];
  render();
  return null;
}, [md, view]);
const text = () => pg.evaluate(() => document.body.innerText.replace(/\s+/g, ' '));

console.log('\n§1 the date is on the screens where off-in-lieu is shown');
// 25 Dec has NOT passed (the seeded "today" is in 2026), so the next one is this year.
await scenario([12, 25], 'profile');
let t = await text();
ok('My leave entitlement shows it', /Off-in-Lieu/.test(t) && /25 Dec 2026/.test(t),
   JSON.stringify((t.match(/Off-in-Lieu[^]{0,60}/) || [''])[0]));
await scenario([12, 25], 'dashboard');
t = await text();
ok('the dashboard tile shows it', /25 Dec 2026/.test(t),
   JSON.stringify((t.match(/Off-in-Lieu[^]{0,80}/) || [''])[0]));
await pg.evaluate(() => { vp.form = { type: 'oil', start: '', end: '', half: {} }; view = 'apply'; render(); });
t = await text();
ok('the Apply screen shows it when off-in-lieu is picked', /25 Dec 2026/.test(t),
   JSON.stringify((t.match(/Available Balance[^]{0,140}/) || [''])[0]));

console.log('\n§2 a date already gone this year shows NEXT year');
// The forfeit for 10 Sep 2026 has already happened; days earned now die on 10 Sep 2027.
await scenario([9, 10], 'profile');
t = await text();
ok('it shows 10 Sep 2027, not 2026', /10 Sep 2027/.test(t) && !/10 Sep 2026/.test(t),
   JSON.stringify((t.match(/Off-in-Lieu[^]{0,60}/) || [''])[0]));

console.log('\n§3 the day itself shows today, not next year');
const todayMD = await pg.evaluate(() => [new Date().getMonth() + 1, new Date().getDate()]);
await scenario(todayMD, 'profile');
t = await text();
const todayStr = await pg.evaluate(() => fmtDateY(new Date().toISOString().slice(0, 10)));
ok('today is the expiry date shown', t.includes(todayStr), JSON.stringify([todayStr, (t.match(/Off-in-Lieu[^]{0,60}/) || [''])[0]]));

console.log('\n§4 no date set means it never expires — said out loud, not left blank');
await scenario(null, 'profile');
t = await text();
ok('it says N/A rather than showing nothing', /Off-in-Lieu/.test(t) && /N\/A/.test(t),
   JSON.stringify((t.match(/Off-in-Lieu[^]{0,60}/) || [''])[0]));

console.log('\n§5 it follows the company setting, with no stored copy to go stale');
// Change the setting and re-render: every screen must move. This is the whole of
// "it must always be updated".
await scenario([12, 25], 'profile');
ok('before: 25 Dec 2026', /25 Dec 2026/.test(await text()));
await pg.evaluate(() => { db.org.oilExpiryMonth = 3; db.org.oilExpiryDay = 31; render(); });
t = await text();
ok('after changing the setting: 31 Mar 2027', /31 Mar 2027/.test(t) && !/25 Dec 2026/.test(t),
   JSON.stringify((t.match(/Off-in-Lieu[^]{0,60}/) || [''])[0]));
const stored = await pg.evaluate(() =>
  JSON.stringify(db.employees.map(e => Object.keys(e).filter(k => /oil/i.test(k)))));
ok('and no employee record carries its own copy of the date', stored === '[[],[]]', stored);

console.log('\n§6 a database without the off-in-lieu feature is unaffected');
await pg.evaluate(() => { __seed({ view: 'profile', noV36: true }); render(); });
t = await text();
ok('no expiry line is invented', !/Off-in-Lieu[^]{0,40}Expiry/.test(t));
ok('and the page still renders', t.length > 100);

console.log(`\n${pass} passed, ${fail} failed` + (fail ? '\n  ' + failed.join('\n  ') : ''));
if (errs.length) console.log('page errors: ' + errs.join(' | '));
await b.close();
process.exit(fail || errs.length ? 1 : 0);
