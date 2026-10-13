// LEAVE CHECK, all twelve deducting leave types, on every screen that shows a balance.
//
// Asked for by name: "AL Annual Leave · SL Sick Leave · HL Hospitalisation Leave ·
// CCL Childcare Leave · OIL Off-in-Lieu · ML Maternity Leave · PL Paternity Leave ·
// SPL Shared Parental Leave · UIC Unpaid Infant Care · ADL Adoption Leave ·
// CL Compassionate Leave · MRL Marriage Leave. make sure everything is shown"
//
// "Shown" cannot mean "shown to everybody": Maternity and Adoption are female-only and
// Paternity is male-only, so a man seeing Maternity Leave would be the bug. The rule
// checked here is therefore: every type appears for everyone ELIGIBLE, with the same
// figure on every screen, and never appears for anyone ineligible.
//
// t49 proves the screens agree with each other using one type. This proves no type is
// missing from a screen -- a different failure, and the one actually asked about.
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
let pass = 0, fail = 0, failed = [], errs = [];
const ok = (n, c, extra = '') => { if (c) { pass++; console.log('  ✓', n); } else { fail++; failed.push(n); console.log('  ✗', n, extra); } };
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const pg = await b.newPage({ viewport: { width: 1400, height: 1000 } });
pg.on('pageerror', e => errs.push(e.message));
await pg.goto('file://' + HERE + '../app.html');
await pg.waitForFunction(() => typeof render === 'function');
await pg.addScriptTag({ content: fs.readFileSync(HERE + 'seed.js', 'utf8') });

// The real MOM configuration, all 17 types, so nothing is tested against a toy list.
const TYPES = [
  ['annual','Annual Leave','AL',14,null],   ['sick','Sick Leave','SL',14,null],
  ['hosp','Hospitalisation Leave','HL',60,null], ['childcare','Childcare Leave','CCL',6,null],
  ['oil','Off-in-Lieu','OIL',0,null],       ['maternity','Maternity Leave','ML',112,'F'],
  ['paternity','Paternity Leave','PL',28,'M'], ['shared_parental','Shared Parental Leave','SPL',70,null],
  ['infant','Unpaid Infant Care','UIC',6,null], ['adoption','Adoption Leave','ADL',84,'F'],
  ['compassionate','Compassionate Leave','CL',3,null], ['marriage','Marriage Leave','MRL',3,null],
];
const NO_DEDUCT = [['ns','NS / Reservist','M'],['unpaid','Unpaid Leave',null],
                   ['overseas_trip','Overseas Business Trip Leave',null],
                   ['training','Training Leave',null],['others','Others',null]];

// Seed all 17 types, grant every eligible type to e2, and take 2 days of each.
const setup = (gender, asHr) => pg.evaluate(([T, ND, g, hr]) => {
  __seed({ asHr: hr, view: hr ? 'hr' : 'dashboard', hrTab: hr ? 'balances' : undefined });
  db.employees.forEach(e => { if (e.id === 'e2') e.gender = g; });
  db.leaveTypes = T.map(([code, en, , days, gen], i) =>
      ({ code, en, zh: '', mc: false, gender: gen || '', noDeduct: false, days,
         allowHalf: code === 'annual' || code === 'oil', sort: i + 1, note: '' }))
    .concat(ND.map(([code, en, gen], i) =>
      ({ code, en, zh: '', mc: false, gender: gen || '', noDeduct: true, days: 0,
         allowHalf: false, sort: 90 + i, note: '' })));
  db.applications = []; db.ledgerTagged = true; db.ledger = []; db.allCarry = []; db.annualCarry = null;
  let id = 1;
  for (const [code, , , days, gen] of T) {
    if (gen && gen !== g) continue;                 // not eligible: no allowance at all
    if (days > 0) db.ledger.push({ id: id++, empId: 'e2', type: code, delta: days,
        reason: '2026 annual allowance', ts: Date.parse('2026-01-02'), year: 2026, kind: 'grant' });
    // Off-in-lieu is earned, not granted — credit it the way HR does.
    if (code === 'oil') db.ledger.push({ id: id++, empId: 'e2', type: 'oil', delta: 5,
        reason: 'Off-in-lieu: worked Saturdays', ts: Date.parse('2026-02-01'), year: 2026, kind: 'adjust' });
    db.ledger.push({ id: id++, empId: 'e2', type: code, delta: -2, refApp: 'a' + code,
        reason: 'Leave taken', ts: Date.parse('2026-03-02'), year: 2026, kind: 'taken' });
  }
  render();
}, [TYPES, NO_DEDUCT, gender, asHr]);

