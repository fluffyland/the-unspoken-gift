// Produce the DEPLOYABLE file, index.ts, from handler.ts + templates.js.
//
// Why this exists: the source is split so the test suite can import templates.js -- the very
// file the function sends from -- and check every sentence without sending email.
//
// Why the output is called index.ts: the Supabase dashboard deploys ONE entry-point file, and
// it is always named index.ts. Anything else added in the editor is silently not part of the
// bundle. This project shipped a file called DEPLOY-single-file.ts and told the user to paste
// "DEPLOY-single-file.ts, not index.ts" -- which reads like "make a file called that". It was
// pasted into a second file, the deploy ignored it, index.ts kept an import of a templates.js
// that was not there, the module never booted, and every request hung while the dashboard
// reported success. Three times. So: the file you copy and the file you paste into now have
// the same name, and there is no second name to get wrong.
//
// t29.mjs asserts index.ts and handler.ts never drift apart.
import fs from 'fs';
const dir = new URL('.', import.meta.url).pathname;
const tpl = fs.readFileSync(dir + 'templates.js', 'utf8');
const idx = fs.readFileSync(dir + 'handler.ts', 'utf8');

const body = tpl
  .replace(/^\/\/[^\n]*\n(?:\/\/[^\n]*\n)*\n/, '')           // drop the module's own header
  .replace(/^export /gm, '');                                 // no exports inside one file

const IMPORT = 'import { buildMails, applyTestMode } from "./templates.js";';
if (!idx.includes(IMPORT)) {
  console.error('handler.ts no longer imports templates.js the way this builder expects.');
  process.exit(1);
}
const out = idx.replace(IMPORT,
`/* ============================================================================
   GENERATED FILE — do not edit here. Edit handler.ts or templates.js and re-run
   \`node build-single.mjs\`.

   THIS is the file you deploy. Supabase Dashboard → Edge Functions →
   send-notification → DELETE any file that is not index.ts → open index.ts,
   select all, paste this in its place → Deploy. One file, and it needs no other:
   a second file is not part of what the dashboard deploys, and an entry point
   that imports a file which is not there never starts -- it hangs, with no error,
   while the deploy still reports success.

   Then prove it actually started: ./check-deploy.sh — it only sends an OPTIONS
   preflight, so it cannot email anyone.

   Leave "Verify JWT with legacy secret" ON -- this function has no auth logic of
   its own by design, so that setting is what protects it, and the anon key the
   webhook sends already satisfies it.
   ============================================================================ */

// ---- the words, from templates.js -------------------------------------------
${body.trim()}
// ---- end of templates.js ----------------------------------------------------`);

// The whole point of this file is that it still contains the templates, and that it needs
// nothing beside it. An anchor that silently stops matching produces a file that looks fine
// and is missing half of itself -- which is exactly what happened once the import line above
// was edited.
for (const needed of ['function buildMails', 'function applyTestMode', 'Deno.serve']) {
  if (!out.includes(needed)) { console.error('BUILD FAILED — generated file is missing:', needed); process.exit(1); }
}
// Not just the one import we know about: ANY relative import is fatal, because the deployed
// bundle is this file alone. This is the check that would have caught the three-week bug.
const stray = out.match(/^\s*(?:import|export)\s[^\n]*from\s+["']\.[^"']*["']/m)
           || out.match(/\bimport\s*\(\s*["']\.[^"']*["']\s*\)/);
if (stray) { console.error('BUILD FAILED — the deployable file still imports a sibling file:', stray[0].trim()); process.exit(1); }

// --check regenerates and compares without writing, so a test (or a pre-deploy step) can
// prove index.ts is still exactly what handler.ts + templates.js produce. A hand edit made
// straight into the generated file is invisible to every other check in this project.
if (process.argv.includes('--check')) {
  const have = fs.existsSync(dir + 'index.ts') ? fs.readFileSync(dir + 'index.ts', 'utf8') : '';
  if (have !== out) {
    console.error('DRIFT — index.ts is not what handler.ts + templates.js produce. Run: node build-single.mjs');
    process.exit(1);
  }
  console.log('index.ts is up to date —', out.split('\n').length, 'lines');
  process.exit(0);
}

fs.writeFileSync(dir + 'index.ts', out);
console.log('wrote index.ts —', out.split('\n').length, 'lines');
