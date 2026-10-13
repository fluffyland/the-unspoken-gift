// v35 — the page must read the leave year off the entry, not guess it.
//
// The bug: bal() bucketed entries by the DAY THEY WERE TYPED and decided what each one
// meant by matching its wording. So a company-wide top-up counted as entitlement, December
// leave keyed in January counted against January, and a year-end write-off could be
// mistaken for a correction. The database now stores both facts; this proves the page uses
// them, and still works on a database that has not been upgraded.
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;   // .../hr-leave-system/tests/
const APP = HERE + '../app.html';
const S = HERE;
let pass = 0, fail = 0, errs = [], failed = [];
const ok = (n, c, extra = '') => { if (c) { pass++; console.log('  ✓', n); } else { fail++; failed.push(n); console.log('  ✗', n, extra); } };
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const pg = await b.newPage({ viewport: { width: 1280, height: 950 } });
pg.on('pageerror', e => { errs.push(e.message); console.log('  !! pageerror:', e.message); });
await pg.goto('file://' + APP);
await pg.waitForFunction(() => typeof render === 'function');
await pg.addScriptTag({ content: fs.readFileSync(S + '/seed.js', 'utf8') });
const act = (o) => pg.evaluate(x => runAction({ dataset: x }), o);
const CY = new Date().getFullYear();

console.log('\n§1 a tagged ledger is read from its tags');
// Barbie's annual for this year: 14 granted, 3.5 in top-ups, 5 carried from last year,
// last year closed off, and 2 days taken. Every entry is typed TODAY on purpose — under
// the old rule that alone put all of them in this year.
await pg.evaluate((cy) => {
  __seed({});
  const now = new Date().toISOString();
  db.ledger = [
    { id: 1, empId: 'e2', type: 'annual', delta: 14,  reason: cy + ' annual allowance',      ts: now, refApp: null, year: cy,     kind: 'grant' },
    { id: 2, empId: 'e2', type: 'annual', delta: 3.5, reason: cy + ' annual leave +3.5 — company-wide', ts: now, refApp: null, year: cy, kind: 'adjust' },
    { id: 3, empId: 'e2', type: 'annual', delta: 5,   reason: 'Carried forward from ' + (cy - 1), ts: now, refApp: null, year: cy, kind: 'carry_in' },
    { id: 4, empId: 'e2', type: 'annual', delta: -5,  reason: (cy - 1) + ' annual leave closed — 5 carried forward', ts: now, refApp: null, year: cy - 1, kind: 'writeoff' },
    { id: 5, empId: 'e2', type: 'annual', delta: 5,   reason: (cy - 1) + ' annual allowance', ts: now, refApp: null, year: cy - 1, kind: 'grant' },
    { id: 6, empId: 'e2', type: 'annual', delta: -2,  reason: 'Leave taken', ts: now, refApp: 'a1', year: cy, kind: 'taken' }
  ];
  db.ledgerTagged = true;
  view = 'hr'; hrTab = 'staff'; render();
}, CY);
let bl = await pg.evaluate(() => bal('e2', 'annual'));
ok('entitled this year is the allowance plus the top-up', bl.yGranted === 17.5, 'got ' + bl.yGranted);
ok('carried days are NOT counted as this year\'s entitlement', bl.yGranted === 17.5);
ok('last year\'s allowance is not counted either — it is tagged last year', bl.yGranted === 17.5);
ok('taken is read from the tag', bl.yUsed === 2, 'got ' + bl.yUsed);
ok('the balance is every entry, whatever year it belongs to', bl.avail === 20.5, 'got ' + bl.avail);

console.log('\n§2 the day it was typed no longer decides anything');
// The same six entries, but keyed in on 2 January of THIS year while three of them belong
// to last year. The old rule would have counted all six as this year's.
await pg.evaluate((cy) => {
  const jan = cy + '-01-02T02:00:00Z';
  db.ledger.forEach(l => { l.ts = jan; });
  render();
}, CY);
bl = await pg.evaluate(() => bal('e2', 'annual'));
ok('entitlement is unchanged by the timestamps', bl.yGranted === 17.5, 'got ' + bl.yGranted);
ok('and so is taken', bl.yUsed === 2, 'got ' + bl.yUsed);

console.log('\n§3 an un-upgraded database still works');
await pg.evaluate((cy) => {
  __seed({});
  const now = new Date().toISOString();
  db.ledger = [
    { id: 1, empId: 'e2', type: 'annual', delta: 14,  reason: cy + ' annual allowance', ts: now, refApp: null, year: null, kind: null },
    { id: 2, empId: 'e2', type: 'annual', delta: 3.5, reason: cy + ' annual leave +3.5 — company-wide', ts: now, refApp: null, year: null, kind: null },
    { id: 3, empId: 'e2', type: 'annual', delta: -1,  reason: (cy - 1) + ' Sick Leave expired (unused)', ts: now, refApp: null, year: null, kind: null },
    { id: 4, empId: 'e2', type: 'annual', delta: -2,  reason: 'Leave taken', ts: now, refApp: 'a1', year: null, kind: null }
  ];
  db.ledgerTagged = false;
  render();
}, CY);
bl = await pg.evaluate(() => bal('e2', 'annual'));
ok('it falls back to the wording and the timestamp', bl.yGranted === 17.5, 'got ' + bl.yGranted);
ok('write-offs are still kept out of the entitlement', bl.yGranted === 17.5);
ok('and leave taken is still recognised', bl.yUsed === 2, 'got ' + bl.yUsed);

console.log('\n§4 starting a year that is already running is explained, not attempted');
await pg.evaluate((cy) => {
  __seed({ asHr: true, hrTab: 'settings' });
  vp.grantYear = cy;
  vp.ysPreview = { data: { year: cy, preview: true, already_started: true,
    blocked_reason: cy + ' has already been credited — 12 employee(s) already hold ' + cy + ' leave.',
    rows: [], blockers: [] } };
  render();
}, CY);
const panel = await pg.evaluate(() => document.body.innerText);
ok('it says the year has already been credited', /already been credited/i.test(panel));
ok('it says the button is for the year ahead', /year <?ahead|the year\s*ahead/i.test(panel), panel.slice(0, 200));
ok('it points at Edit employee', /Edit employee/.test(panel));
ok('it points at the Leave types tab', /Leave types/.test(panel));
ok('it says nothing was changed', /Nothing has been changed/i.test(panel));
const btns = await pg.evaluate(() => [...document.querySelectorAll('[data-act]')].map(b => b.dataset.act));
ok('and offers no way to run it anyway', !btns.includes('ysgo'), JSON.stringify(btns.filter(x => /^ys/.test(x))));

console.log('\n§5 nothing guesses the year off a timestamp any more');
const src = fs.readFileSync(APP, 'utf8');
const guesses = src.split('\n')
  .map((l, i) => [i + 1, l])
  .filter(([, l]) => /new Date\(l\.ts\)\.getFullYear\(\)/.test(l));
ok('the only place left is the documented fallback inside ledgerYear()',
   guesses.length === 1 && /ledgerYear/.test(guesses[0][1]),
   JSON.stringify(guesses));

ok('no page errors', errs.length === 0, errs.join(' | '));
console.log('\n' + pass + ' passed, ' + fail + ' failed' + (failed.length ? '\n  FAILED: ' + failed.join('; ') : ''));
await b.close();
process.exit(fail ? 1 : 0);
