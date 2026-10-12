// v42 — every screen renders, for every kind of account, on every shape of database.
//
// This suite exists because of a mistake it would have caught in one second. v41 deleted
// balCard() after `grep -n "balCard(" app.html` found no callers. It had one:
//
//     <div class="balgrid">${main.map(balCard).join("")}</div>
//
// passed by REFERENCE, with no parenthesis after the name. Deleting it threw a
// ReferenceError the moment the dashboard rendered — the first screen after sign-in — so
// the login form worked and the screen behind it went blank. Reported as "i unable to
// sign in already".
//
// Every other suite here seeds a view and asserts numbers in it. None of them rendered
// the dashboard, so none of them could notice. This one renders EVERYTHING and asserts
// only that it rendered: no page error, and some content on screen. It is the cheapest
// test in the project and the one whose absence actually cost the user a working app.
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
let pass = 0, fail = 0, failed = [];
const ok = (n, c, extra = '') => { if (c) { pass++; console.log('  ✓', n); } else { fail++; failed.push(n); console.log('  ✗', n, extra); } };
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const pg = await b.newPage({ viewport: { width: 1280, height: 950 } });
let errs = [];
pg.on('pageerror', e => errs.push(e.message));
pg.on('console', m => { if (m.type() === 'error' && !/favicon|404/.test(m.text())) errs.push('console: ' + m.text().slice(0, 200)); });
await pg.goto('file://' + HERE + '../app.html');
await pg.waitForFunction(() => typeof render === 'function');
await pg.addScriptTag({ content: fs.readFileSync(HERE + 'seed.js', 'utf8') });

const VIEWS = ['dashboard', 'profile', 'apply', 'myapps', 'calendar', 'approvals', 'hr'];
const HRTABS = ['records', 'balances', 'employees', 'types', 'apply', 'amend', 'settings', 'ledger'];

// A screen counts as rendered only if it put real content on the page. A caught
// exception that leaves an empty <main> must not pass for "no error".
async function screen(label, opts) {
  errs = [];
  const out = await pg.evaluate(o => {
    try { __seed(o); } catch (e) { return { threw: String(e && e.message || e) }; }
    const m = document.querySelector('main');
    return { threw: null, len: m ? m.innerText.trim().length : 0 };
  }, opts);
  ok(`${label} renders`, !out.threw && out.len > 40 && errs.length === 0,
     JSON.stringify({ threw: out.threw, chars: out.len, errs: errs.slice(0, 2) }));
}

console.log('\n§1 every view, as an employee');
for (const v of VIEWS) await screen(`employee · ${v}`, { view: v });

console.log('\n§2 every view, as HR / Owner');
for (const v of VIEWS) await screen(`HR · ${v}`, { asHr: true, view: v });

console.log('\n§3 every HR console tab');
for (const t of HRTABS) await screen(`HR console · ${t}`, { asHr: true, hrTab: t });

console.log('\n§4 the same, against a database that has not been upgraded');
// Each flag turns off a migration. A screen that reads a column the database does not
// have must degrade, not blank — the app is used by companies mid-upgrade.
for (const flag of ['noV16', 'noV18', 'noV24', 'noV28', 'noV36']) {
  await screen(`${flag} · dashboard`, { [flag]: true, view: 'dashboard' });
  await screen(`${flag} · profile`,   { [flag]: true, view: 'profile' });
  await screen(`${flag} · HR balances`, { [flag]: true, asHr: true, hrTab: 'balances' });
}

console.log('\n§5 with a carry-forward, and with none');
for (const carry of [undefined, null,
                     { year: 2026, carry_in: 5, remaining: 5, expires_on: '2026-12-31', expired: false },
                     { year: 2026, carry_in: 5, remaining: 0, expires_on: '2026-06-30', expired: true }]) {
  const name = carry === undefined ? 'default' : carry === null ? 'no carry record'
             : carry.expired ? 'expired carry' : 'live carry';
  await screen(`${name} · dashboard`, { carry, view: 'dashboard' });
  await screen(`${name} · profile`, { carry, view: 'profile' });
}

console.log('\n§6 annual leave is split on the dashboard too, not just the other screens');
// The dashboard tile is the fourth place this statement is made. All four must agree.
await pg.evaluate(() => {
  __seed({ view: 'dashboard' });
  db.applications = []; db.ledgerTagged = true;
  db.ledger = [
    { id: 1, empId: 'e2', type: 'annual', delta: 14, reason: '2026 annual allowance',
      ts: Date.parse('2026-01-02'), year: 2026, kind: 'grant' },
    { id: 2, empId: 'e2', type: 'annual', delta: 5, reason: 'Carried forward from 2025',
      ts: Date.parse('2026-01-02'), year: 2026, kind: 'carry_in' }
  ];
  db.annualCarry = { year: 2026, carry_in: 5, remaining: 5, expires_on: '2026-12-31', expired: false };
  db.allCarry = [{ emp_id: 'e2', year: 2026, carry_in: 5, expires_on: '2026-12-31', expired_at: null }];
  render();
});
const tile = await pg.evaluate(() => {
  const el = [...document.querySelectorAll('.bal')].find(x => /Annual Leave/.test(x.textContent));
  return el ? el.innerText.replace(/\s+/g, ' ') : null;
});
ok('the tile shows this year\'s 14, not 19', /\b14 days left\b/.test(tile || ''), JSON.stringify(tile));
ok('and names the carried days separately', /5 carried forward/.test(tile || ''), JSON.stringify(tile));

console.log(`\n${pass} passed, ${fail} failed` + (fail ? '\n  ' + failed.join('\n  ') : ''));
await b.close();
process.exit(fail ? 1 : 0);
