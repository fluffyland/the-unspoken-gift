// v40 — annual leave and carry-forward are two pots, and no screen may count them twice.
//
// Reported, with the numbers: "Lee Jian Wei ... CF 5 | AL 11 / 14 ... why LEE JIAN WEI AL
// HAVE NO APPLICATION BUT IT SHOWS 11 days / 14 days" and "Annual leave for this year is
// one group, then carry forward annual leave is another thing they do not mix ... when
// user apply it should deduct from carryfoward first until zero out only use its annual
// leave for this year."
//
// The Balances tab printed the carried days in the CF column AND inside the Annual Leave
// figure beside it, so a person with 14 entitled and 5 carried read as CF 5 next to an AL
// number that already had those 5 in it. Same days, two columns, one row.
//
// The worked example used throughout: 14 entitled, 5 carried in, 3 days taken.
//   carry is spent first        -> 2 of the carry left
//   this year's 14 is untouched -> AL 14 / 14
//   available                   -> 16, and 14 + 2 = 16 exactly
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
const APP = HERE + '../app.html';
let pass = 0, fail = 0, errs = [], failed = [];
const ok = (n, c, extra = '') => { if (c) { pass++; console.log('  ✓', n); } else { fail++; failed.push(n); console.log('  ✗', n, extra); } };
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const pg = await b.newPage({ viewport: { width: 1400, height: 950 } });
pg.on('pageerror', e => { errs.push(e.message); console.log('  !! pageerror:', e.message); });
await pg.goto('file://' + APP);
await pg.waitForFunction(() => typeof render === 'function');
await pg.addScriptTag({ content: fs.readFileSync(HERE + 'seed.js', 'utf8') });
const seed = o => pg.evaluate(x => __seed(x), o);

// 14 granted, 5 carried in, 3 taken — Barbie (e2). The seed's own applications are
// cleared: they are 17 days of 2026 annual leave, which would swamp the arithmetic
// being measured here and make a wrong answer look plausible.
const scenario = (taken) => pg.evaluate(t => {
  db.applications = [];
  db.ledger = [
    { id: 1, empId: 'e2', type: 'annual', delta: 14, reason: '2026 annual allowance',
      ts: Date.parse('2026-01-02'), year: 2026, kind: 'grant' },
    { id: 2, empId: 'e2', type: 'annual', delta: 5, reason: 'Carried forward from 2025',
      ts: Date.parse('2026-01-02'), year: 2026, kind: 'carry_in' }
  ];
  if (t) db.ledger.push({ id: 3, empId: 'e2', type: 'annual', delta: -t, refApp: 'x',
      reason: 'Leave taken', ts: Date.parse('2026-03-02'), year: 2026, kind: 'taken' });
  db.allCarry = [{ emp_id: 'e2', year: 2026, carry_in: 5, expires_on: '2026-12-31', expired_at: null }];
  db.annualCarry = { year: 2026, carry_in: 5, remaining: 5 - t, expires_on: '2026-12-31', expired: false };
  db.ledgerTagged = true;
  render();
}, taken);

// Barbie's row on the Balances tab, as a list of cells.
const row = () => pg.evaluate(() => {
  const tr = [...document.querySelectorAll('table tr')].find(r => /Barbie Girl/.test(r.textContent));
  return tr ? [...tr.querySelectorAll('td')].map(td => td.textContent.trim()) : null;
});

console.log('\n§1 nothing taken yet: the two pots are shown separately and add up');
await seed({ asHr: true, hrTab: 'balances' });
await scenario(0);
let r = await row();
ok('the row is there', !!r, JSON.stringify(r));
ok('CF column shows the 5 carried in', r[2] === '5', JSON.stringify(r));
ok('and Annual Leave shows THIS YEAR only — 14 / 14, not 19 / 14', r[3] === '14 / 14', JSON.stringify(r));
const totalled = await pg.evaluate(() => {
  const s = annualSplit('e2', bal('e2', 'annual'));
  return [s.own, s.carry, bal('e2', 'annual').avail];
});
ok('the two always sum to Available', totalled[0] + totalled[1] === totalled[2], JSON.stringify(totalled));

console.log('\n§2 three days taken: the carry goes first, this year is untouched');
await scenario(3);
r = await row();
ok('CF drops from 5 to 2 — the carry paid for it', r[2] === '2', JSON.stringify(r));
ok('this year\'s 14 is untouched: 14 / 14', r[3] === '14 / 14', JSON.stringify(r));
ok('available is still 16 in total', await pg.evaluate(() => bal('e2', 'annual').avail) === 16);

console.log('\n§3 more taken than was carried: only then does this year pay');
await scenario(7);   // 5 from the carry, 2 from this year's own days
r = await row();
ok('the carry is exhausted, not negative', r[2] === '0', JSON.stringify(r));
ok('and this year has paid the remaining 2: 12 / 14', r[3] === '12 / 14', JSON.stringify(r));
ok('available 12', await pg.evaluate(() => bal('e2', 'annual').avail) === 12);

console.log('\n§4 the same split on the Apply screen, and for the RIGHT person');
// carryLine used to read db.annualCarry — the carry of whoever is logged in — whatever
// balance was on screen. HR entering leave for somebody else saw their own carried days.
await scenario(3);
await pg.evaluate(() => { hrTab = 'apply'; vp = { hrApply: true, forEmp: 'e2' }; render(); });
let txt = await pg.evaluate(() => document.body.innerText);
ok('Apply says Annual Leave 14 and Carry Forward 2',
   /Annual Leave:\s*14\b[^]{0,30}Carry Forward:\s*2\b/.test(txt),
   JSON.stringify((txt.match(/Available Balance[^]{0,140}/) || [''])[0]));
const usesWho = await pg.evaluate(() =>
  /carryLine\(who\.id,/.test(document.documentElement.innerHTML));
ok('and it is asked for the person on screen, not for me', usesWho);

console.log('\n§5 a company that never had carry-forward is unaffected');
await seed({ asHr: true, hrTab: 'balances', noV16: true });
await pg.evaluate(() => {
  db.applications = []; db.ledgerTagged = true;
  db.ledger = [{ id: 1, empId: 'e2', type: 'annual', delta: 14, reason: '2026 annual allowance',
    ts: Date.parse('2026-01-02'), year: 2026, kind: 'grant' }];
  render();
});
r = await row();
ok('there is no CF column at all', r.length >= 3 && r[2] === '14 / 14', JSON.stringify(r));

console.log('\n§6 the CSV export splits it the same way the table does');
await seed({ asHr: true, hrTab: 'balances' });
await scenario(3);
const csv = await pg.evaluate(() => {
  let got = null;
  const real = window.csvDownload;
  window.csvDownload = (name, rows) => { got = rows; };
  runAction({ dataset: { act: 'balcsv' } });
  window.csvDownload = real;
  return got;
});
ok('the header has a Carry Forward column', csv[0][2] === 'Carry Forward left', JSON.stringify(csv[0].slice(0, 5)));
const brow = csv.find(x => x[0] === 'Barbie Girl');
ok('and Barbie exports as CF 2, AL 14 — never 16 in both', Number(brow[2]) === 2 && Number(brow[3]) === 14,
   JSON.stringify(brow.slice(0, 6)));

console.log(`\n${pass} passed, ${fail} failed` + (fail ? '\n  ' + failed.join('\n  ') : ''));
if (errs.length) console.log('page errors: ' + errs.join(' | '));
await b.close();
process.exit(fail || errs.length ? 1 : 0);
