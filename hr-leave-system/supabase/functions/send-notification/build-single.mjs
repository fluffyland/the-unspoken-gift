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

const out = idx
  .replace('import { buildMails, applyTestMode } from "./templates.js";\n', '')
  .replace('import { createClient } from "npm:@supabase/supabase-js@2";',
`import { createClient } from "npm:@supabase/supabase-js@2";

/* ============================================================================
   GENERATED FILE — do not edit here.
   Paste this whole thing into the Supabase dashboard: Edge Functions →
   Deploy a new function → name it exactly  send-notification  → then replace the
   WHOLE CONTENTS of the sample index.ts with this. Keep the file, replace what is
   inside it. "Verify JWT" can be left at its default: the webhook sends the anon
   key and the test button sends the signed-in user's token, so both pass.
   The editable source is index.ts + templates.js in the repo; regenerate with
   \`node build-single.mjs\`.
   ============================================================================ */

// ---- the words, from templates.js -------------------------------------------
${body.trim()}
// ---- end of templates.js ----------------------------------------------------
`);
fs.writeFileSync(dir + 'DEPLOY-single-file.ts', out);
console.log('wrote DEPLOY-single-file.ts —', out.split('\n').length, 'lines');
