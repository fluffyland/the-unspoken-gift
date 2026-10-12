// v41 — the same split on My details, the page the employee actually opens.
//
// v40 stopped the Balances tab counting the carried days twice. It missed this page.
// Reported: "i still saw its wrong under the employee Lee Jian Wei" — while his ledger,
// checked with explain_balances.sql, was correct: 14 entitled, 5 carried, 0 taken = 19.
//
// What his own screen printed:
//
//   Annual Leave     Balance 14   Taken 0   Left 19   <- the 5 carried are in here
//   Carry Forward    Balance  5   Taken 0   Left  5   <- and again here
//
// 14 entitled reading as 24 available. Both columns were double-counting: Left came from
// b.avail (carry included) and Taken from b.yUsed (days paid out of the carry included).
//
// The rule asserted here, on both rows, whatever the numbers are:
//     Balance - Taken === Left        (each row's own arithmetic closes)
//     annual.Left + carry.Left === bal().avail   (the two pots are the whole balance)
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

// Barbie (e2) is the logged-in employee. 14 granted, 5 carried in, `taken` days gone.
// The seed's own applications are cleared: they are 17 days of 2026 annual leave, which
// would swamp the arithmetic being measured and make a wrong answer look plausible.
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

// One row of My leave entitlement, as [Balance, Taken, Left] numbers.
const line = (label) => pg.evaluate(l => {
  const tr = [...document.querySelectorAll('table tr')]
    .find(r => r.querySelector('td') && new RegExp('^' + l).test(r.querySelector('td').textContent.trim()));
  if (!tr) return null;
  return [...tr.querySelectorAll('td')].slice(1).map(td => Number(td.textContent.trim()));
}, label);
const availOf = () => pg.evaluate(() => bal('e2', 'annual').avail);

// Balance - Taken === Left, on a row, and the row is really there.
async function closes(label, want) {
  const r = await line(label);
  ok(`${label}: ${want.join(' · ')}`, r && r.join(',') === want.join(','), JSON.stringify(r));
  if (r) ok(`${label}: Balance − Taken = Left`, r[0] - r[1] === r[2], JSON.stringify(r));
}

console.log('\n§1 Lee Jian Wei\'s real figures — 14 entitled, 5 carried, nothing taken');
await seed({ view: 'profile' });
await scenario(0);
await closes('Annual Leave', [14, 0, 14]);
await closes('Carry Forward', [5, 0, 5]);
let a = await line('Annual Leave'), c = await line('Carry Forward');
ok('the two Left figures are the whole balance — 19', a[2] + c[2] === await availOf(),
   JSON.stringify([a[2], c[2], await availOf()]));
ok('and Annual Leave does NOT read 19 on its own', a[2] !== 19);

console.log('\n§2 three days taken: the carry pays, this year is untouched');
await scenario(3);
await closes('Annual Leave', [14, 0, 14]);
await closes('Carry Forward', [5, 3, 2]);
a = await line('Annual Leave'); c = await line('Carry Forward');
ok('the two Left figures still sum to the balance — 16', a[2] + c[2] === await availOf(),
   JSON.stringify([a[2], c[2], await availOf()]));
ok('the three days are counted ONCE, not on both rows', a[1] + c[1] === 3,
   JSON.stringify([a[1], c[1]]));

console.log('\n§3 seven taken: the carry is spent first, then this year');
await scenario(7);
await closes('Annual Leave', [14, 2, 12]);
await closes('Carry Forward', [5, 5, 0]);
a = await line('Annual Leave'); c = await line('Carry Forward');
ok('the two Left figures still sum to the balance — 12', a[2] + c[2] === await availOf(),
   JSON.stringify([a[2], c[2], await availOf()]));
ok('and the seven days are counted once across the two rows', a[1] + c[1] === 7,
   JSON.stringify([a[1], c[1]]));

console.log('\n§4 a leave type with no carry at all is untouched');
await scenario(3);
await pg.evaluate(() => {
  db.ledger.push({ id: 9, empId: 'e2', type: 'sick', delta: 14, reason: '2026 annual allowance',
    ts: Date.parse('2026-01-02'), year: 2026, kind: 'grant' });
  db.ledger.push({ id: 10, empId: 'e2', type: 'sick', delta: -2, refApp: 'y', reason: 'Leave taken',
    ts: Date.parse('2026-04-02'), year: 2026, kind: 'taken' });
  render();
});
await closes('Sick Leave', [14, 2, 12]);