// Each screen, as a map of leave-type name -> the number it shows.
const screens = () => pg.evaluate(() => {
  const out = { overview: {}, myDetails: {}, applyOptions: [], hrBalances: {}, csv: {} };
  view = 'dashboard'; render();
  // .bal tiles exist in the DOM even inside the collapsed "More leave types" section.
  // textContent, not innerText: eight of the twelve tiles live inside the collapsed
  // "More leave types" section, and innerText returns '' for anything not rendered --
  // which made every one of them read NaN and looked like the app's fault.
  for (const el of document.querySelectorAll('.bal')) {
    const name = el.querySelector('.t').textContent.trim();
    out.overview[name] = Number((el.textContent.match(/([\d.]+)\s*days left/) || [])[1]);
    out.collapsed = out.collapsed || {};
    out.collapsed[name] = !!el.closest('details');
  }
  view = 'profile'; render();
  for (const tr of document.querySelectorAll('table tr')) {
    const td = tr.querySelector('td'); if (!td) continue;
    const name = td.textContent.trim().split('·')[0].split('Expiry')[0].trim();
    const cells = [...tr.querySelectorAll('td')];
    if (cells.length >= 4) out.myDetails[name] = cells[3].textContent.trim();
  }
  view = 'apply'; vp.form = { type: 'annual', start: '', end: '', half: {} }; render();
  out.applyOptions = [...document.querySelectorAll('select[data-f="type"] option')].map(o => o.textContent.trim());
  return out;
});

for (const gender of ['F', 'M']) {
  const who = gender === 'F' ? 'a female employee' : 'a male employee';
  console.log(`\n######## ${who} ########`);
  await setup(gender, false);
  const s = await screens();
  const eligible = TYPES.filter(([, , , , g]) => !g || g === gender);
  const notEligible = TYPES.filter(([, , , , g]) => g && g !== gender);

  console.log('\n§ every eligible type appears on all three employee screens');
  const missing = { overview: [], myDetails: [], apply: [] };
  for (const [code, en, short] of eligible) {
    if (!(en in s.overview)) missing.overview.push(short);
    if (!(en in s.myDetails)) missing.myDetails.push(short);
    if (!s.applyOptions.includes(en)) missing.apply.push(short);
  }
  ok(`Overview shows all ${eligible.length}`, !missing.overview.length, 'missing: ' + missing.overview.join(','));
  ok(`My details shows all ${eligible.length}`, !missing.myDetails.length, 'missing: ' + missing.myDetails.join(','));
  ok(`Apply lists all ${eligible.length}`, !missing.apply.length, 'missing: ' + missing.apply.join(','));

  console.log('\n§ and the figures match bal() exactly, type by type');
  const bad = [];
  for (const [code, en] of eligible) {
    const want = await pg.evaluate(c => bal('e2', c).avail, code);
    if (Number(s.overview[en]) !== want) bad.push(`${en}: overview ${s.overview[en]} vs bal ${want}`);
    if (Number(s.myDetails[en]) !== want) bad.push(`${en}: myDetails ${s.myDetails[en]} vs bal ${want}`);
  }
  ok('all ' + eligible.length + ' agree with bal()', !bad.length, bad.join(' | '));

  console.log('\n§ types this person is not eligible for are absent, not zero');
  const wrong = notEligible.filter(([, en]) => (en in s.overview) || (en in s.myDetails) || s.applyOptions.includes(en));
  ok(`${notEligible.map(t => t[2]).join(' and ')} not offered to ${who}`, !wrong.length,
     wrong.map(t => t[1]).join(','));

  console.log('\n§ how many of them are visible without a click?');
  const hidden = eligible.filter(([, en]) => s.collapsed && s.collapsed[en]).map(t => t[2]);
  console.log('     Overview shows at once : ' + eligible.filter(([, en]) => !(s.collapsed || {})[en]).map(t => t[2]).join(' '));
  console.log('     behind "More leave types": ' + (hidden.join(' ') || 'none'));
  ok('every eligible type is in the page, clicked open or not', eligible.length ===
     Object.keys(s.collapsed || {}).filter(n => eligible.some(([, en]) => en === n)).length,
     JSON.stringify(Object.keys(s.collapsed || {})));

  console.log('\n§ record-only types show no balance');
  const leaked = NO_DEDUCT.filter(([, en]) => Number.isFinite(Number(s.overview[en])));
  ok('NS / Unpaid / Trip / Training / Others carry no day count on Overview', !leaked.length,
     leaked.map(t => t[1]).join(','));
}

