// v36 — the Off-in-Lieu expiry date control, on the Company settings tab.
//
// It sits next to the Carry Forward AL one and looks the same, but the RULE is not the
// same, and the screen has to say so: carried annual leave loses only LAST year's
// leftover, off-in-lieu loses the WHOLE balance. Somebody who assumes they match will
// take days off their staff by accident.
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
const APP = HERE + '../app.html';
let pass = 0, fail = 0, errs = [], failed = [];
const ok = (n, c, extra = '') => { if (c) { pass++; console.log('  ✓', n); } else { fail++; failed.push(n); console.log('  ✗', n, extra); } };
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const pg = await b.newPage({ viewport: { width: 1280, height: 950 } });
pg.on('pageerror', e => { errs.push(e.message); console.log('  !! pageerror:', e.message); });
await pg.goto('file://' + APP);
await pg.waitForFunction(() => typeof render === 'function');
await pg.addScriptTag({ content: fs.readFileSync(HERE + 'seed.js', 'utf8') });
const seed = o => pg.evaluate(x => __seed(x), o);
const act = o => pg.evaluate(x => runAction({ dataset: x }), o);
const fire = (sel, val) => pg.evaluate(([s, v]) => {
  const el = document.querySelector(s); el.value = v;
  el.dispatchEvent(new Event('change', { bubbles: true }));
}, [sel, val]);
async function spy() {
  await pg.evaluate(() => {
    window.__rpc = [];
    sb.rpc = async (fn, a) => { window.__rpc.push([fn, a]);
      return { data: { preview: true, holding: 3, people: 3, days_lost: 7, dying_people: 2,
                       already_expired: 0, new_date: '2026-01-31' }, error: null }; };
    const chain = () => { const p = Promise.resolve({ data: null, error: null });
      p.eq = () => p; p.select = () => ({ single: async () => ({ data: {}, error: null }) }); return p; };
    sb.from = () => ({ update: chain, insert: chain, delete: chain, select: chain });
    window.loadAll = async () => {}; window.reload = async () => {}; window.reloadKeep = async () => {};
  });
}
const rpcs = () => pg.evaluate(() => window.__rpc);
const confirmText = () => pg.evaluate(() => {
  const btn = document.querySelector('[data-act="confirmyes"]');
  return btn ? btn.closest('.modal').textContent.replace(/\s+/g, ' ') : '';
});

console.log('\n§1 the control is there, next to the annual-leave one');
await seed({ asHr: true, hrTab: 'settings' });
let txt = await pg.evaluate(() => document.body.innerText);
ok('Off-in-Lieu expiry date is on Company settings', /Off-in-Lieu expiry date/i.test(txt));
ok('so is Carry Forward AL expiry date', /Carry Forward AL expiry date/i.test(txt));
const order = await pg.evaluate(() => {
  const t = document.body.innerText;
  return [t.indexOf('Off-in-Lieu expiry date'), t.indexOf('Carry Forward AL expiry date')];
});
ok('they are next to each other', Math.abs(order[0] - order[1]) < 600, JSON.stringify(order));
ok('it starts on "Never expires"', /Off-in-lieu\s+never expires/i.test(txt),
   JSON.stringify((txt.match(/Off-in-lieu[^]{0,60}/) || [''])[0]));
const dayDisabled = await pg.evaluate(() => document.querySelector('[data-f="org.oilDay"]').disabled);
ok('and the day box is disabled until a month is picked', dayDisabled === true);

console.log('\n§2 it says how it differs from annual leave');
await fire('[data-f="org.oilMon"]', '1');
await fire('[data-f="org.oilDay"]', '31');
txt = await pg.evaluate(() => document.body.innerText);
ok('the hint names the date', /31 Jan/.test(txt), txt.match(/Off-in-lieu must be used by[^.]*/)?.[0]);
ok('it warns the WHOLE balance goes', /whole balance/i.test(txt));
ok('and contrasts it with carried annual leave', /different from carried annual leave/i.test(txt));

console.log('\n§3 saving asks first, with the database\'s own numbers');
await spy();
await act({ act: 'hrsave' });
let r = await rpcs();
const prev = r.filter(x => x[0] === 'set_oil_expiry' && x[1].p_preview === true);
ok('it previews before writing', prev.length === 1, JSON.stringify(r.map(x => x[0])));
ok('and sends the month and day chosen', prev[0] && prev[0][1].p_month === 1 && prev[0][1].p_day === 31,
   JSON.stringify(prev[0] && prev[0][1]));
ok('nothing was written yet', !r.some(x => x[0] === 'set_oil_expiry' && x[1].p_preview === false));
const cm = await confirmText();
ok('the dialog quotes the real figure it got back', /7 days/.test(cm), cm.slice(0, 200));
ok('it says who is affected', /2 people/.test(cm), cm.slice(0, 200));
ok('it says the days are forfeited immediately', /forfeited immediately/i.test(cm), cm.slice(0, 200));
ok('and repeats the difference from annual leave', /whole off-in-lieu balance/i.test(cm), cm.slice(0, 240));

console.log('\n§4 confirming writes it');
await act({ act: 'hrsaveok' });
r = await rpcs();
const wrote = r.filter(x => x[0] === 'set_oil_expiry' && x[1].p_preview === false);
ok('confirming sends the real write', wrote.length === 1, JSON.stringify(r.map(x => [x[0], x[1].p_preview])));
ok('with the same month and day', wrote[0] && wrote[0][1].p_month === 1 && wrote[0][1].p_day === 31);

console.log('\n§5 a database without the migration still works');
await seed({ asHr: true, hrTab: 'settings', noV36: true });
txt = await pg.evaluate(() => document.body.innerText);
ok('the control is hidden rather than broken', !/Off-in-Lieu expiry date/i.test(txt));
ok('and the annual-leave one still shows', /Carry Forward AL expiry date/i.test(txt));
ok('no page errors', errs.length === 0, errs.join(' | '));

console.log('\n' + pass + ' passed, ' + fail + ' failed' + (failed.length ? '\n  FAILED: ' + failed.join('; ') : ''));
await b.close();
process.exit(fail ? 1 : 0);
