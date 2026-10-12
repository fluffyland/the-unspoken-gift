// v44 — a copy of index.html that is not pointed at a database must SAY SO.
//
// Shipping a file with placeholder values is normal when somebody else has to fill in
// their own project. What is not acceptable is the failure mode: createClient() throws
// on a non-URL, before anything renders, so the person setting up a new company gets a
// white page and no clue which of 4,400 lines to look at.
//
// Also checks the two key formats are BOTH accepted. Older Supabase projects issue a
// long "eyJ..." JWT; new ones issue "sb_publishable_...". Rejecting the newer form would
// tell somebody with a correct setup that it is wrong.
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
const SRC = fs.readFileSync(HERE + '../app.html', 'utf8');
let pass = 0, fail = 0, failed = [];
const ok = (n, c, extra = '') => { if (c) { pass++; console.log('  ✓', n); } else { fail++; failed.push(n); console.log('  ✗', n, extra); } };
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });

const REAL_URL = 'https://aypyolzkdupkpefpxius.supabase.co';
async function load(url, key) {
  const html = SRC.replace(`const SUPABASE_URL = "${REAL_URL}";`, `const SUPABASE_URL = ${JSON.stringify(url)};`)
                  .replace(/const SUPABASE_ANON_KEY = "[^"]*";/, `const SUPABASE_ANON_KEY = ${JSON.stringify(key)};`);
  const f = '/tmp/t45-' + Math.random().toString(36).slice(2) + '.html';
  fs.writeFileSync(f, html);
  fs.copyFileSync(HERE + '../supabase.min.js', f.replace(/\/[^/]+$/, '/supabase.min.js'));
  const pg = await b.newPage();
  const errs = [];
  pg.on('pageerror', e => errs.push(e.message));
  await pg.goto('file://' + f);
  await pg.waitForTimeout(500);
  const out = await pg.evaluate(() => ({
    needsSetup: typeof NEEDS_SETUP !== 'undefined' ? NEEDS_SETUP : 'undefined',
    text: (document.querySelector('#app') || {}).innerText || '',
    chars: ((document.querySelector('#app') || {}).innerText || '').trim().length
  }));
  await pg.close(); fs.unlinkSync(f);
  return { ...out, errs };
}

console.log('\n§1 placeholders: a screen that explains, not a blank page');
let r = await load('PASTE_YOUR_PROJECT_URL_HERE', 'PASTE_YOUR_ANON_KEY_HERE');
ok('it knows it is unconfigured', r.needsSetup === true, JSON.stringify(r.needsSetup));
ok('the page is NOT blank', r.chars > 100, 'chars=' + r.chars);
ok('no uncaught error', r.errs.length === 0, JSON.stringify(r.errs));
ok('it names the file to edit', /index\.html/.test(r.text), JSON.stringify(r.text.slice(0, 120)));
ok('and the line number', /263/.test(r.text));
ok('and where to find the values', /Settings\s*→\s*API/.test(r.text), JSON.stringify(r.text.slice(0, 200)));
ok('it names both constants', /SUPABASE_URL/.test(r.text) && /SUPABASE_ANON_KEY/.test(r.text));
ok('it warns off the service_role key', /service_role/.test(r.text));

console.log('\n§2 only the URL missing — only the URL is named');
r = await load('PASTE_YOUR_PROJECT_URL_HERE', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSJ9.abc');
ok('still a setup screen', r.needsSetup === true);
ok('SUPABASE_URL is listed', /SUPABASE_URL/.test(r.text));
ok('SUPABASE_ANON_KEY is NOT listed as a problem', !/SUPABASE_ANON_KEY/.test(r.text), JSON.stringify(r.text.slice(0, 300)));

console.log('\n§3 a NEW-style sb_publishable_ key is accepted');
r = await load('https://abcdefghijkl.supabase.co', 'sb_publishable_ovL7MxZCgA5Zl6qrpDlWWw_78wTWh8T');
ok('not treated as unconfigured', r.needsSetup === false, JSON.stringify(r.needsSetup));
ok('and it renders the real app, not the setup screen', !/not pointed at a database/.test(r.text));

console.log('\n§4 an OLD-style eyJ JWT is accepted');
r = await load('https://abcdefghijkl.supabase.co', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSJ9.sig');
ok('not treated as unconfigured', r.needsSetup === false);
ok('renders the real app', !/not pointed at a database/.test(r.text));

console.log('\n§5 the shipped file is configured, so nobody sees the setup screen by accident');
r = await load(REAL_URL, 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSJ9.sig');
ok('the real configuration passes', r.needsSetup === false);

console.log('\n§6 a service_role-shaped or junk key is refused rather than half-working');
for (const k of ['', 'service_role', 'sb_secret_abcdefghijklmnop', 'hello']) {
  r = await load('https://abcdefghijkl.supabase.co', k);
  ok(`refused: ${JSON.stringify(k).slice(0, 24)}`, r.needsSetup === true, JSON.stringify(r.needsSetup));
}

console.log(`\n${pass} passed, ${fail} failed` + (fail ? '\n  ' + failed.join('\n  ') : ''));
await b.close();
process.exit(fail ? 1 : 0);