console.log('\n§5 a company that never had carry-forward');
await seed({ view: 'profile', noV16: true });
await pg.evaluate(() => {
  db.applications = []; db.ledgerTagged = true;
  db.ledger = [{ id: 1, empId: 'e2', type: 'annual', delta: 14, reason: '2026 annual allowance',
    ts: Date.parse('2026-01-02'), year: 2026, kind: 'grant' },
    { id: 2, empId: 'e2', type: 'annual', delta: -3, refApp: 'x', reason: 'Leave taken',
      ts: Date.parse('2026-03-02'), year: 2026, kind: 'taken' }];
  render();
});
await closes('Annual Leave', [14, 3, 11]);
ok('and there is no Carry Forward line to confuse it with', (await line('Carry Forward')) === null);

console.log('\n§6 days that EXPIRED are not days the person took');
// This is what separates the two ways of working out the carry's Taken column. Taken as
// `carriedIn − left` is the same number as `min(carriedIn, taken)` for as long as the
// only thing reducing the carry is leave — but once the days expire, `left` drops to 0
// and `carriedIn − left` reports the whole carry as leave the person took. They took
// nothing: it was forfeited. The Taken column is the one an employee queries with HR.
await seed({ view: 'profile' });
await pg.evaluate(() => {
  db.applications = []; db.ledgerTagged = true;
  db.ledger = [
    { id: 1, empId: 'e2', type: 'annual', delta: 14, reason: '2026 annual allowance',
      ts: Date.parse('2026-01-02'), year: 2026, kind: 'grant' },
    { id: 2, empId: 'e2', type: 'annual', delta: 5, reason: 'Carried forward from 2025',
      ts: Date.parse('2026-01-02'), year: 2026, kind: 'carry_in' }
  ];
  // The expiry has gone by and nothing has been booked against the carry.
  db.annualCarry = { year: 2026, carry_in: 5, remaining: 0,
                     expires_on: '2026-06-30', expired: true };
  db.allCarry = [{ emp_id: 'e2', year: 2026, carry_in: 5,
                   expires_on: '2026-06-30', expired_at: null }];
  render();
});
let x = await line('Carry Forward');
ok('the carry is reported as gone — Left 0', x && x[2] === 0, JSON.stringify(x));
ok('but Taken stays 0: nobody took those days', x && x[1] === 0, JSON.stringify(x));
ok('and the line says expired rather than just showing a zero',
   /Expired 30 Jun 2026/.test(await pg.evaluate(() => document.body.innerText)));

console.log('\n§7 HR can tell an expired carry from a live one, for anybody');
// db.allCarry is what the Balances tab reads for other people, and expires_on was
// missing from the columns it fetches — so carryExpired() had nothing to test and an
// expired carry looked live on everybody's row but the viewer's own.
const cols = await pg.evaluate(() =>
  (document.documentElement.innerHTML.match(/from\("annual_carry"\)\.select\("([^"]+)"/) || [])[1] || '');
ok('expires_on is among the columns fetched for everyone', /expires_on/.test(cols), cols);

console.log('\n§8 the dashboard tile makes the same statement');
// §8 used to assert that balCard() had been DELETED, and passed — which is how a
// function the dashboard still used by reference got removed and shipped. The assertion
// was true and useless: it confirmed the function was gone without confirming nothing
// needed it. What matters is that the four screens stating this quantity agree, so that
// is what is checked; t42_smoke.mjs separately renders every view and would have caught
// the removal outright.
await seed({ view: 'dashboard' });
await scenario(0);
const tile = await pg.evaluate(() => {
  const el = [...document.querySelectorAll('.bal')].find(x => /Annual Leave/.test(x.textContent));
  return el ? el.innerText.replace(/\s+/g, ' ') : null;
});
ok('the dashboard tile says 14 days left, not 19', /\b14 days left\b/.test(tile || ''), JSON.stringify(tile));
ok('and names the 5 carried days separately', /5 carried forward/.test(tile || ''), JSON.stringify(tile));

console.log(`\n${pass} passed, ${fail} failed` + (fail ? '\n  ' + failed.join('\n  ') : ''));
if (errs.length) console.log('page errors: ' + errs.join(' | '));
await b.close();
process.exit(fail || errs.length ? 1 : 0);
