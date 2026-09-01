// Produce a ONE-FILE version of the function for pasting into the Supabase dashboard editor.
//
// Why this exists: the source is split so the test suite can import templates.js -- the very
// file the function sends from -- and check every sentence without sending email. But the
// dashboard editor is a paste box, and asking a non-developer to juggle two files there is
// how deployments go wrong. So the split stays for correctness, and this generates the
// single file for deployment. t29.mjs asserts the two never drift apart.
import fs from 'fs';
const dir = new URL('.', import.meta.url).pathname;
const tpl = fs.readFileSync(dir + 'templates.js', 'utf8');
const idx = fs.readFileSync(dir + 'index.ts', 'utf8');

const body = tpl
  .replace(/^\/\/[^\n]*\n(?:\/\/[^\n]*\n)*\n/, '')           // drop the module's own header
  .replace(/^export /gm, '');                                 // no exports inside one file

const IMPORT = 'import { buildMails, applyTestMode } from "./templates.js";';
if (!idx.includes(IMPORT)) {
  console.error('index.ts no longer imports templates.js the way this builder expects.');
  process.exit(1);
}
const out = idx.replace(IMPORT,
`/* ============================================================================
   GENERATED FILE — do not edit here.
   Paste this whole thing into the Supabase dashboard: Edge Functions →
   Deploy a new function → name it exactly  send-notification  → then replace the
   WHOLE CONTENTS of the sample index.ts with this. Keep the file, replace what is
   inside it. Leave "Verify JWT with legacy secret" ON -- this function has no auth
   logic of its own by design, so that setting is what protects it, and the anon key
   the webhook sends already satisfies it.
   The editable source is index.ts + templates.js in the repo; regenerate with
   \`node build-single.mjs\`.
   ============================================================================ */

// ---- the words, from templates.js -------------------------------------------
${body.trim()}
// ---- end of templates.js ----------------------------------------------------`);

// The whole point of this file is that it still contains the templates. An anchor that
// silently stops matching produces a file that looks fine and is missing half of itself --
// which is exactly what happened when the import line above was edited.
for (const needed of ['function buildMails', 'function applyTestMode', 'Deno.serve']) {
  if (!out.includes(needed)) { console.error('BUILD FAILED — generated file is missing:', needed); process.exit(1); }
}
if (out.includes('from "./templates.js"')) { console.error('BUILD FAILED — the import is still there'); process.exit(1); }

fs.writeFileSync(dir + 'DEPLOY-single-file.ts', out);
console.log('wrote DEPLOY-single-file.ts —', out.split('\n').length, 'lines');