console.log('\n######## HR Console: the Balances tab and the CSV ########');
await setup('F', true);
const hrv = await pg.evaluate(() => {
  const out = { headers: [], cells: {}, csvHead: [], csvRow: {} };
  const table = document.querySelector('table.nowrap');
  out.headers = [...table.querySelectorAll('thead th')].map(th => th.textContent.trim());
  const tr = [...table.querySelectorAll('tbody tr')].find(r => /Barbie Girl/.test(r.textContent));
  const cells = [...tr.querySelectorAll('td')].map(td => td.textContent.trim());
  out.headers.forEach((h, i) => { out.cells[h] = cells[i]; });
  let csv = null; const real = window.csvDownload;
  window.csvDownload = (n, rows) => { csv = rows; }; runAction({ dataset: { act: 'balcsv' } }); window.csvDownload = real;
  out.csvHead = csv[0];
  const row = csv.find(r => r[0] === 'Barbie Girl');
  csv[0].forEach((h, i) => { out.csvRow[h] = row[i]; });
  return out;
});
const fem = TYPES.filter(([, , , , g]) => !g || g === 'F');
const missCol = fem.filter(([, , short]) => !hrv.headers.includes(short));
ok(`Balances tab has a column for all ${fem.length} eligible types`, !missCol.length,
   'missing: ' + missCol.map(t => t[2]).join(',') + ' | headers: ' + hrv.headers.join(' '));
ok('and a value in every one of them',
   fem.every(([, , short]) => /\d/.test(hrv.cells[short] || '')), JSON.stringify(hrv.cells));
const missCsv = fem.filter(([, en]) => !hrv.csvHead.includes(en + ' left'));
ok(`CSV export covers all ${fem.length}`, !missCsv.length, 'missing: ' + missCsv.map(t => t[1]).join(','));
// One column set serves every row, so PL is a column for everyone; eligibility is shown
// per CELL. Asserting the column was absent was wrong about the design, not about the app.
ok('a female employee\'s PL cell reads n/a, not a number', (hrv.cells['PL'] || '') === 'n/a',
   JSON.stringify({ PL: hrv.cells['PL'], ML: hrv.cells['ML'] }));
ok('while her ML cell carries a real figure', /\d/.test(hrv.cells['ML'] || ''),
   JSON.stringify({ ML: hrv.cells['ML'] }));

console.log(`\n${pass} passed, ${fail} failed` + (fail ? '\n  ' + failed.join('\n  ') : ''));
if (errs.length) console.log('page errors: ' + errs.join(' | '));
await b.close();
process.exit(fail || errs.length ? 1 : 0);
